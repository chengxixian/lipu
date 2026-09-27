/// 可选模型包：**按需下载 / 校验 / 可删除**的高精度扒谱后端。
///
/// 为什么不打包进 APK：
///   · ByteDance 钢琴 CRNN 的 fp32 ONNX 是 **147MB**，int8 也有 ~37MB；
///   · 大部分人只用 Basic Pitch（230KB、秒级）就够，不该让所有人多下几百兆。
///
/// 两种安装方式：
///   1. **在线下载**：默认从 Hugging Face 拉原始 fp32 权重，边下边校验（支持断点续传）；
///   2. **本地导入**：发行包里另外附了量化过的小体积文件（`dist/packs/`），
///      拷到设备上选一次即可——离线环境、或者不想下 147MB 的人走这条。
///
/// 下载/导入完成后都会核对**字节数 + SHA256**，对不上就删掉并报错，绝不半信半疑地喂给模型。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/app_paths.dart';

/// 一个下载源（同一个文件的多个镜像）
class PackSource {
  /// 界面上显示的名字，例如「镜像 hf-mirror.com」
  final String label;
  final String url;

  /// 需要 HuggingFace token（门控模型：用户得先在模型页接受协议）
  final bool gated;

  const PackSource(this.label, this.url, {this.gated = false});
}

/// 一个可选包的描述
class ModelPackSpec {
  final String id;
  final String title;
  final String subtitle;

  /// 落地文件名（放在包目录下）
  final String fileName;

  /// 下载源，**按顺序尝试**（国内手机连不上 huggingface.co，所以镜像放前面）
  final List<PackSource> sources;

  /// 期望字节数（>0 时校验）
  final int bytes;

  /// 期望 SHA256（十六进制小写；为空则只校验字节数）
  final String sha256;

  final String license;
  final String attribution;

  /// 网盘分享页（夸克/百度等）。大文件放网盘、用户自己取，App 只负责**跳转**。
  /// 与 [sources]（可直连下载的源）互补：网盘不能程序化下载，所以只给按钮。
  final String? netdiskUrl;

  /// 网盘按钮上的文案
  final String netdiskLabel;

  /// 非商用许可：界面上必须显著提示（MuScriptor 是 CC BY-NC 4.0）
  final bool nonCommercial;

  /// 用户需要先在这个页面接受协议（门控模型）
  final String? licensePage;

  const ModelPackSpec({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.fileName,
    required this.bytes,
    required this.sha256,
    required this.license,
    required this.attribution,
    this.sources = const [],
    this.nonCommercial = false,
    this.licensePage,
    this.netdiskUrl,
    this.netdiskLabel = '从网盘下载',
  });

  /// 有没有门控源（需要 token）
  bool get needsToken => sources.any((s) => s.gated);

  /// 主下载源（没有源 = 只能本地导入）
  PackSource? get primarySource => sources.isEmpty ? null : sources.first;

  /// 兼容旧调用：主源地址
  String? get url => primarySource?.url;

  bool get downloadable => sources.isNotEmpty;

  /// 有没有网盘分享页
  bool get hasNetdisk => netdiskUrl != null && netdiskUrl!.isNotEmpty;
}

/// 包状态
enum PackState { missing, downloading, ready, invalid }

