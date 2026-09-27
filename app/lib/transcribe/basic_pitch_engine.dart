/// Basic Pitch（Spotify，Apache-2.0）识别引擎。
///
/// 数据流：音频 → ONNX Runtime 跑 `basic_pitch.onnx` → 去重叠拼接 → 峰值解码
///         → 音符事件 →（可选）主旋律提取 → [MelodyAnalysis] → 量化成简谱/五线谱
///
/// 模型很小（约 230KB），自带 CQT 前端，输入就是 22050Hz 单声道 PCM，
/// 因此 Windows 与 Android 都能**离线**跑，不需要 Python 或联网。
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'basic_pitch.dart';
import 'melody.dart';
import 'spectral_verify.dart';

// 泛音去重与主旋律提取是纯 DSP 后处理，放在 melody.dart 里；
// 这里转出去，老的 `import 'basic_pitch_engine.dart'` 仍然能用。
export 'melody.dart' show dropHarmonicGhosts, pickMelodyNotes;

/// 解码请求（丢到后台 isolate 里跑，避免大矩阵运算卡住界面）
class _DecodeRequest {
  final Float32List frames;
  final Float32List onsets;
  final int nFrames;
  final BasicPitchParams params;
  const _DecodeRequest(this.frames, this.onsets, this.nFrames, this.params);
}

List<BasicPitchNote> _decodeInIsolate(_DecodeRequest req) => decodeNotes(
      frameData: req.frames,
      onsetData: req.onsets,
      nFrames: req.nFrames,
      params: req.params,
    );

class BasicPitchEngine {
  /// 模型资源路径（`pubspec.yaml` 里的 assets/models/）
  static const String modelAsset = 'assets/models/basic_pitch.onnx';
  static const String modelLicense = 'Apache-2.0（Spotify AB）';

  /// 与 `inference.py` 中 ONNX 分支的输入/输出名一致
  static const String _inputName = 'serving_default_input_2:0';
  static const String _noteOutput = 'StatefulPartitionedCall:1';
  static const String _onsetOutput = 'StatefulPartitionedCall:2';

  OrtSession? _session;
  String? _error;

  bool get ready => _session != null;
  String? get error => _error;

  /// 载入模型（第一次调用会从 assets 解压到临时目录并缓存）
  Future<bool> ensureLoaded() async {
    if (_session != null) return true;
    if (_error != null) return false;
    try {
      final runtime = OnnxRuntime();
      _session = await runtime.createSessionFromAsset(
        modelAsset,
        // 4 线程：桌面端能明显加速，手机端也不会因为抢满核心而过热
        options: OrtSessionOptions(intraOpNumThreads: 4),
      );
      return true;
    } catch (e) {
      _error = '$e';
      return false;
    }
  }

  Future<void> dispose() async {
    final s = _session;
    _session = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {
        // 关闭失败不影响退出
      }
    }
  }

  /// 跑完整套识别。[onProgress] 的 fraction 是 0~1。
  Future<List<BasicPitchNote>> transcribe(
    Float64List samples, {
    BasicPitchParams params = const BasicPitchParams(),
    void Function(double fraction, String stage)? onProgress,
  }) async {
    if (samples.isEmpty) return const [];
    if (!await ensureLoaded()) {
      throw StateError('Basic Pitch 模型加载失败：${_error ?? "未知原因"}');
    }
    final session = _session!;

    // Float64 → Float32（模型输入是 float32）
    final audio = Float32List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      audio[i] = samples[i];
    }

    final starts = windowStarts(audio.length);
    final noteWindows = <Float32List>[];
    final onsetWindows = <Float32List>[];

    for (var w = 0; w < starts.length; w++) {
      final window = extractWindow(audio, starts[w]);
      final input = await OrtValue.fromList(window, const [1, BpConst.audioNSamples, 1]);
      Map<String, OrtValue> outputs;
      try {
        outputs = await session.run({_inputName: input});
      } finally {
        await input.dispose();
      }
      try {
        final note = outputs[_noteOutput];
        final onset = outputs[_onsetOutput];
        if (note == null || onset == null) {
          throw StateError('模型输出缺少 note/onset 张量');
        }
        noteWindows.add(_toFloat32(await note.asFlattenedList()));
        onsetWindows.add(_toFloat32(await onset.asFlattenedList()));
      } finally {
        for (final v in outputs.values) {
          try {
            await v.dispose();
          } catch (_) {
            // 释放失败忽略
          }
        }
      }
      onProgress?.call((w + 1) / starts.length * 0.85, 'Basic Pitch 推理 ${w + 1}/${starts.length}');
      // 让出事件循环，界面与进度条保持响应
      await Future<void>.delayed(Duration.zero);
    }

    final noteFrames = unwrapFrames(noteWindows, BpConst.nNoteBins, audio.length);
    final onsetFrames = unwrapFrames(onsetWindows, BpConst.nNoteBins, audio.length);
    final nFrames = noteFrames.length ~/ BpConst.nNoteBins;
    if (nFrames <= 0) return const [];

    onProgress?.call(0.9, '解码音符事件');
    final notes = await compute(
      _decodeInIsolate,
      _DecodeRequest(noteFrames, onsetFrames, nFrames, params),
    );
    onProgress?.call(1, '识别完成');
    return notes;
  }
}

