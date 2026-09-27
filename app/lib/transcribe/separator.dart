/// 人声分离引擎：把立体声混音拆成「人声」与「伴奏」两轨。
///
/// 用途（用户要求）：扒谱前先去人声，**用伴奏转谱**，避免人声带着走调。
///
/// 流程（严格照 UVR-MDX KARA2 的宿主契约，见 `stft.dart` 与
/// `docs/和弦识别-测量记录.md`）：
///   逐块（261,120 样本）→ STFT → 模型 → iSTFT → overlap-add
///   → 得到「人声」；「伴奏」= 原混音 − 人声（MDX 系模型输出的是目标源）。
///
/// ⚠️ 三个待现场确认/标定的点（都已做成参数或记录在案）：
///   1. **信道顺序**（模型卡没写明）→ `imagFirst`；
///   2. 模型输出的是"人声"还是"伴奏"——KARA2 是主唱/伴唱分离模型，
///      这里按"输出=主唱"处理；若实测反了，把 [outputIsVocal] 设成 false 即可；
///   3. **ISTFT 的缩放约定**（模型卡没写）：实测人声轨比混音大 ~7 倍
///      （`integration_test/separator_e2e_test.dart` 会打印这个比值），
///      说明"分析 Hann + 合成按 Σw² 归一化"这套 torch.istft 默认约定与模型训练时不一致。
///      标定之前**不要**把分离结果接进扒谱流程——所以扒谱页暂时没有这个开关。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'stft.dart';

class UvrSeparator {
  OrtSession? _session;
  String? _error;
  String? _inputName;
  File? _modelFile;

  bool get ready => _session != null;
  String? get error => _error;
  File? get modelFile => _modelFile;

  Future<bool> ensureLoaded(String modelPath) async {
    if (_session != null) return true;
    if (_error != null) return false;
    try {
      final runtime = OnnxRuntime();
      _session = await runtime.createSession(
        modelPath,
        options: OrtSessionOptions(intraOpNumThreads: 4),
      );
      _inputName = _session!.inputNames.first;
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
    _modelFile = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {
        // 忽略
      }
    }
  }

  /// 分离一对立体声声道。返回人声与伴奏（长度与输入相同）。
  Future<
      ({
        Float64List vocalLeft,
        Float64List vocalRight,
        Float64List accompanimentLeft,
        Float64List accompanimentRight,
      })> separate(
    Float64List left,
    Float64List right, {
    void Function(double fraction, String stage)? onProgress,
    bool imagFirst = false,
    bool outputIsVocal = true,
  }) async {
    final session = _session;
    if (session == null) throw StateError('分离模型未加载：${_error ?? "未知原因"}');
    if (left.isEmpty || left.length != right.length) {
      throw ArgumentError('左右声道必须等长且非空');
    }
    final n = left.length;
    final window = hannPeriodic(StftConst.nFft);
    // 目标源累加（人声或伴奏，取决于模型输出的是哪一个）
    final targetL = Float64List(n);
    final targetR = Float64List(n);
    final weight = Float64List(n);

    final blocks = (n / StftConst.chunkSamples).ceil();
    for (var b = 0; b < blocks; b++) {
      final start = b * StftConst.chunkSamples + StftConst.nFft ~/ 2;
      final spec = stftChunk(left: left, right: right, start: start, window: window, imagFirst: imagFirst);
      final value = await OrtValue.fromList(spec, const [1, 4, StftConst.modelBins, StftConst.chunkFrames]);
      Map<String, OrtValue> outputs;
      try {
        outputs = await session.run({_inputName!: value});
      } finally {
        await value.dispose();
      }
      try {
        final out = outputs.values.first;
        final list = await out.asFlattenedList();
        final data = Float32List(list.length);
        for (var i = 0; i < list.length; i++) {
          final x = list[i];
          data[i] = x is num ? x.toDouble() : 0;
        }
        istftChunk(
          spec: data,
          outLeft: targetL,
          outRight: targetR,
          weight: weight,
          start: start,
          window: window,
          imagFirst: imagFirst,
        );
      } finally {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
      onProgress?.call((b + 1) / blocks, '人声分离 ${b + 1}/$blocks 块');
    }
    normalizeOverlapAdd(targetL, weight);
    normalizeOverlapAdd(targetR, weight);

    final vocalL = outputIsVocal ? targetL : Float64List(n);
    final vocalR = outputIsVocal ? targetR : Float64List(n);
    if (!outputIsVocal) {
      // 模型给的是伴奏 → 人声 = 混音 − 伴奏
      for (var i = 0; i < n; i++) {
        vocalL[i] = left[i] - targetL[i];
        vocalR[i] = right[i] - targetR[i];
      }
    }
    final accL = Float64List(n);
    final accR = Float64List(n);
    for (var i = 0; i < n; i++) {
      accL[i] = left[i] - vocalL[i];
      accR[i] = right[i] - vocalR[i];
    }
    return (
      vocalLeft: vocalL,
      vocalRight: vocalR,
      accompanimentLeft: accL,
      accompanimentRight: accR,
    );
  }
}

/// 单声道 → 立体声（很多音源是单声道；分离模型要双声道输入）
({Float64List left, Float64List right}) toStereo(Float64List mono) =>
    (left: mono, right: Float64List.fromList(mono));

/// 简易 RMS（自检用：人声轨的能量应当明显低于混音）
double rmsOf(Float64List x, [int from = 0, int? to]) {
  final end = to ?? x.length;
  if (end <= from) return 0;
  var sum = 0.0;
  for (var i = from; i < end; i++) {
    sum += x[i] * x[i];
  }
  return math.sqrt(sum / (end - from));
}
