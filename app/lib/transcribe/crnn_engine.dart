/// ByteDance 高分辨率钢琴转写（CRNN）的 Dart 推理 + 解码。
///
/// 模型（可选包 `kPianoCrnnPack`，MIT，Kong et al. 2021）：
///   · 输入  `audio` float32 [1, 160000] —— 单声道 **16kHz、正好 10 秒**，mel 前端在图里
///   · 输出  `reg_onset` / `reg_offset` / `frame` / `velocity` 各 [1, 1001, 88]（100fps × 88 键，A0=MIDI 21）
///           + 三路踏板输出（当前不使用）
///
/// 解码是论文里的"回归式"做法：onset 出现在 `reg_onset>0.5` 的帧上，
/// 那一帧的值是**帧内位置**（0~1），所以真实时间是 `(帧号 + 值) / 100`；
/// offset 同理取 onset 之后第一个 `reg_offset>0.5` 的帧。
/// 这里额外用 `frame`（持续发声）做一次校验，把"只有起音没有持续"的鬼影滤掉。
///
/// 实测（本机，`tools/piano_crnn_probe/`）：90 秒真实钢琴录音推理 11.6s（CPU）；
/// 合成和弦 recall 100% / precision 86%（Basic Pitch 91%，各有各的鬼影）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'melody.dart';

/// 模型常量
class CrnnConst {
  static const int sampleRate = 16000;
  static const int segmentSamples = 160000; // 10 秒
  static const int framesPerSegment = 1001; // 100 fps
  static const int keyBase = 21; // A0
  static const int keyCount = 88;

  /// 帧号 → 秒
  static const double frameSec = 1 / 100;

  static int midiOf(int key) => keyBase + key;
  static int keyOf(int midi) => midi - keyBase;
}

/// 从模型输出解出音符。
///
/// **这份实现是官方解码器的 1:1 移植**，不是自己发明的（教训见
/// `docs/和弦识别-测量记录.md`：手写版连撞两次墙）：
///   · 二值化 + 帧内位置修正 ← `utilities.py: get_binarized_output_from_regression`
///     （含 `is_monotonic_neighbour` 邻域去抖；位置**不是**回归值本身，
///      而是由左右邻帧算出的 shift）
///   · 音符配对 ← `piano_vad.py: note_detection_with_onset_offset_regress`
///     （offset 的取舍是"`offset_occur` 与 `frame_disappear` 谁离起点更近"，
///      不是最短时长阈值）
///
/// 唯一有意的偏离：官方写 `if bgn:`，Python 里 `0` 为假，正好从第 0 帧起的音会被丢掉；
/// 这里用 `bgn >= 0`，只会多出音、不会少音。
///
/// [onset]/[offset]/[frame]/[velocity] 都是行优先的 `frames × keys` 数组。
/// [segStartSec] 是这一段在整首曲子里的起始时间。
List<DetectedNote> decodeCrnnNotes({
  required Float32List onset,
  required Float32List offset,
  required Float32List frame,
  required Float32List velocity,
  required int frames,
  required int keys,
  double segStartSec = 0,
  double onsetThresh = 0.5,
  double offsetThresh = 0.5,
  double frameThresh = 0.3,
  int neighbour = 1,
  double minDurSec = 0.0,
  int maxNoteFrames = 600,
}) {
  final notes = <DetectedNote>[];
  final onsetBin = Uint8List(frames);
  final offsetBin = Uint8List(frames);
  final onsetShift = Float32List(frames);
  final offsetShift = Float32List(frames);

  for (var k = 0; k < keys; k++) {
    _binarize(onset, frames, keys, k, onsetThresh, neighbour, onsetBin, onsetShift);
    _binarize(offset, frames, keys, k, offsetThresh, neighbour, offsetBin, offsetShift);

    var bgn = -1;
    var frameDisappear = -1;
    var offsetOccur = -1;

    void closeNote(int fin) {
      final startSec = segStartSec + (bgn + onsetShift[bgn]) * CrnnConst.frameSec;
      final endSec = segStartSec + (fin + offsetShift[fin]) * CrnnConst.frameSec;
      if (endSec - startSec >= minDurSec) {
        notes.add(DetectedNote(
          startSec: startSec,
          endSec: endSec,
          midi: CrnnConst.midiOf(k).toDouble(),
          confidence:
              velocity.isEmpty ? 0.5 : velocity[bgn * keys + k].clamp(0.0, 1.0),
        ));
      }
      bgn = -1;
      frameDisappear = -1;
      offsetOccur = -1;
    }

    for (var i = 0; i < frames; i++) {
      if (onsetBin[i] == 1) {
        // 连续两个 onset：前一个音在这里收尾（踏板没松、又弹了一个音）
        if (bgn >= 0) closeNote(i - 1 < 0 ? 0 : i - 1);
        bgn = i;
      }
      if (bgn >= 0 && i > bgn) {
        final fv = frame.isEmpty ? 1.0 : frame[i * keys + k];
        if (fv <= frameThresh && frameDisappear < 0) frameDisappear = i;
        if (offsetBin[i] == 1 && offsetOccur < 0) offsetOccur = i;
        if (frameDisappear >= 0) {
          // bgn ---- offset_occur --- frame_disappear → 取 offset_occur
          // bgn --- offset_occur --------- frame_disappear → 取 frame_disappear
          final fin =
              (offsetOccur >= 0 && offsetOccur - bgn > frameDisappear - offsetOccur)
                  ? offsetOccur
                  : frameDisappear;
          closeNote(fin);
        } else if (bgn >= 0 && (i - bgn >= maxNoteFrames || i == frames - 1)) {
          closeNote(i); // 一直没消失也没 offset：按上限截断
        }
      }
    }
  }
  notes.sort((a, b) =>
      a.startSec != b.startSec ? a.startSec.compareTo(b.startSec) : a.midi.compareTo(b.midi));
  return notes;
}