/// 下载进度
class PackProgress {
  final int received;
  final int total; // 0 = 未知
  const PackProgress(this.received, this.total);

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

/// ByteDance 高分辨率钢琴转写 CRNN（Kong et al. 2021）
///
/// · 输入：原始波形 float32 [1, 160000]（单声道 16kHz，正好 10 秒；mel 前端在图里）
/// · 输出：reg_onset / reg_offset / frame / velocity 各 [1, 1001, 88] + 踏板
/// · 实测（本机 RTX 4070 / CPU，探针 `tools/piano_crnn_probe/`）：
///     合成和弦 recall 100% / precision 83%（Basic Pitch 86~91%）
///     90 秒真实钢琴录音 11.6s 推理（0.13× 实时）
///     DirectML 走 GPU 反而更慢（13.7s），小模型不该上 GPU
///
/// 下载源**镜像优先**：实测国内手机连 huggingface.co 会失败；
/// `hf-mirror.com` 是它的公开镜像（同一个文件的 CDN 回源，字节数一致）。
/// 无论从哪个源下，落地前都会核对 **字节数 + SHA256**，镜像给错文件也会被拒。
const ModelPackSpec kPianoCrnnPack = ModelPackSpec(
  id: 'piano_crnn',
  title: '高精度钢琴（CRNN）',
  subtitle: '钢琴独奏/和弦专用，带踏板建模；147MB，比内置模型慢一些',
  fileName: 'piano_crnn.onnx',
  sources: [
    PackSource('镜像 hf-mirror.com',
        'https://hf-mirror.com/stelee/piano-transcription-onnx/resolve/main/piano_crnn.onnx'),
    PackSource('官方 huggingface.co',
        'https://huggingface.co/stelee/piano-transcription-onnx/resolve/main/piano_crnn.onnx'),
  ],
  bytes: 154206740,
  sha256: '743cf9fc88d1c24e5d4cc7a47ba55abd5c52c8623274355d79a981955fbbea99',
  license: 'MIT',
  attribution: 'Qiuqiang Kong et al., "High-resolution Piano Transcription with Pedals", '
      'IEEE/ACM TASLP 2021（ONNX 转换：stelee）',
);

/// Tsumugi 乐器无关转写（神经半-CRF）
///
/// · 权重：anime-song/instrument_agnostic_amt 的 best_model.pth（53.5MB，MIT）
/// · ONNX 由本仓库导出（`tools/onnx_export/probe_tsumugi_export.py`），
///   产物是 **两个文件**：`tsumugi_amt.onnx` + `tsumugi_amt.onnx.data`（外部权重，必须同目录）
/// · 网上没有现成下载，所以放在**夸克网盘**分享；App 里的按钮直接跳转过去，
///   用户取回两个文件后用「从文件导入」装进来（导入会自动带上同目录的 `.data` ✓）
/// · 官方定位：乐器无关、干净且偏单声部的素材最擅长 → 适合"听歌扒谱"那条路
const ModelPackSpec kTsumugiPack = ModelPackSpec(
  id: 'tsumugi',
  title: '通用乐器（Tsumugi）',
  subtitle: '乐器无关（人声/吉他/弦乐/管乐），偏单声部素材更准；体积小',
  fileName: 'tsumugi_amt.onnx',
  sources: [],
  bytes: 0,
  sha256: '',
  license: 'MIT',
  attribution: 'anime-song/tsumugi — Neural Semi-CRF Automatic Music Transcription',
  // 用户提供的网盘分享（夸克）：放的是 tsumugi_amt.onnx 与 tsumugi_amt.onnx.data
  netdiskUrl: 'https://pan.quark.cn/s/900bc47212c4',
  netdiskLabel: '从夸克网盘下载（tsumugi_amt.onnx 与 .onnx.data 一起导入）',
);

const List<ModelPackSpec> kModelPacks = [
  kPianoCrnnPack,
  kTsumugiPack,
  kMuScriptorPack,
  kSeparatorSmallPack,
  kSeparatorLargePack,
  kMnnModelPack,
];

/// 自定义 **MNN 模型**（实验）：把 `.mnn` 文件纳入包管理，等 MNN 运行时接上就能直接用。
///
/// 现状（如实写在界面上）：
///   · MNN 运行时（FFI）**尚未接入** —— 实测两个自带模型都过不了 MNN 的转换
///     （CRNN 图有控制流 `While`、Tsumugi 报 `Framework Input ERROR`），
///     详见 `docs/和弦识别-测量记录.md` 的"MNN 后端：实测结论"；
///   · 但 MNN 官方有 QNN / Hexagon / NNAPI 后端，将来遇到"只有 .mnn 格式"的模型时，
///     这个槽位直接可用（届时只需实现一个 `MnnRuntime`，界面与注册表不用改）。
const ModelPackSpec kMnnModelPack = ModelPackSpec(
  id: 'mnn_custom',
  title: 'MNN 模型（实验）',
  subtitle: '导入 .mnn 文件；MNN 运行时尚未接入，先做文件管理（可删除）',
  fileName: 'custom_model.mnn',
  sources: [],
  bytes: 0,
  sha256: '',
  license: '按模型自身许可',
  attribution: '用户自行提供（MNN 格式）',
);

/// 人声分离（**小**）：UVR-MDX-NET KARA2 的 ONNX 图，50.8MB，MIT ✓
///
/// 用途：扒谱前把**人声**分出去，用剩下的伴奏转谱（用户明确要求"用伴奏转谱"）。
/// 手机、电脑都能跑（单次前向、固定段长），所以默认推荐这个。
const ModelPackSpec kSeparatorSmallPack = ModelPackSpec(
  id: 'separator_small',
  title: '人声分离·小（UVR-MDX KARA2）',
  subtitle: '50.8MB · MIT · 手机也跑得动；扒谱前分出人声，用伴奏转谱',
  fileName: 'uvr_kara2.onnx',
  sources: [
    PackSource('镜像 hf-mirror.com',
        'https://hf-mirror.com/musetric/uvr-mdxnet-kara2-onnx/resolve/main/kara2.onnx'),
    PackSource('官方 huggingface.co',
        'https://huggingface.co/musetric/uvr-mdxnet-kara2-onnx/resolve/main/kara2.onnx'),
  ],
  bytes: 53249592,
  sha256: '',
  license: 'MIT',
  attribution: 'UVR-MDX-NET KARA2（Ultimate Vocal Remover 项目）的 ONNX 转换：musetric',
);

/// 人声分离（**大**）：htdemucs（Demucs v4）的 ONNX 图，172MB
///
/// ⚠️ **许可未标注**（转换仓库没写；原始 Demucs 项目是 MIT）。
/// 用户要求"小的大的都做成可选、自己决策"，所以照做，但必须如实标注这一点。
const ModelPackSpec kSeparatorLargePack = ModelPackSpec(
  id: 'separator_large',
  title: '人声分离·大（htdemucs）',
  subtitle: '172MB · 许可未标注（原 Demucs 为 MIT）· 质量更好，建议桌面端',
  fileName: 'htdemucs_embedded.onnx',
  sources: [
    PackSource('镜像 hf-mirror.com',
        'https://hf-mirror.com/timcsy/demucs-web-onnx/resolve/main/htdemucs_embedded.onnx'),
    PackSource('官方 huggingface.co',
        'https://huggingface.co/timcsy/demucs-web-onnx/resolve/main/htdemucs_embedded.onnx'),
  ],
  bytes: 180534758,
  sha256: '',
  license: '未标注（原 Demucs 项目 MIT）',
  attribution: 'htdemucs（Demucs v4，Meta）的 ONNX 转换：timcsy/demucs-web-onnx',
);

/// MuScriptor（Kyutai × Mirelo，多乐器）
///
/// ⚠️ **权重是 CC BY-NC 4.0（禁止商用）且 HuggingFace 门控**（实测不带 token 直接 401）。
/// 所以：App **不内嵌、不代下**，要么用户自己在模型页接受协议后填 token 下载，
/// 要么自己下好再用"从文件导入"。界面上必须把这两点讲清楚。
///
/// 规格：small = 103M 参数 / 392.8MB safetensors（medium 307M / 1.1GB 太大，不提供）。
/// 架构是 **decoder-only Transformer**（自回归逐 token 解码），所以手机端速度要实测；
/// ONNX 导出尚未做（需要拿到权重；导出器与 Tsumugi 同理）。
const ModelPackSpec kMuScriptorPack = ModelPackSpec(
  id: 'muscriptor',
  title: 'MuScriptor（多乐器·非商用）',
  subtitle: 'Kyutai × Mirelo 的多乐器模型（small，392.8MB）；许可为非商用，需自备 token',
  fileName: 'muscriptor_small.safetensors',
  sources: [
    PackSource(
      'HuggingFace（需 token）',
      'https://huggingface.co/MuScriptor/muscriptor-small/resolve/main/model.safetensors',
      gated: true,
    ),
  ],
  // 门控模型没法预置校验值（用户拿到的是同一份，但我们无法先验证），
  // 所以只做"下完大小合理性检查"，不做 SHA256 —— 界面上会说明这一点。
  bytes: 411879424,
  sha256: '',
  license: 'CC BY-NC 4.0（非商用）',
  nonCommercial: true,
  licensePage: 'https://huggingface.co/MuScriptor/muscriptor-small',
  attribution: 'MuScriptor: An Open Model for Multi-Instrument Music Transcription（Kyutai / Mirelo）',
);

/// 扒谱引擎选择
enum TranscribeEngine {
  /// 内置纯 Dart 算法（体积最小，适合干净的单声部哼唱）
  builtin,