Float32List _toFloat32(List<dynamic> values) {
  final out = Float32List(values.length);
  for (var i = 0; i < values.length; i++) {
    final v = values[i];
    out[i] = v is num ? v.toDouble() : 0;
  }
  return out;
}

/* ------------------------------------------------------------------ *
 * 从 Basic Pitch 结果构造通用分析结果
 * ------------------------------------------------------------------ */

/// 把 Basic Pitch 的音符事件转成通用的 [MelodyAnalysis]。
///
/// [melodyOnly] 为真时先做一次**主旋律提取**（适合听歌扒谱：去掉伴奏与低音声部）；
/// 为假时保留全部音符（适合钢琴等复调，界面上可以逐个删）。
MelodyAnalysis analysisFromBasicPitch(
  List<BasicPitchNote> raw, {
  required int sampleRate,
  required double durationSec,
  bool melodyOnly = true,
  bool mixMode = true,
  bool includePitchClass = true,
  Float64List? samples,
}) {
  final nFrames = raw.isEmpty ? 0 : raw.map((n) => n.endFrame).reduce((a, b) => a > b ? a : b) + 1;
  final times = modelFramesToTime(nFrames);

  double timeAt(int frame) => frame < times.length ? times[frame] : (frame * BpConst.fftHop / BpConst.sampleRate);

  var notes = <DetectedNote>[];
  for (final n in raw) {
    final start = timeAt(n.startFrame);
    final end = timeAt(n.endFrame);
    if (end - start <= 0.01) continue;
    notes.add(DetectedNote(
      startSec: start,
      endSec: end,
      midi: n.midi.toDouble(),
      confidence: n.amplitude.clamp(0.0, 1.0),
    ));
  }
  notes.sort((a, b) => a.startSec.compareTo(b.startSec));

  // 同一音高被重复报出的（滑动窗口拼接的副产物）先合并掉：这一步纯赚，两种模式都做
  notes = mergeDuplicateNotes(notes);

  if (melodyOnly) {
    // 主旋律模式：内部已含泛音去重 + 声部跟踪
    notes = pickMelodyNotes(notes);
  } else if (samples != null && samples.isNotEmpty) {
    // 复调（钢琴/和弦）模式：用**频谱残差**去掉泛音鬼影——
    // 响度/时长分不出"真八度叠置"和"泛音鬼影"（实测两者完全重叠），
    // 只有"这个频率处的能量是否高于低音谐波包络的预测"能分开。
    notes = dropHarmonicGhostsSpectral(notes, samples, sampleRate: sampleRate);
  }

  final bpm = estimateTempo(notes, Float64List(0), 0.01);
  final key = estimateKey(notes);

  // 钢琴卷帘的背景轨迹：每 20ms 取当时最高的音
  final track = <PitchPoint>[];
  const stepSec = 0.02;
  var cursor = 0;
  for (var t = 0.0; t < durationSec; t += stepSec) {
    while (cursor < notes.length && notes[cursor].endSec < t) {
      cursor++;
    }
    var best = 0.0;
    var conf = 0.0;
    var level = 0.0;
    for (var i = cursor; i < notes.length && notes[i].startSec <= t; i++) {
      final n = notes[i];
      if (n.endSec <= t) continue;
      if (n.midi >= best) {
        best = n.midi;
        conf = n.confidence;
        level = n.confidence;
      }
    }
    track.add(PitchPoint(t, best, conf, level));
  }

  return MelodyAnalysis(
    notes: notes,
    track: track,
    sampleRate: sampleRate,
    durationSec: durationSec,
    bpm: bpm,
    keyName: key.$1,
    mode: key.$2,
    hopSec: stepSec,
    mixMode: mixMode,
  );
}

