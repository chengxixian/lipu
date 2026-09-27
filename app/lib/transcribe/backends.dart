/// 扒谱后端的统一接口与注册表。
///
/// 设计目标（用户要求"模型都可以尝试，后端写好做成可选增强包"）：
/// **加一个新模型 = 写一个 [TranscribeBackend] 实现 + 加一条 [ModelPackSpec] 注册**，
/// 界面与状态层不需要任何改动。
///
/// 每个后端自己声明：
///   · 需不需要可选包（[pack] 为空 = 内置，随安装包分发）；
///   · 包在不在（[ready]），不在时由 [resolveBackend] 统一回落到内置 Basic Pitch；
///   · 怎么跑（[run]），把音频变成 [MelodyAnalysis]。
library;

import 'audio_source.dart';
import 'basic_pitch.dart';
import 'basic_pitch_engine.dart';
import 'crnn_engine.dart';
import 'melody.dart';
import 'wav.dart';
import 'model_packs.dart';
import 'tsumugi_engine.dart';

/// 后端跑完之后的产物 + 一句"实际用了什么"的说明
class BackendRun {
  final MelodyAnalysis analysis;

  /// 显示在界面上的引擎说明（回落时要说清楚为什么没用用户选的那个）
  final String used;

  const BackendRun(this.analysis, this.used);
}

/// 推理运行时。
///
/// **默认且优先用 [onnxRuntime]**：我们的模型（Basic Pitch / CRNN / Tsumugi）都能被它直接加载，
/// 数值与速度都实测过（见 `docs/和弦识别-测量记录.md`）。
///
/// [mnn] **只保留给"非它不可"的模型**（用户决定：能直接用的不要绕 MNN）。
/// 目前没有任何后端声明它，因为实测转换过不去：
///   · CRNN 的 ONNX 图带控制流 `While` → `Compute Shape Error for While119`；
///   · Tsumugi 走 ONNX 前端 → `Compute Shape Error for val_412`；
///     走 TorchScript 前端（自己 trace 出 55.4MB 的 .pt）→
///     `Framework Input ERROR or Not Support This Model Type Now!`。
/// 脚本：`tools/onnx_export/mnn_probe.py`、`mnn_tsumugi_probe.py`。
enum InferenceRuntime { onnxRuntime, mnn }

/// 一个扒谱后端
abstract class TranscribeBackend {
  const TranscribeBackend();

  /// 这个后端跑在哪个运行时上。默认 onnxruntime；
  /// **只有 ORT 加载不了的模型**才声明 [InferenceRuntime.mnn]
  InferenceRuntime get runtime => InferenceRuntime.onnxRuntime;

  /// 稳定 id（与 [ModelPackSpec.id] 对应）
  String get id;

  String get label;
  String get blurb;

  /// 需要的可选包；null = 内置（随安装包分发）
  ModelPackSpec? get pack;

  /// 现在能不能用（内置的永远可用；可选包要求文件已装好且字节数对得上）
  bool ready(ModelPackStore store);

  /// 跑一次识别
  Future<MelodyAnalysis> run(
    AudioClip clip, {
    required TranscribeOptions options,
    void Function(double fraction, String stage)? onProgress,
  });

  /// 需要包但没装时，界面上应该提示什么
  String get missingHint => '${label}：增强包未安装，已用 Basic Pitch 代替';
}

/// 选中的后端 + 实际要跑的后端 + 回落说明
class BackendChoice {
  final TranscribeBackend backend;
  final String? fallbackNote;
  const BackendChoice(this.backend, this.fallbackNote);
}

/// 内置纯 Dart 算法（永远可用，最后的兜底）
class BuiltinDspBackend extends TranscribeBackend {
  const BuiltinDspBackend();

  @override
  String get id => 'builtin';
  @override
  String get label => '内置算法';
  @override
  String get blurb => '纯 Dart 基频跟踪 + 显著度：体积最小，适合干净的单声部哼唱，对混音/和弦较弱。';
  @override
  ModelPackSpec? get pack => null;
  @override
  bool ready(ModelPackStore store) => true;

  @override
  Future<MelodyAnalysis> run(
    AudioClip clip, {
    required TranscribeOptions options,
    void Function(double fraction, String stage)? onProgress,
  }) async {
    // 真正的实现在 ui 层（需要 isolate + 进度估算），这里只做接口占位：
    // 见 TranscribeView._runBuiltin。写成同步抛错避免"以为它在跑"。
    throw UnimplementedError('内置算法由界面层直接调用（需要 isolate 与进度估算）');
  }
}