  /// 内置 Basic Pitch（230KB，默认；和弦 recall 100% / precision 86~91%）
  basicPitch,

  /// 可选包：钢琴专用 CRNN（踏板/力度，钢琴独奏更合适）
  pianoCrnn,

  /// 可选包：Tsumugi 乐器无关（偏单声部素材，适合听歌扒谱）
  tsumugi,
}

extension TranscribeEngineInfo on TranscribeEngine {
  String get label => switch (this) {
        TranscribeEngine.builtin => '内置算法',
        TranscribeEngine.basicPitch => 'Basic Pitch（内置）',
        TranscribeEngine.pianoCrnn => '高精度钢琴（增强包）',
        TranscribeEngine.tsumugi => '通用乐器（增强包）',
      };

  String get blurb => switch (this) {
        TranscribeEngine.builtin =>
          '纯 Dart 基频跟踪 + 显著度：体积最小，适合干净的单声部哼唱，对混音/和弦较弱。',
        TranscribeEngine.basicPitch =>
          'Spotify Basic Pitch（Apache-2.0，230KB）：自带 CQT 前端，混音/复调/哼唱都稳，秒级、免下载。',
        TranscribeEngine.pianoCrnn =>
          '钢琴专用 CRNN（MIT）：带踏板与力度建模，钢琴独奏/和弦更完整；比内置慢一些，需下载。',
        TranscribeEngine.tsumugi =>
          'Tsumugi 乐器无关转写（MIT）：人声/吉他/弦乐/管乐同一模型，偏干净单声部素材更准，体积小。',
      };

