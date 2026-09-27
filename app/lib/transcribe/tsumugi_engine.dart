/// Tsumugi（乐器无关，神经半-CRF）的 **Dart 侧解码**。
///
/// 分工：神经网络部分已经导出成 ONNX（`tools/onnx_export/probe_tsumugi_export.py`，
/// 数值与 PyTorch 一致到 1e-5），**解码不在网络里**，所以要在这里重写。
/// 移植蓝本（不是自己发明的，见 `docs/和弦识别-测量记录.md` 的"移植契约"）：
///   · `instrument_agnostic_amt/amt/inference/v1_windowed.py: decode_v1_notes()`
///   · `instrument_agnostic_amt/amt/modeling/heads/semi_crf.py: decode_pitch_intervals()`
///     （打分矩阵约 547/590 行，DP 是 `viterbi` 167 行 / `viterbiBackward` 91 行）
///
/// 本文件目前实现**打分矩阵**这一半（可单测）；分段 Viterbi 在下一步。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'melody.dart';

/// 模型常量（来自 checkpoint 的 `model_config`）
class TsumugiConst {
  static const int sampleRate = 22050;

  /// 模型要 **双声道** `[1, 2, T]`（实测：单声道会报 "waveform must have shape [B, 2, T]"）
  static const int channels = 2;

  static const int hopLength = 512;
  static const int nFft = 2048;

  /// 导出时固定的段长（CQT 的 reflect padding 在动态形状下导不出来）
  static const double segmentSeconds = 10.0;
  static const int segmentSamples = sampleRate * 10;

  /// 帧数 = ceil(T / hop)（`model.py: compute_model_frames`）
  static int framesFor(int samples) => (samples / hopLength).ceil();

  /// 帧号 → 秒
  static double frameToSec(int frame) => frame * hopLength / sampleRate;
}

/// 长度缩放方式（checkpoint 里是 `none`）
enum SemiCrfLengthScaling { none, linear, sqrt }

/// 从模型的三路输出构造**区间打分矩阵**。
///
/// 打分规则（`semi_crf.py`）：
///   · `t == u`（单帧区间）用对角项 `interval_diag[t, k]`；
///   · `t <  u` 用双线性项 `interval_query[t, k, :] · interval_key[u, k, :]`；
///   · `t >  u` 不允许（`_strictly_lower_triangular_mask`）；
///   · 再统一加 `noteBias`，以及长度相关的缩放/惩罚。
///
/// [intervalQuery]/[intervalKey] 形状是行优先的 `frames × keys × dim`，
/// [intervalDiag] 是 `frames × keys`。返回 `frames × frames × keys`（行优先）的分数，
/// 非法位置（`t > u`）填 [double.negativeInfinity]。
Float32List buildIntervalScores({
  required Float32List intervalQuery,
  required Float32List intervalKey,
  required Float32List intervalDiag,
  required int frames,
  required int keys,
  required int dim,
  double noteBias = 0.0,
  SemiCrfLengthScaling lengthScaling = SemiCrfLengthScaling.none,
  double lengthPenalty = 0.0,
  int? maxSpanFrames,
}) {
  final out = Float32List(frames * frames * keys);
  out.fillRange(0, out.length, double.negativeInfinity);

  for (var t = 0; t < frames; t++) {
    // 区间跨度上限：真实演奏里一个音很少超过几秒，把过远的 (begin,end) 直接留成 -inf。
    // 复杂度从 O(F²·P·D) 降到 O(F·span·P·D) —— 实测这一段原本要 1.8s/段。
    final uMax = maxSpanFrames == null ? frames - 1 : math.min(frames - 1, t + maxSpanFrames);
    for (var u = t; u <= uMax; u++) {
      // 长度项严格照官方 `_build_length_scale` / `_build_length_penalty`：
      //   interval_length = |end - begin|（**不 +1**）
      //   length_scaling: score *= length   （none 则不变）
      //   length_penalty: score -= length * penalty
      final span = (u - t).toDouble();
      final scale = switch (lengthScaling) {
        SemiCrfLengthScaling.none => 1.0,
        SemiCrfLengthScaling.linear => span,
        SemiCrfLengthScaling.sqrt => math.sqrt(span),
      };
      final penalty = lengthPenalty == 0.0 ? 0.0 : span.clamp(0, double.infinity) * lengthPenalty;
      for (var k = 0; k < keys; k++) {
        // 双线性项：query[begin] · key[end]（官方 einsum("tnd,snd->stn") 的 t=begin, s=end）
        final qBase = (t * keys + k) * dim;
        final kBase = (u * keys + k) * dim;
        var dot = 0.0;
        for (var d = 0; d < dim; d++) {
          dot += intervalQuery[qBase + d] * intervalKey[kBase + d];
        }
        var score = dot * scale - penalty + noteBias;
        // 对角项是**加上** `interval_diag`（官方 `score[diag] += interval_diag`），不是替换
        if (t == u) score += intervalDiag[t * keys + k];
        out[(t * frames + u) * keys + k] = score;
      }
    }
  }
  return out;
}