/// 内置 Basic Pitch（230KB，默认引擎）
class BasicPitchBackend extends TranscribeBackend {
  BasicPitchBackend([BasicPitchEngine? engine]) : _engine = engine ?? BasicPitchEngine();
  final BasicPitchEngine _engine;

  @override
  String get id => 'basic_pitch';
  @override
  String get label => 'Basic Pitch（内置）';
  @override
  String get blurb =>
      'Spotify Basic Pitch（Apache-2.0，230KB）：自带 CQT 前端，混音/复调/哼唱都稳，秒级、免下载。';
  @override
  ModelPackSpec? get pack => null;
  @override
  bool ready(ModelPackStore store) => true;

  @override
  Future<MelodyAnalysis> run(
    AudioClip clip, {
    required TranscribeOptions options,
    void Function(double fraction, String stage)? onProgress,
  }) async {
    final samples = clip.sampleRate == BpConst.sampleRate
        ? clip.samples
        : resample(clip.samples, clip.sampleRate, BpConst.sampleRate);
    final params = BasicPitchParams(
      onsetThreshold: (0.65 - 0.30 * options.sensitivity).clamp(0.20, 0.65),
      frameThreshold: (0.45 - 0.25 * options.sensitivity).clamp(0.12, 0.45),
      minNoteLengthMs: (options.minNoteSec * 1000).clamp(60, 300),
    );
    final notes = await _engine.transcribe(samples, params: params, onProgress: onProgress);
    return analysisFromBasicPitch(
      notes,
      sampleRate: clip.sampleRate,
      durationSec: clip.durationSec,
      // 保留全部音符（含伴奏），转大谱表时才有左手声部；"只保留主旋律"在转换时才过滤
      melodyOnly: false,
      samples: samples,
    );
  }
}

/// 可选包：ByteDance 钢琴 CRNN
class PianoCrnnBackend extends TranscribeBackend {
  PianoCrnnBackend([PianoCrnnEngine? engine]) : _engine = engine ?? PianoCrnnEngine();
  final PianoCrnnEngine _engine;

  @override
  String get id => kPianoCrnnPack.id;
  @override
  String get label => '高精度钢琴（增强包）';
  @override
  String get blurb =>
      '钢琴专用 CRNN（MIT，Kong et al. 2021）：带踏板与力度建模。实测和弦 recall 100% / precision 83%，'
      '90 秒真实录音约 12 秒（桌面 CPU）。需下载 147MB 增强包。';
  @override
  ModelPackSpec? get pack => kPianoCrnnPack;

  @override
  bool ready(ModelPackStore store) => store.installedFile(kPianoCrnnPack) != null;

  @override
  Future<MelodyAnalysis> run(
    AudioClip clip, {
    required TranscribeOptions options,
    void Function(double fraction, String stage)? onProgress,
  }) async {
    // 包文件要从**与应用同一套包目录**里取（`forApp()`）。
    // 之前这里读的是 `_engine.modelFile`——它只有 ensureLoaded 之后才有值，
    // 结果每次识别都报"增强包未安装"（用户实测踩到）。
    final file = ModelPackStore.forApp().installedFile(kPianoCrnnPack);
    if (file == null) {
      throw StateError('增强包未安装：请在扒谱页的「增强包」区块下载或从文件导入 piano_crnn.onnx');
    }
    if (!await _engine.ensureLoaded(file.path)) {
      throw StateError('模型加载失败：${_engine.error ?? "未知原因"}');
    }
    final samples = clip.sampleRate == CrnnConst.sampleRate
        ? clip.samples
        : resample(clip.samples, clip.sampleRate, CrnnConst.sampleRate);
    final notes = await _engine.transcribe(samples, onProgress: onProgress);
    return analysisFromDetectedNotes(
      notes,
      sampleRate: clip.sampleRate,
      durationSec: clip.durationSec,
      melodyOnly: false,
    );
  }
}

/// 可选包：Tsumugi 乐器无关（神经半-CRF）
///
/// 现状：ONNX 已能导出并校验通过（`tools/onnx_export/probe_tsumugi_export.py`），
/// 输入 `[1,2,T]` 双声道 22.05kHz，输出是 interval_query/key/diag + 乐器 logits；
/// **还差 Dart 侧的半-CRF 区间 DP**（解码那一步不在网络里），所以 [ready] 暂时恒为 false。
/// 移植蓝本用仓库自己的 `decode_v1_notes()`
/// （`instrument_agnostic_amt/amt/inference/v1_windowed.py`）：它默认的 `torch` 后端是纯张量
/// 运算（`triton` 那个要 CUDA，不用），能在 Dart 里 1:1 重写。
class TsumugiBackend extends TranscribeBackend {
  TsumugiBackend([TsumugiEngine? engine]) : _engine = engine ?? TsumugiEngine();
  final TsumugiEngine _engine;