  /// 这个引擎对应的可选包（内置引擎为 null）
  ModelPackSpec? get pack => switch (this) {
        TranscribeEngine.pianoCrnn => kPianoCrnnPack,
        TranscribeEngine.tsumugi => kTsumugiPack,
        _ => null,
      };

  bool get needsPack => pack != null;

  /// 这个引擎当前**能不能选**。
  ///
  /// Tsumugi 暂时不可用：它的解码核心是神经半-CRF 的动态规划（`semi_crf.py` 85.7KB，
  /// `@torch.jit.script` + 数据相关控制流），**导不出 ONNX**；
  /// 要接入只能"只导出骨干 + 在 Dart 里重写 DP"，属于独立项目。
  /// 详见 `docs/和弦识别-测量记录.md`。
  bool get available => this != TranscribeEngine.tsumugi;
}

/// 包目录管理：下载、导入、校验、删除
class ModelPackStore {
  /// 包目录（生产环境用 `path_provider` 的 app support 目录；测试里给临时目录）
  final Directory root;

  /// 允许注入，测试里指向本地 HTTP 服务
  final Future<HttpClient> Function() clientFactory;

  ModelPackStore({required this.root, Future<HttpClient> Function()? clientFactory})
      : clientFactory = clientFactory ?? (() async => HttpClient());

  /// **App 实际使用的包目录**：`<应用数据目录>/离谱/packs`。
  ///
  /// 界面和后端都必须走这一个入口，否则会出现"界面说已安装、后端说没装"这种对不上的情况
  /// （用户实测踩到过：CRNN 显示已安装，识别时报"增强包未安装"）。
  factory ModelPackStore.forApp() =>
      ModelPackStore(root: Directory('${AppPaths.outputDir().path}${Platform.pathSeparator}packs'));

  File fileOf(ModelPackSpec spec) => File('${root.path}/${spec.fileName}');

  File partOf(ModelPackSpec spec) => File('${root.path}/${spec.fileName}.part');

  Future<void> ensureDir() async {
    if (!root.existsSync()) await root.create(recursive: true);
  }