/// 官方 `get_binarized_output_from_regression`：二值化 + 帧内位置修正
void _binarize(
  Float32List reg,
  int frames,
  int keys,
  int k,
  double threshold,
  int neighbour,
  Uint8List outBin,
  Float32List outShift,
) {
  outBin.fillRange(0, frames, 0);
  outShift.fillRange(0, frames, 0);
  double at(int i) => reg[i * keys + k];
  for (var i = neighbour; i < frames - neighbour; i++) {
    final v = at(i);
    if (v <= threshold) continue;
    if (!_isMonotonicNeighbour(at, i, neighbour, frames)) continue;
    outBin[i] = 1;
    final prev = at(i - 1);
    final next = at(i + 1);
    outShift[i] = prev > next
        ? (next - prev) / (v - next) / 2
        : (next - prev) / (v - prev) / 2;
  }
}

/// 官方 `is_monotonic_neighbour`：左右两侧都单调（保证这里是"峰"而不是斜坡）
bool _isMonotonicNeighbour(double Function(int) at, int n, int neighbour, int frames) {
  for (var i = 0; i < neighbour; i++) {
    if (n - i - 1 < 0 || n + i + 1 >= frames) return false;
    if (at(n - i) < at(n - i - 1)) return false;
    if (at(n + i) < at(n + i + 1)) return false;
  }
  return true;
}
/// 合并"同一次触键"被重复报出的事件：**音高相同、起音相差 ≤80ms**。
///
/// 模型对一次触键会连着好几帧报 onset（实测 B4 连续 299~304 帧），逐帧解码就会
/// 排出好几个事件。合并时取最早起音、最晚结束，置信度取最大。
///
/// 阈值取 80ms 而不是更长：相邻和弦（哪怕十六分音符）的起音间隔都远大于它，
/// 不会被误并（Basic Pitch 那条路用的是 150ms，因为它的重复来自滑动窗口拼接）。
List<DetectedNote> mergeSameStrike(List<DetectedNote> notes) {
  if (notes.length < 2) return notes;
  final out = <DetectedNote>[];
  final byPitch = <int, List<DetectedNote>>{};
  for (final n in notes) {
    byPitch.putIfAbsent(n.midi.round(), () => []).add(n);
  }
  for (final list in byPitch.values) {
    list.sort((a, b) => a.startSec.compareTo(b.startSec));
    DetectedNote? cur;
    for (final n in list) {
      if (cur == null) {
        cur = n;
        continue;
      }
      if (n.startSec - cur.startSec <= 0.08) {
        cur = DetectedNote(
          startSec: cur.startSec,
          endSec: math.max(cur.endSec, n.endSec),
          midi: cur.midi,
          confidence: math.max(cur.confidence, n.confidence),
        );
      } else {
        out.add(cur);
        cur = n;
      }
    }
    if (cur != null) out.add(cur);
  }
  out.sort((a, b) => a.startSec != b.startSec ? a.startSec.compareTo(b.startSec) : a.midi.compareTo(b.midi));
  return out;
}

/// 钢琴 CRNN 引擎：跑 ONNX，出 `DetectedNote`
class PianoCrnnEngine {
  OrtSession? _session;
  String? _error;
  File? _modelFile;

  bool get ready => _session != null;
  String? get error => _error;

  /// 当前已加载的模型文件（可选包落地后的路径）
  File? get modelFile => _modelFile;