/// 一个解出来的区间（音高 + 起止帧）
typedef PitchInterval = ({int key, int startFrame, int endFrame});

/// 分段 Viterbi —— **官方 `semi_crf.py: viterbi()` 的 1:1 移植**。
///
/// 官方语义（注意它的索引顺序是 `score[end, begin]`，本函数用 Dart 这边更顺的
/// `scores[begin, end]`，映射关系写在实现里）：
///   · 每个音高是一条**独立的轨道**（`B` 维就是音高）；
///   · 一帧要么属于某个区间 `[begin, end]`，要么是一次 **skip**（`noiseScore`）；
///   · 对角项 `score[i, i] > 0` 表示"这一帧单独成一个音"，回溯时单独发射；
///   · 只有**正分**才算事件（官方到处用 `> 0` 掩码）。
///
/// [noiseScore] 长度是 `frames - 1`（官方 `_validate_shapes`），表示 `[t, t+1]` 跳过。
List<List<PitchInterval>> viterbiDecodeIntervals({
  required Float32List scores,
  required Float32List noiseScore,
  required int frames,
  required int tracks,
}) {
  if (frames <= 0 || tracks <= 0) return const [];
  if (noiseScore.isNotEmpty && noiseScore.length < (frames - 1) * tracks) {
    throw ArgumentError('noiseScore 需要 (frames-1)*tracks 个元素');
  }

  // v[end, b]：到 end 帧为止的最优分数
  final v = Float32List(frames * tracks);
  // ptr[end-1, b]：-1 = 上一帧是 skip；否则是区间起点
  final ptr = Int32List(math.max(1, frames - 1) * tracks);
  ptr.fillRange(0, ptr.length, -2);

  double diagAt(int i, int b) => scores[(i * frames + i) * tracks + b];
  double scoreAt(int begin, int end, int b) => scores[(begin * frames + end) * tracks + b];

  for (var b = 0; b < tracks; b++) {
    final d0 = diagAt(0, b);
    v[b] = d0 > 0 ? d0 : 0.0;
    for (var end = 1; end < frames; end++) {
      // 候选 0 = skip：[end-1] + noise[end-1]
      final skip = v[(end - 1) * tracks + b] + noiseScore[(end - 1) * tracks + b];
      var best = skip;
      var sel = -1;
      for (var begin = 0; begin < end; begin++) {
        final cand = v[begin * tracks + b] + scoreAt(begin, end, b);
        if (cand > best) {
          best = cand;
          sel = begin;
        }
      }
      ptr[(end - 1) * tracks + b] = sel;
      final d = diagAt(end, b);
      v[end * tracks + b] = best + (d > 0 ? d : 0.0);
    }
  }

  // 回溯：官方从 T-1 往前，遇到 diag 就发射单帧音
  final out = <List<PitchInterval>>[];
  for (var b = 0; b < tracks; b++) {
    final list = <PitchInterval>[];
    var pos = frames - 1;
    while (pos > 0) {
      final sel = ptr[(pos - 1) * tracks + b];
      if (diagAt(pos, b) > 0) list.add((key: b, startFrame: pos, endFrame: pos));
      if (sel < 0) {
        pos -= 1;
      } else {
        list.add((key: b, startFrame: sel, endFrame: pos));
        pos = sel;
      }
    }
    if (diagAt(0, b) > 0) list.add((key: b, startFrame: 0, endFrame: 0));
    out.add(list.reversed.toList());
  }
  return out;
}

/// 取某个区间 `[t, u]`、第 [k] 个音高的分数（越界返回 -inf）
double intervalScoreAt(
  Float32List scores,
  int frames,
  int keys, {
  required int t,
  required int u,
  required int k,
}) {
  if (t < 0 || u < t || u >= frames || k < 0 || k >= keys) return double.negativeInfinity;
  return scores[(t * frames + u) * keys + k];
}