  /// 已装好就返回文件，否则 null。
  ///
  /// [ModelPackSpec.bytes] 是**严格**校验：大小对不上就算没装
  /// （半截模型拿去推理只会出怪音）。但现实里用户拿到的文件可能只是版本略有差异
  /// （镜像重新导出过等），所以允许用户**显式忽略大小检查**（[accept]）：
  /// 那时只要求文件存在，真正的可用性交给 onnxruntime 去报错
  /// ——它给的错误比一句"未安装"清楚得多。
  File? installedFile(ModelPackSpec spec) {
    final f = fileOf(spec);
    if (!f.existsSync()) return null;
    if (spec.bytes > 0 && !isAccepted(spec) && f.lengthSync() != spec.bytes) return null;
    return f;
  }

  /// 用户点过"忽略大小检查仍要使用"的标记
  File _acceptMarker(ModelPackSpec spec) => File('${root.path}/${spec.fileName}.accept');

  bool isAccepted(ModelPackSpec spec) => _acceptMarker(spec).existsSync();

  /// 记下"用户接受这个文件"（大小可能与规格不一致）
  Future<void> accept(ModelPackSpec spec) async {
    await ensureDir();
    final f = fileOf(spec);
    await _acceptMarker(spec).writeAsString(
      '${DateTime.now().toIso8601String()}\n'
      '实际 ${f.existsSync() ? f.lengthSync() : 0} 字节 / 规格 ${spec.bytes} 字节\n',
    );
  }

  /// 包状态 + 实际/期望字节数（界面用它把"为什么未安装"说清楚）
  ({PackState state, int actual, int expected}) detailOf(ModelPackSpec spec) {
    final f = fileOf(spec);
    if (!f.existsSync()) {
      return (
        state: partOf(spec).existsSync() ? PackState.downloading : PackState.missing,
        actual: partOf(spec).existsSync() ? partOf(spec).lengthSync() : 0,
        expected: spec.bytes,
      );
    }
    final actual = f.lengthSync();
    if (spec.bytes > 0 && actual != spec.bytes && !isAccepted(spec)) {
      return (state: PackState.invalid, actual: actual, expected: spec.bytes);
    }
    return (state: PackState.ready, actual: actual, expected: spec.bytes);
  }

  Future<PackState> stateOf(ModelPackSpec spec) async => detailOf(spec).state;

  /// 下载（**多源回退 + 断点续传**）。
  ///
  /// 依次尝试 [ModelPackSpec.sources]：某个源连不上/中途断了，就带着已经下好的
  /// `.part` 换下一个源**续传**（Range 是文件级的，换源也能接上）。
  /// 全部源都失败才抛错，并保留 `.part` 供下次继续。
  ///
  /// 落地前核对字节数与 SHA256：**这一步也顺带兜住了镜像的风险** ——
  /// 镜像给错/给坏文件都会被拒，不会拿一个来路不明的模型去推理。
  Future<File> download(
    ModelPackSpec spec, {
    void Function(PackProgress)? onProgress,
    void Function(String stage)? onStage,
    String? token,
  }) async {
    if (spec.sources.isEmpty) {
      throw StateError('${spec.title} 没有在线地址，请用"从文件导入"');
    }
    await ensureDir();
    final part = partOf(spec);
    var received = part.existsSync() ? part.lengthSync() : 0;
    if (spec.bytes > 0 && received == spec.bytes) {
      return _finalize(spec, part); // 上次其实已经下完了，只是没改名
    }
    if (spec.bytes > 0 && received > spec.bytes) {
      await part.delete(); // 比目标还大，缓存坏了
      received = 0;
    }

    Object? lastError;
    for (var i = 0; i < spec.sources.length; i++) {
      final source = spec.sources[i];
      try {
        onStage?.call(received > 0
            ? '从 ${source.label} 续传（已下 ${(received / 1048576).toStringAsFixed(1)}MB）…'
            : '从 ${source.label} 下载…');
        if (source.gated && (token == null || token.isEmpty)) {
          throw StateError('${source.label} 需要先在模型页接受协议，再填 HuggingFace token');
        }
        await _fetchFrom(source.url, part, spec, onProgress, onStage,
            token: source.gated ? token : null);
        return await _finalize(spec, part);
      } catch (e) {
        lastError = e;
        received = part.existsSync() ? part.lengthSync() : 0;
        final more = i < spec.sources.length - 1;
        onStage?.call('${source.label} 失败：${_short(e)}${more ? "，换下一个下载源" : ""}');
        if (!more) break;
      }
    }
    final hint = received > 0
        ? '（已下 ${(received / 1048576).toStringAsFixed(1)}MB，下次可续传）'
        : '';
    throw StateError('所有下载源都不可用：${_short(lastError)}$hint');
  }