  @override
  String get id => kTsumugiPack.id;
  @override
  String get label => '通用乐器（Tsumugi）';
  @override
  String get blurb =>
      'Tsumugi（MIT）乐器无关转写：人声/吉他/弦乐/管乐同一模型，14M 参数、'
      '10 秒音频约 2.3 秒（桌面 CPU）。网络已导出 ONNX，解码（半-CRF 区间 DP）在 Dart 里实现。';
  @override
  ModelPackSpec? get pack => kTsumugiPack;

  /// 包装好了就能用（引擎是纯 Dart + onnxruntime，两条平台路径一致）
  @override
  bool ready(ModelPackStore store) => store.installedFile(kTsumugiPack) != null;

  @override
  Future<MelodyAnalysis> run(
    AudioClip clip, {
    required TranscribeOptions options,
    void Function(double fraction, String stage)? onProgress,
  }) async {
    // 同 CRNN：必须从应用真正的包目录取文件（不能依赖 engine 内部状态）
    final store = ModelPackStore.forApp();
    final file = store.installedFile(kTsumugiPack) ?? _engine.modelFile;
    if (file == null) {
      throw StateError('增强包未安装：请先下载 tsumugi_amt.onnx 与 tsumugi_amt.onnx.data 并导入');
    }
    if (!await _engine.ensureLoaded(file.path)) {
      throw StateError('模型加载失败：${_engine.error ?? "未知原因"}');
    }
    final notes = await _engine.transcribe(
      clip.samples,
      sampleRate: clip.sampleRate,
      onProgress: onProgress,
    );
    return analysisFromDetectedNotes(
      notes,
      sampleRate: clip.sampleRate,
      durationSec: clip.durationSec,
      melodyOnly: false,
    );
  }
}

/// 可选包：MuScriptor（Kyutai × Mirelo，多乐器，**非商用**）
///
/// 现状：包位置已接好（含**门控下载**：用户需先在模型页接受 CC BY-NC 4.0 协议、填 token，
/// 或自己下好再"从文件导入"）；**引擎还没实现** —— 权重是 PyTorch safetensors
/// （small 392.8MB / 103M 参数），要先做 ONNX 导出（做法与 Tsumugi 相同：`dynamo=True`），
/// 它是 decoder-only Transformer，还需在 Dart 里实现自回归 token 解码 + MIDI detokenizer。
/// 在引擎落地前 [ready] 恒为 false，避免给用户一个装了却不能用的入口。
class MuScriptorBackend extends TranscribeBackend {
  const MuScriptorBackend();

  @override
  String get id => kMuScriptorPack.id;
  @override
  String get label => 'MuScriptor（多乐器·开发中）';
  @override
  String get blurb =>
      'MuScriptor（Kyutai × Mirelo）：多乐器转写，small 版 103M 参数。'
      '权重为非商用许可且需自备 token；ONNX 导出与自回归解码尚在开发。';
  @override
  ModelPackSpec? get pack => kMuScriptorPack;

  @override
  bool ready(ModelPackStore store) => false; // 等 ONNX 导出 + 自回归解码落地

  @override
  Future<MelodyAnalysis> run(
    AudioClip clip, {
    required TranscribeOptions options,
    void Function(double fraction, String stage)? onProgress,
  }) async {
    throw UnimplementedError('MuScriptor 的 ONNX 导出与解码尚未实现');
  }
}

/// 全部后端（顺序 = 界面下拉框顺序）
final List<TranscribeBackend> kTranscribeBackends = [
  const BuiltinDspBackend(),
  BasicPitchBackend(),
  PianoCrnnBackend(),
  TsumugiBackend(),
  const MuScriptorBackend(),
];

TranscribeBackend? backendById(String id) {
  for (final b in kTranscribeBackends) {
    if (b.id == id) return b;
  }
  return null;
}

/// 界面里**可以选**的后端：需要包的必须已经装好（或者允许先选再装——由 [allowUninstalled] 决定）
List<TranscribeBackend> selectableBackends(ModelPackStore store, {bool allowUninstalled = true}) => [
      for (final b in kTranscribeBackends)
        if (b.pack == null || allowUninstalled || b.ready(store)) b,
    ];

/// 决定实际跑哪个后端：选中的后端不可用就回落到 Basic Pitch，并给出说明
BackendChoice resolveBackend(TranscribeBackend wanted, ModelPackStore store) {
  if (wanted.ready(store)) return BackendChoice(wanted, null);
  final fallback = backendById('basic_pitch')!;
  return BackendChoice(fallback, wanted.missingHint);
}