  /// [modelPath] 是可选包落地后的文件路径（`ModelPackStore.installedFile`）
  Future<bool> ensureLoaded(String modelPath) async {
    if (_session != null) return true;
    if (_error != null) return false;
    try {
      final runtime = OnnxRuntime();
      _session = await runtime.createSession(
        modelPath,
        options: OrtSessionOptions(intraOpNumThreads: 4),
      );
      _modelFile = File(modelPath);
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
        // 关不掉也不影响使用
      }
    }
  }

  /// 逐段（10 秒）推理。[samples] 必须是 [CrnnConst.sampleRate] 的单声道波形。
  ///
  /// [onRawSegment] 是排障用的出口：把每一段的原始张量交出来
  /// （"这个音到底有没有被模型检出"这种问题，只能看原始输出才能定位）。
  Future<List<DetectedNote>> transcribe(
    Float64List samples, {
    void Function(double fraction, String stage)? onProgress,
    void Function(int segment, Float32List onset, Float32List offset, Float32List frame, Float32List velocity)?
        onRawSegment,
    double onsetThresh = 0.5,
    double offsetThresh = 0.5,
    double frameThresh = 0.3,
    double minDurSec = 0.0,
  }) async {
    final session = _session;
    if (session == null) throw StateError('CRNN 模型未加载：${_error ?? "未知原因"}');
    if (samples.isEmpty) return const [];

    final segments = (samples.length / CrnnConst.segmentSamples).ceil();
    final all = <DetectedNote>[];
    for (var s = 0; s < segments; s++) {
      final start = s * CrnnConst.segmentSamples;
      final input = Float32List(CrnnConst.segmentSamples);
      final n = math.min(CrnnConst.segmentSamples, samples.length - start);
      for (var i = 0; i < n; i++) {
        input[i] = samples[start + i];
      }
      final value = await OrtValue.fromList(input, const [1, CrnnConst.segmentSamples]);
      Map<String, OrtValue> outputs;
      try {
        outputs = await session.run({await _inputName(session): value});
      } finally {
        await value.dispose();
      }
      try {
        final onset = await _read(outputs, const ['reg_onset_output', 'reg_onset']);
        final offset = await _read(outputs, const ['reg_offset_output', 'reg_offset']);
        final frame = await _read(outputs, const ['frame_output', 'frame']);
        final velocity = await _read(outputs, const ['velocity_output', 'velocity']);
        if (onset == null || offset == null) {
          throw StateError('模型输出里找不到 onset/offset：${outputs.keys.join(",")}');
        }
        onRawSegment?.call(s, onset.$1, offset.$1, frame?.$1 ?? Float32List(0), velocity?.$1 ?? Float32List(0));
        all.addAll(decodeCrnnNotes(
          onset: onset.$1,
          offset: offset.$1,
          frame: frame?.$1 ?? Float32List(0),
          velocity: velocity?.$1 ?? Float32List(0),
          frames: onset.$2,
          keys: onset.$3,
          segStartSec: start / CrnnConst.sampleRate,
          onsetThresh: onsetThresh,
          offsetThresh: offsetThresh,
          frameThresh: frameThresh,
          minDurSec: minDurSec,
        ));
      } finally {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
      onProgress?.call((s + 1) / segments, '高精度钢琴识别 ${s + 1}/$segments 段');
    }
    return all;
  }

  String? _inputNameCache;
  Future<String> _inputName(OrtSession session) async => _inputNameCache ??= session.inputNames.first;

  /// 取某个输出并摊平成 (数据, 帧数, 键数)
  ///
  /// ⚠️ 匹配必须**精确优先**：模型还有三路踏板输出
  /// （`reg_pedal_onset_output` / `reg_pedal_offset_output` / `pedal_frame_output`），
  /// 用"名字包含"匹配 `frame` 会命中 **`pedal_frame_output`** ✗ —— 那会让
  /// "音身消失"判断（`frame_disappear`）用错张量，音长与切分全乱。
  Future<(Float32List, int, int)?> _read(Map<String, OrtValue> outputs, List<String> names) async {
    OrtValue? v;
    for (final name in names) {
      if (outputs.containsKey(name)) {
        v = outputs[name];
        break;
      }
    }
    if (v == null) {
      for (final name in names) {
        for (final key in outputs.keys) {
          if (key.startsWith(name) && !key.toLowerCase().contains('pedal')) {
            v = outputs[key];
            break;
          }
        }
        if (v != null) break;
      }
    }
    if (v == null) return null;
    final dims = v.shape;
    final frames = dims.length >= 2 ? dims[dims.length - 2] : 0;
    final keys = dims.isNotEmpty ? dims.last : 0;
    final list = await v.asFlattenedList();
    final data = Float32List(list.length);
    for (var i = 0; i < list.length; i++) {
      final x = list[i];
      data[i] = x is num ? x.toDouble() : 0;
    }
    return (data, frames, keys);
  }
}

/// 把 CRNN（或任何）检出的音符包成通用的 [MelodyAnalysis]，供既有流程复用
MelodyAnalysis analysisFromDetectedNotes(
  List<DetectedNote> notes, {
  required int sampleRate,
  required double durationSec,
  bool melodyOnly = false,
  bool mixMode = true,
}) {
  var list = List<DetectedNote>.from(notes);
  if (melodyOnly) list = pickMelodyNotes(list);

  final bpm = estimateTempo(list, Float64List(0), 0.01);
  final key = estimateKey(list);
  final track = <PitchPoint>[];
  const stepSec = 0.02;
  var cursor = 0;
  for (var t = 0.0; t < durationSec; t += stepSec) {
    while (cursor < list.length && list[cursor].endSec < t) {
      cursor++;
    }
    var best = 0.0;
    var conf = 0.0;
    for (var i = cursor; i < list.length && list[i].startSec <= t; i++) {
      final n = list[i];
      if (n.endSec <= t) continue;
      if (n.midi >= best) {
        best = n.midi;
        conf = n.confidence;
      }
    }
    track.add(PitchPoint(t, best, conf, conf));
  }
  return MelodyAnalysis(
    notes: list,
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