  /// 从单个源拉全量（内部会续传直到收够）
  Future<void> _fetchFrom(
    String url,
    File part,
    ModelPackSpec spec,
    void Function(PackProgress)? onProgress,
    void Function(String stage)? onStage, {
    String? token,
  }) async {
    final client = await clientFactory();
    client.connectionTimeout = const Duration(seconds: 30);
    try {
      var received = part.existsSync() ? part.lengthSync() : 0;
      var guard = 0;
      while (guard++ < 500) {
        final req = await client.getUrl(Uri.parse(url));
        if (token != null && token.isNotEmpty) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        if (received > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
        final res = await req.close();
        if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          // 服务器说"没有更多可给了"：本地可能已经收够（或超出规格）
          await res.drain<void>();
          break;
        }
        if (res.statusCode != 200 && res.statusCode != 206) {
          throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
        }
        final total = res.contentLength > 0
            ? (res.statusCode == 206 ? received + res.contentLength : res.contentLength)
            : spec.bytes;
        final sink = part.openSync(
            mode: received > 0 && res.statusCode == 206 ? FileMode.append : FileMode.write);
        var got = received;
        try {
          await for (final chunk in res) {
            sink.writeFromSync(chunk);
            got += chunk.length;
            onProgress?.call(PackProgress(got, total));
          }
        } finally {
          sink.closeSync();
        }
        final delta = got - received;
        received = got;
        if (spec.bytes <= 0 || received >= spec.bytes) break;
        if (delta <= 0) break; // 这一轮没涨：别死循环
        onStage?.call('已下载 ${(received / 1048576).toStringAsFixed(1)}MB，继续…');
      }
    } finally {
      client.close(force: true);
    }
  }

  static String _short(Object? e) {
    final s = '$e';
    return s.length <= 80 ? s : '${s.substring(0, 80)}…';
  }

  /// 把用户选的文件导入包目录。
  ///
  /// **必须连附属文件一起拷**：ONNX 的外部权重（`xxx.onnx.data`）如果没跟着过来，
  /// onnxruntime 会直接加载失败——用户"两个文件同目录也导入失败"就是这么来的。
  /// 所以这里：
  ///   1. [extra] 里用户一起选中的文件全部拷进来（多选导入）；
  ///   2. 没给的话，**自动在主文件同目录里找**同名附属文件（`.data`、`.onnx.data` 等）。
  ///
  /// 主文件按 [ModelPackSpec.fileName] 落地，附属文件保持原名。
  Future<File> import(ModelPackSpec spec, File source, {List<File> extra = const []}) async {
    await ensureDir();
    // 主文件：可能是用户选的，也可能是 .data（用户先点到了权重）——认扩展名
    var primary = source;
    final all = <File>[source, ...extra];
    final onnx = all.where((f) => f.path.toLowerCase().endsWith('.onnx')).toList();
    if (onnx.isNotEmpty) primary = onnx.first;

    // 附属文件 = 其它所有文件 + 同目录自动发现的同名附属
    final sidecars = <File>{
      for (final f in all)
        if (f.path != primary.path) f,
      ..._discoverSidecars(primary),
    };

    final dest = fileOf(spec);
    if (dest.existsSync()) await dest.delete();
    await primary.copy(dest.path);
    for (final side in sidecars) {
      final target = File('${root.path}/${_basename(side.path)}');
      if (target.path == dest.path) continue;
      if (target.existsSync()) await target.delete();
      await side.copy(target.path);
    }
    return _finalize(spec, dest, alreadyInPlace: true);
  }