/// 把 `frames × frames × keys` 的分数按音高拆成一条条可读的区间（排障用）
List<({int startFrame, int endFrame, int key, double score})> topIntervals(
  Float32List scores,
  int frames,
  int keys, {
  int limit = 20,
}) {
  final all = <({int startFrame, int endFrame, int key, double score})>[];
  for (var t = 0; t < frames; t++) {
    for (var u = t; u < frames; u++) {
      for (var k = 0; k < keys; k++) {
        final s = scores[(t * frames + u) * keys + k];
        if (s.isFinite) {
          all.add((startFrame: t, endFrame: u, key: k, score: s));
        }
      }
    }
  }
  all.sort((a, b) => b.score.compareTo(a.score));
  return all.take(limit).toList();
}

/// Tsumugi 引擎：跑 ONNX（网络部分）+ Dart 解码（打分矩阵 + 分段 Viterbi）
///
/// 模型 I/O（`tools/onnx_export/probe_tsumugi_export.py` 导出的那版）：
///   输入  `waveform` float32 **[1, 2, T]**（双声道 22.05kHz，导出时固定 T=220500）
///   输出  `interval_query` / `interval_key` [1, F, 88, 256]、`interval_diag` [1, F, 88]、
///         `interval_features` / `pitch_query_features` / `instrument_logits` / `frame_valid_mask` [1, F]
/// 解码：`buildIntervalScores` → `viterbiDecodeIntervals`（noiseScore 官方是全零）

/// 钢琴键位映射：第 0 键 = A0 = MIDI 21（与 CRNN 一致）
const int kTsumugiKeyBase = 21;
const int kTsumugiKeyCount = 88;

class TsumugiEngine {
  OrtSession? _session;
  String? _error;
  String? _inputName;
  File? _modelFile;

  bool get ready => _session != null;
  String? get error => _error;
  File? get modelFile => _modelFile;

  /// [modelPath] 指向导出的 `tsumugi_amt.onnx`（同目录下要有 `*.onnx.data` 外部权重）
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