  /// 找主文件同目录下的附属文件（`x.onnx` → `x.onnx.data`、`x.data`、`x.onnx.data.*`）
  static List<File> _discoverSidecars(File primary) {
    final dir = primary.parent;
    if (!dir.existsSync()) return const [];
    final base = _basename(primary.path);
    final out = <File>[];
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = _basename(f.path);
      if (name == base) continue;
      if (name.startsWith('$base.') || name.startsWith('${base}_')) out.add(f);
    }
    return out;
  }

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  /// 这个包里现在有哪些文件（界面用来显示"装了几个文件"）。
  ///
  /// 注意：**附属文件保持原文件名**，不能改成 `<主文件>.data` ——
  /// ONNX 里存的外部权重路径是相对模型目录的**原始名字**，改名就加载不了 ✗。
  /// 所以这里按"主文件 + 主文件名前缀 + 任何 .data"来列举，只用于显示。
  List<String> installedFiles(ModelPackSpec spec) {
    if (!root.existsSync()) return const [];
    final base = spec.fileName;
    final stem = base.contains('.') ? base.substring(0, base.indexOf('.')) : base;
    final out = <String>[];
    for (final f in root.listSync()) {
      if (f is! File) continue;
      final name = _basename(f.path);
      if (name == base ||
          name.startsWith('$base.') ||
          name.endsWith('.data') ||
          (stem.isNotEmpty && name.startsWith(stem))) {
        out.add(name);
      }
    }
    return out;
  }

  Future<void> delete(ModelPackSpec spec) async {
    final f = fileOf(spec);
    if (f.existsSync()) await f.delete();
    final p = partOf(spec);
    if (p.existsSync()) await p.delete();
  }

  /// 校验并"转正"：字节数 + SHA256 都对得上才算装好
  Future<File> _finalize(ModelPackSpec spec, File file, {bool alreadyInPlace = false}) async {
    if (!file.existsSync()) {
      throw StateError('没有下到任何数据（${spec.title}），请检查网络后重试');
    }
    if (spec.bytes > 0 && file.lengthSync() != spec.bytes) {
      final got = file.lengthSync();
      if (!alreadyInPlace) await file.delete();
      throw StateError('文件不完整：$got / ${spec.bytes} 字节');
    }
    if (spec.sha256.isNotEmpty) {
      final digest = await _sha256Of(file);
      if (digest != spec.sha256) {
        if (file.existsSync()) await file.delete();
        throw StateError('校验失败：SHA256 不匹配（文件可能损坏或不是这个模型）');
      }
    }
    if (!alreadyInPlace && !file.path.endsWith(spec.fileName)) {
      final dest = fileOf(spec);
      if (dest.existsSync()) await dest.delete();
      await file.rename(dest.path);
      return dest;
    }
    if (file.path.endsWith('.part')) {
      final dest = fileOf(spec);
      if (dest.existsSync()) await dest.delete();
      await file.rename(dest.path);
      return dest;
    }
    return file;
  }

  /// 流式算 SHA256（147MB 也不会把内存吃满）
  static Future<String> sha256OfFile(File file) => _sha256Of(file);

  static Future<String> _sha256Of(File file) async {
    final sink = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.events.single.toString();
  }

  /// 供界面显示的一句话（大小 + 许可证）
  /// 这个包要不要 token（门控模型）
  static bool needsToken(ModelPackSpec spec) => spec.needsToken;

  static String describe(ModelPackSpec spec) {
    final size = spec.bytes > 0 ? '${(spec.bytes / 1048576).toStringAsFixed(0)}MB' : '体积未知';
    return '$size · ${spec.license}';
  }
}

/// 收集 chunked conversion 的结果
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];
  @override
  void add(T data) => events.add(data);
  @override
  void close() {}
}

/// 把包信息写成给用户看的多行说明（设置界面用）
String packDetailLines(ModelPackSpec spec, PackState state) {
  final buf = StringBuffer()
    ..writeln(spec.subtitle)
    ..writeln('来源：${spec.attribution}')
    ..writeln('许可证：${spec.license}');
  switch (state) {
    case PackState.ready:
      buf.write('状态：已安装');
    case PackState.downloading:
      buf.write('状态：下载中断，可继续');
    case PackState.invalid:
      buf.write('状态：文件不完整，请重新下载');
    case PackState.missing:
      buf.write(spec.url == null ? '状态：未安装（需从文件导入）' : '状态：未安装');
  }
  return buf.toString();
}

/// 供测试/日志用的简短 JSON
String packStateJson(ModelPackSpec spec, PackState state) => jsonEncode({
      'id': spec.id,
      'state': state.name,
      'bytes': spec.bytes,
    });