  /// [mono] 是任意采样率的单声道波形；内部会重采样到 22.05kHz 并**复制成双声道**
  /// （模型实测要求 `[B, 2, T]`）。模型按固定 10 秒段长，超出部分逐段处理。
  Future<List<DetectedNote>> transcribe(
    Float64List mono, {
    required int sampleRate,
    void Function(double fraction, String stage)? onProgress,
    /// 排障/优化用：分段汇报 ONNX 前向、打分矩阵、Viterbi 各花了多少毫秒
    void Function(int onnxMs, int scoreMs, int viterbiMs, int frames, int pitches)? onTiming,
  }) async {
    final session = _session;
    if (session == null) throw StateError('Tsumugi 模型未加载：${_error ?? "未知原因"}');
    if (mono.isEmpty) return const [];

    final pcm = sampleRate == TsumugiConst.sampleRate
        ? mono
        : resampleMono(mono, sampleRate, TsumugiConst.sampleRate);
    final segments = (pcm.length / TsumugiConst.segmentSamples).ceil();
    final out = <DetectedNote>[];

    for (var s = 0; s < segments; s++) {
      final start = s * TsumugiConst.segmentSamples;
      // [1, 2, T]：两个声道用同一份单声道数据（模型只吃双声道形状）
      final input = Float32List(2 * TsumugiConst.segmentSamples);
      for (var i = 0; i < TsumugiConst.segmentSamples; i++) {
        final j = start + i;
        final v = j < pcm.length ? pcm[j] : 0.0;
        input[i] = v;
        input[TsumugiConst.segmentSamples + i] = v;
      }

      final tOnnx0 = DateTime.now();
      final value = await OrtValue.fromList(input, const [1, 2, TsumugiConst.segmentSamples]);
      Map<String, OrtValue> outputs;
      try {
        outputs = await session.run({_inputName!: value});
      } finally {
        await value.dispose();
      }
      try {
        final query = await _read(outputs, 'interval_query');
        final key = await _read(outputs, 'interval_key');
        final diag = await _read(outputs, 'interval_diag');
        final mask = await _read(outputs, 'frame_valid_mask');
        if (query == null || key == null || diag == null) {
          throw StateError('模型输出缺少 interval_query/key/diag：${outputs.keys.join(",")}');
        }
        // 有效帧数：固定 10 秒窗口里只算**真实音频**覆盖的帧（导出时形状固定，
        // 假若整段按 431 帧算，短片会白算 6 倍以上的打分矩阵 —— 实测过）
        var frames = query.frames;
        if (mask != null) {
          var valid = 0;
          for (var t = 0; t < mask.frames && t < frames; t++) {
            if ((mask.data[t] != 0)) valid = t + 1;
          }
          if (valid > 0) frames = valid;
        }
        final realSamples = math.max(0, pcm.length - start);
        final realFrames = (realSamples / TsumugiConst.hopLength).ceil();
        if (realFrames > 0 && realFrames < frames) frames = realFrames;
        final onnxMs = DateTime.now().difference(tOnnx0).inMilliseconds;
        final tScore0 = DateTime.now();
        final scores = buildIntervalScores(
          intervalQuery: query.data,
          intervalKey: key.data,
          intervalDiag: diag.data,
          frames: frames,
          keys: query.keys,
          dim: query.dim,
          // 跨度上限 6 秒（帧率 = 22050/512 ≈ 43fps → 约 258 帧），
          // 把打分矩阵从 O(F²) 压到 O(F·span)
          maxSpanFrames: (TsumugiConst.sampleRate / TsumugiConst.hopLength * 6).round(),
        );
        // 官方 `_zero_noise_score`：noiseScore 全零
        final noise = Float32List((frames - 1) * query.keys);
        final scoreMs = DateTime.now().difference(tScore0).inMilliseconds;
        final tVit0 = DateTime.now();
        final tracks = viterbiDecodeIntervals(
          scores: scores,
          noiseScore: noise,
          frames: frames,
          tracks: query.keys,
        );
        onTiming?.call(onnxMs, scoreMs, DateTime.now().difference(tVit0).inMilliseconds,
            frames, query.keys);
        for (final track in tracks) {
          for (final iv in track) {
            final startSec = (start / TsumugiConst.sampleRate) + TsumugiConst.frameToSec(iv.startFrame);
            final endSec = (start / TsumugiConst.sampleRate) + TsumugiConst.frameToSec(iv.endFrame + 1);
            if (endSec <= startSec) continue;
            out.add(DetectedNote(
              startSec: startSec,
              endSec: endSec,
              midi: (kTsumugiKeyBase + iv.key).toDouble(),
              confidence: 1.0,
            ));
          }
        }
      } finally {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
      onProgress?.call((s + 1) / segments, 'Tsumugi 识别 ${s + 1}/$segments 段');
    }
    out.sort((a, b) => a.startSec != b.startSec ? a.startSec.compareTo(b.startSec) : a.midi.compareTo(b.midi));
    return out;
  }

  /// 读一个输出并摊平成 (data, frames, keys, dim)
  Future<_Tensor?> _read(Map<String, OrtValue> outputs, String name) async {
    OrtValue? v;
    for (final k in outputs.keys) {
      if (k == name || k.contains(name)) {
        v = outputs[k];
        break;
      }
    }
    if (v == null) return null;
    final shape = v.shape;
    final list = await v.asFlattenedList();
    final data = Float32List(list.length);
    for (var i = 0; i < list.length; i++) {
      final x = list[i];
      data[i] = x is num ? x.toDouble() : 0;
    }
    // [1, F, K, D] 或 [1, F, K] 或 [1, F]
    final frames = shape.length >= 3 ? shape[shape.length - 3] : (shape.isNotEmpty ? shape.last : 0);
    final keys = shape.length >= 3 ? shape[shape.length - 2] : 1;
    final dim = shape.length >= 4 ? shape.last : 1;
    return _Tensor(data, frames, keys, dim);
  }
}

class _Tensor {
  final Float32List data;
  final int frames;
  final int keys;
  final int dim;
  const _Tensor(this.data, this.frames, this.keys, this.dim);
}

/// 单声道重采样（线性插值；Tsumugi 的 CQT 前端对轻微混叠不敏感）
Float64List resampleMono(Float64List input, int fromRate, int toRate) {
  if (fromRate == toRate) return input;
  final n = (input.length * toRate / fromRate).floor();
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    final x = i * fromRate / toRate;
    final i0 = x.floor();
    final i1 = i0 + 1 < input.length ? i0 + 1 : i0;
    final f = x - i0;
    out[i] = input[i0] * (1 - f) + input[i1] * f;
  }
  return out;
}
