/// 主旋律提取：PCM -> 音符序列（音高轨迹 + 切分 + 速度/调号估计）
///
/// 两种模式：
///  - 独奏 / 哼唱：YIN 自相关基频检测，稳、准
///  - 歌曲混音：谐波求和显著度提取主旋律（伴奏存在时尽量抓主旋律线）
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';

class TranscribeOptions {
  /// true = 歌曲主旋律模式（谐波显著度），false = 独奏/哼唱模式（YIN）
  final bool mixMode;

  /// 灵敏度 0..1：越大越容易把弱音判成有声
  final double sensitivity;

  /// 最短音符时长（秒），短于此的碎片会被合并或丢弃
  final double minNoteSec;

  final double minHz;
  final double maxHz;

  /// 分析帧移（秒）
  final double hopSec;

  const TranscribeOptions({
    this.mixMode = false,
    this.sensitivity = 0.5,
    this.minNoteSec = 0.08,
    this.minHz = 65,
    this.maxHz = 1500,
    this.hopSec = 0.01,
  });

  TranscribeOptions copyWith({
    bool? mixMode,
    double? sensitivity,
    double? minNoteSec,
    double? minHz,
    double? maxHz,
    double? hopSec,
  }) =>
      TranscribeOptions(
        mixMode: mixMode ?? this.mixMode,
        sensitivity: sensitivity ?? this.sensitivity,
        minNoteSec: minNoteSec ?? this.minNoteSec,
        minHz: minHz ?? this.minHz,
        maxHz: maxHz ?? this.maxHz,
        hopSec: hopSec ?? this.hopSec,
      );
}

/// 音高轨迹上的一个点（用于画钢琴卷帘）
class PitchPoint {
  final double timeSec;
  final double midi; // 0 表示该帧无音高
  final double confidence;
  final double level;
  const PitchPoint(this.timeSec, this.midi, this.confidence, this.level);

  bool get voiced => midi > 0;
}

/// 切分出来的一个音符
class DetectedNote {
  final double startSec;
  final double endSec;
  final double midi; // 浮点半音，便于显示偏差（音分）
  final double confidence;
  /// 用户在钢琴卷帘里手动删除（不参与后续转换）
  final bool removed;

  const DetectedNote({
    required this.startSec,
    required this.endSec,
    required this.midi,
    required this.confidence,
    this.removed = false,
  });

  double get durationSec => endSec - startSec;

  /// 相对十二平均律的音分偏差
  double get cents => (midi - midi.roundToDouble()) * 100;

  int get midiRound => midi.round();

  DetectedNote copyWith({double? startSec, double? endSec, double? midi, double? confidence, bool? removed}) =>
      DetectedNote(
        startSec: startSec ?? this.startSec,
        endSec: endSec ?? this.endSec,
        midi: midi ?? this.midi,
        confidence: confidence ?? this.confidence,
        removed: removed ?? this.removed,
      );
}

class MelodyAnalysis {
  final List<DetectedNote> notes;
  final List<PitchPoint> track;
  final int sampleRate;
  final double durationSec;
  final double bpm;
  final String keyName;
  final String mode;
  final double hopSec;
  final bool mixMode;

  const MelodyAnalysis({
    required this.notes,
    required this.track,
    required this.sampleRate,
    required this.durationSec,
    required this.bpm,
    required this.keyName,
    required this.mode,
    required this.hopSec,
    required this.mixMode,
  });

  List<DetectedNote> get activeNotes => notes.where((n) => !n.removed).toList();

  MelodyAnalysis withNotes(List<DetectedNote> newNotes) => MelodyAnalysis(
        notes: newNotes,
        track: track,
        sampleRate: sampleRate,
        durationSec: durationSec,
        bpm: bpm,
        keyName: keyName,
        mode: mode,
        hopSec: hopSec,
        mixMode: mixMode,
      );
}

int _nextPow2(int n) {
  var p = 1;
  while (p < n) {
    p <<= 1;
  }
  return p;
}

/// 主入口：分析单声道 PCM
MelodyAnalysis analyzeMelody(
  Float64List samples, {
  required int sampleRate,
  TranscribeOptions options = const TranscribeOptions(),
}) {
  final durationSec = samples.length / sampleRate;
  if (samples.isEmpty) {
    return MelodyAnalysis(
      notes: const [],
      track: const [],
      sampleRate: sampleRate,
      durationSec: 0,
      bpm: 0,
      keyName: 'C',
      mode: 'major',
      hopSec: options.hopSec,
      mixMode: options.mixMode,
    );
  }

  final hop = math.max(
    1,
    ((options.mixMode ? math.max(options.hopSec, 0.02) : options.hopSec) * sampleRate).round(),
  );
  final frameSize = _nextPow2(options.mixMode ? (sampleRate * 0.093).round() : (sampleRate * 0.046).round())
      .clamp(512, 4096);

  final yin = YinDetector(
    sampleRate: sampleRate,
    frameSize: frameSize,
    threshold: 0.10 + 0.18 * options.sensitivity,
    minHz: options.minHz,
    maxHz: options.maxHz,
  );
  final salience = SalienceDetector(
    sampleRate: sampleRate,
    fftSize: frameSize,
    minHz: options.minHz,
    maxHz: options.maxHz,
  );

  final frameCount = math.max(1, (samples.length - frameSize) ~/ hop + 1);
  final rawMidi = Float64List(frameCount);
  final rawConf = Float64List(frameCount);
  final levels = Float64List(frameCount);
  final frame = Float64List(frameSize);

  // 噪声门限：取 RMS 的 20 分位与中位数之间
  final rmsAll = Float64List(frameCount);
  for (var i = 0; i < frameCount; i++) {
    final start = i * hop;
    for (var j = 0; j < frameSize; j++) {
      final k = start + j;
      frame[j] = k < samples.length ? samples[k] : 0.0;
    }
    rmsAll[i] = rms(frame);
  }
  final sorted = Float64List.fromList(rmsAll)..sort();
  final noiseFloor = sorted[(frameCount * 0.2).floor().clamp(0, frameCount - 1)];
  final peakLevel = sorted[frameCount - 1];
  // 门限：以 20% 分位为基准（能切掉衰减尾音），但夹在峰值的 2%~25% 之间，
  // 这样连续不断的音乐（分位≈峰值）也不会被整体判成静音。
  final gate = (noiseFloor * 1.6).clamp(peakLevel * 0.02, peakLevel * 0.25);

  Float64List midiTrack;
  if (options.mixMode) {
    // 混音：先用显著度矩阵，再用时域连续性做 Viterbi 跟踪（避免在低音伴奏/八度之间乱跳）
    midiTrack = _viterbiMelodyTrack(
      samples: samples,
      hop: hop,
      frameSize: frameSize,
      frameCount: frameCount,
      salience: salience,
      levels: rmsAll,
      gate: gate,
      confidenceOut: rawConf,
    );
  } else {
    for (var i = 0; i < frameCount; i++) {
      final start = i * hop;
      for (var j = 0; j < frameSize; j++) {
        final k = start + j;
        frame[j] = k < samples.length ? samples[k] : 0.0;
      }
      levels[i] = rmsAll[i];
      if (rmsAll[i] < gate) {
        rawMidi[i] = 0;
        rawConf[i] = 0;
        continue;
      }
      final p = yin.detect(frame);
      if (p.voiced && p.hz >= options.minHz && p.hz <= options.maxHz) {
        rawMidi[i] = hzToMidi(p.hz);
        rawConf[i] = p.confidence;
      } else {
        rawMidi[i] = 0;
        rawConf[i] = 0;
      }
    }
    midiTrack = _medianFilter(rawMidi, 5);
  }
  for (var i = 0; i < frameCount; i++) {
    levels[i] = rmsAll[i];
  }

  // 起音检测：RMS 包络正向差分的局部极大（同音重复只能靠它切分）
  final onsets = _detectOnsets(levels, peakLevel);

  // 切分成音符
  var notes = _segment(midiTrack, rawConf, levels, hop / sampleRate, options, gateLocal: gate, onsets: onsets);

  // 八度跳变平滑（谐波显著度偶尔会把 2 次谐波当基频）
  notes = _smoothOctaves(notes);

  // 合并/丢弃过短碎片
  notes = _cleanup(notes, options, onsets, hop / sampleRate);

  // 速度与调号估计
  final bpm = estimateTempo(notes, levels, hop / sampleRate);
  final key = estimateKey(notes);

  final track = <PitchPoint>[];
  for (var i = 0; i < frameCount; i++) {
    track.add(PitchPoint(i * hop / sampleRate, midiTrack[i], rawConf[i], levels[i]));
  }

  return MelodyAnalysis(
    notes: notes,
    track: track,
    sampleRate: sampleRate,
    durationSec: durationSec,
    bpm: bpm,
    keyName: key.$1,
    mode: key.$2,
    hopSec: hop / sampleRate,
    mixMode: options.mixMode,
  );
}

/// 混音模式下的旋律线跟踪
///
/// 单帧的谐波显著度无法区分"低音伴奏"与"真旋律"（贝斯基频往往更强），
/// 所以这里把所有帧的显著度曲线拼成矩阵，用 Viterbi 在时间轴上求最优路径：
///   得分 = Σ 显著度(帧, 候选) − 0.30×|音高跳变| − 低音区偏置
/// 跳变超过 14 个半音不连通，因此八度误判、低音乱跳会被自然抑制。
Float64List _viterbiMelodyTrack({
  required Float64List samples,
  required int hop,
  required int frameSize,
  required int frameCount,
  required SalienceDetector salience,
  required Float64List levels,
  required double gate,
  required Float64List confidenceOut,
}) {
  final frame = Float64List(frameSize);
  final curves = List<Float32List>.filled(frameCount, Float32List(0));
  final voiced = List<bool>.filled(frameCount, false);
  var gridMidi = <double>[];

  for (var i = 0; i < frameCount; i++) {
    final start = i * hop;
    for (var j = 0; j < frameSize; j++) {
      final k = start + j;
      frame[j] = k < samples.length ? samples[k] : 0.0;
    }
    if (levels[i] < gate) continue;
    final curve = salience.salienceCurve(frame);
    if (curve.isEmpty) continue;
    if (gridMidi.isEmpty) gridMidi = curve.map((e) => e.$1).toList();
    final row = Float32List(math.min(curve.length, gridMidi.length));
    var maxV = 0.0;
    for (var j = 0; j < row.length; j++) {
      final v = curve[j].$2;
      row[j] = v;
      if (v > maxV) maxV = v;
    }
    if (maxV > 0) {
      for (var j = 0; j < row.length; j++) {
        row[j] = row[j] / maxV;
      }
    }
    curves[i] = row;
    voiced[i] = true;
    confidenceOut[i] = maxV;
  }

  final out = Float64List(frameCount);
  final m = gridMidi.length;
  if (m == 0) return out;

  // 音区先验：旋律一般不会长期停在中低音区（那里多是伴奏/贝斯）；
  // 这是逐帧累加的代价，所以足以压过"低音基频更强"带来的显著度优势。
  // 注意：只在混音模式用；哼唱/独奏走 YIN，不受此先验影响。
  double registerPenalty(double midi) {
    if (midi >= 57) return 0;
    return math.min(4.0, (57 - midi) * 0.28);
  }

  var dp = Float32List(m);
  final back = List<Int16List>.filled(frameCount, Int16List(0));
  for (var j = 0; j < m; j++) {
    final row = curves[0];
    dp[j] = (row.isEmpty || j >= row.length ? 0.0 : row[j] * 2.2) - registerPenalty(gridMidi[j]);
  }

  for (var t = 1; t < frameCount; t++) {
    final row = curves[t];
    final ndp = Float32List(m);
    final bp = Int16List(m);
    for (var j = 0; j < m; j++) {
      final mj = gridMidi[j];
      var best = -1e9;
      var bestI = j;
      for (var i = 0; i < m; i++) {
        final d = (mj - gridMidi[i]).abs();
        if (d > 14) continue;
        final v = dp[i] - d * 0.30;
        if (v > best) {
          best = v;
          bestI = i;
        }
      }
      if (best < -1e8) best = 0;
      final emission = (row.isEmpty || j >= row.length) ? 0.0 : row[j] * 2.2;
      ndp[j] = best + emission - registerPenalty(mj);
      bp[j] = bestI;
    }
    dp = ndp;
    back[t] = bp;
  }

  var bestJ = 0;
  var bestV = -1e9;
  for (var j = 0; j < m; j++) {
    if (dp[j] > bestV) {
      bestV = dp[j];
      bestJ = j;
    }
  }
  var j = bestJ;
  for (var t = frameCount - 1; t >= 0; t--) {
    out[t] = voiced[t] ? gridMidi[j] : 0;
    if (t > 0) j = back[t][j];
  }
  return out;
}

Float64List _medianFilter(Float64List input, int radius) {  final n = input.length;
  final out = Float64List(n);
  final buf = <double>[];
  for (var i = 0; i < n; i++) {
    buf.clear();
    for (var k = i - radius; k <= i + radius; k++) {
      if (k < 0 || k >= n) continue;
      if (input[k] > 0) buf.add(input[k]);
    }
    if (buf.isEmpty) {
      out[i] = input[i] > 0 ? input[i] : 0;
      continue;
    }
    buf.sort();
    out[i] = buf[buf.length ~/ 2];
  }
  return out;
}

/// 起音检测：RMS 包络的正向差分局部极大
List<bool> _detectOnsets(Float64List levels, double peakLevel) {
  final n = levels.length;
  final onsets = List<bool>.filled(n, false);
  if (n < 3 || peakLevel <= 0) return onsets;
  final strength = Float64List(n);
  for (var i = 1; i < n; i++) {
    final d = levels[i] - levels[i - 1];
    strength[i] = d > 0 ? d : 0;
  }
  final threshold = peakLevel * 0.05;
  for (var i = 1; i < n - 1; i++) {
    if (strength[i] > threshold && strength[i] >= strength[i - 1] && strength[i] >= strength[i + 1]) {
      onsets[i] = true;
    }
  }
  return onsets;
}

List<DetectedNote> _segment(
  Float64List midiTrack,
  Float64List conf,
  Float64List levels,
  double hopSec,
  TranscribeOptions options, {
  required double gateLocal,
  required List<bool> onsets,
}) {
  final notes = <DetectedNote>[];
  final n = midiTrack.length;
  int? startFrame;
  var pitchSum = 0.0;
  var pitchCount = 0;
  var confSum = 0.0;
  var silence = 0;

  void flush(int endFrame) {
    if (startFrame == null || pitchCount == 0) {
      startFrame = null;
      return;
    }
    final midi = pitchSum / pitchCount;
    notes.add(DetectedNote(
      startSec: startFrame! * hopSec,
      endSec: endFrame * hopSec,
      midi: midi,
      confidence: confSum / pitchCount,
    ));
    startFrame = null;
    pitchSum = 0;
    pitchCount = 0;
    confSum = 0;
  }

  for (var i = 0; i < n; i++) {
    final m = midiTrack[i];
    if (m <= 0) {
      silence++;
      // 连续静音超过 3 帧才算音结束
      if (startFrame != null && silence >= 3) {
        flush(i - silence + 1);
      }
      continue;
    }
    silence = 0;
    if (startFrame == null) {
      startFrame = i;
      pitchSum = m;
      pitchCount = 1;
      confSum = conf[i];
      continue;
    }
    final current = pitchSum / pitchCount;
    final jump = (m - current).abs();
    // 换音判据：音高跳变 > 0.6 个半音，或检测到起音（同音重复也能切开）
    final hasOnset = onsets[i] && pitchCount > 3; // 至少持续 30ms 才允许被起音切开
    final rising = i > 0 && levels[i] > levels[i - 1] * 1.5 && levels[i] > gateLocal * 2.5;
    if (jump > 0.6 || hasOnset || rising) {
      flush(i);
      startFrame = i;
      pitchSum = m;
      pitchCount = 1;
      confSum = conf[i];
    } else {
      pitchSum += m;
      pitchCount++;
      confSum += conf[i];
    }
  }
  flush(n - 1);
  return notes;
}

List<DetectedNote> _smoothOctaves(List<DetectedNote> notes) {
  if (notes.length < 3) return notes;
  final out = List<DetectedNote>.from(notes);
  for (var i = 1; i < out.length - 1; i++) {
    final prev = out[i - 1].midi;
    final next = out[i + 1].midi;
    final mid = out[i].midi;
    final neighbour = (prev + next) / 2;
    final diff = mid - neighbour;
    // 孤立地高了/低了差不多一个八度 -> 拉回来
    if (diff.abs() > 10 && (diff.abs() - 12).abs() < 1.2 && out[i].durationSec < 0.25) {
      out[i] = out[i].copyWith(midi: mid - 12.0 * (diff > 0 ? 1 : -1));
    }
  }
  return out;
}

/// 区间内是否有起音点
bool _hasOnsetBetween(List<bool> onsets, double hopSec, double startSec, double endSec) {
  if (hopSec <= 0) return false;
  final from = (startSec / hopSec).floor().clamp(0, onsets.length - 1);
  final to = ((endSec / hopSec).ceil() + 1).clamp(0, onsets.length - 1);
  for (var i = from; i <= to; i++) {
    if (onsets[i]) return true;
  }
  return false;
}

List<DetectedNote> _cleanup(
  List<DetectedNote> notes,
  TranscribeOptions options,
  List<bool> onsets,
  double hopSec,
) {
  final minDur = options.minNoteSec;
  // 先把同音高、间隔很短（< 60ms）的相邻音符合并——但区间内有起音点时说明
  // 这是"同一个音重复了一次"，不能合并。
  final merged = <DetectedNote>[];
  for (final note in notes) {
    if (merged.isNotEmpty) {
      final last = merged.last;
      final gap = note.startSec - last.endSec;
      final repeated = _hasOnsetBetween(onsets, hopSec, last.endSec - hopSec, note.startSec + hopSec);
      if (gap < 0.06 && !repeated && (note.midi - last.midi).abs() < 0.5) {
        merged[merged.length - 1] = DetectedNote(
          startSec: last.startSec,
          endSec: note.endSec,
          midi: (last.midi * last.durationSec + note.midi * note.durationSec) / (last.durationSec + note.durationSec),
          confidence: (last.confidence + note.confidence) / 2,
        );
        continue;
      }
    }
    merged.add(note);
  }
  // 再来一轮：把短于阈值的碎片并入相邻同音
  final out = <DetectedNote>[];
  for (var i = 0; i < merged.length; i++) {
    final note = merged[i];
    if (note.durationSec >= minDur) {
      out.add(note);
      continue;
    }
    if (out.isNotEmpty && (out.last.midi - note.midi).abs() < 0.7) {
      out[out.length - 1] = out.last.copyWith(endSec: note.endSec);
    } else if (i + 1 < merged.length && (merged[i + 1].midi - note.midi).abs() < 0.7) {
      merged[i + 1] = merged[i + 1].copyWith(startSec: note.startSec);
    }
    // 否则直接丢弃（多半是颤音/噪声碎片）
  }
  return out;
}

/* ------------------------------------------------------------------ *
 * 速度与调号估计
 * ------------------------------------------------------------------ */

/// 用起始点间隔的直方图估计拍速，落在 60~180 BPM
double estimateTempo(List<DetectedNote> notes, Float64List levels, double hopSec) {
  if (notes.length < 3) return 0;
  final intervals = <double>[];
  for (var i = 1; i < notes.length; i++) {
    final d = notes[i].startSec - notes[i - 1].startSec;
    if (d > 0.12 && d < 2.5) intervals.add(d);
  }
  if (intervals.isEmpty) return 0;

  // 20ms 直方图取众数：比取分位数稳（不会因为个别检测抖动而偏快）
  const binWidth = 0.02;
  final histogram = <int, List<double>>{};
  for (final d in intervals) {
    histogram.putIfAbsent((d / binWidth).round(), () => <double>[]).add(d);
  }
  var bestKey = -1;
  var bestCount = -1;
  histogram.forEach((k, list) {
    // 命中数多的优先；相同时取更短的间隔（避免把两拍并成一拍）
    if (list.length > bestCount || (list.length == bestCount && bestKey > 0 && k < bestKey)) {
      bestCount = list.length;
      bestKey = k;
    }
  });
  if (bestKey < 0) return 0;
  final members = histogram[bestKey]!;
  final base = members.reduce((a, b) => a + b) / members.length;
  if (base <= 0) return 0;

  var bpm = 60.0 / base;
  // 把可能的细分（把八分/十六分当拍）折算回常见拍速区间
  while (bpm > 180) {
    bpm /= 2;
  }
  while (bpm < 60) {
    bpm *= 2;
  }
  return bpm;
}

const List<double> _krumhanslMajor = [
  6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];
const List<double> _krumhanslMinor = [
  6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
];
const List<String> _pitchNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/// Krumhansl-Schmuckler 调性轮廓相关
(String, String) estimateKey(List<DetectedNote> notes) {
  if (notes.isEmpty) return ('C', 'major');
  final hist = List<double>.filled(12, 0);
  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    final pc = ((n.midiRound % 12) + 12) % 12;
    // 首尾音在调性上最有指示性（乐曲通常从主音/属音起、落在主音上）
    // 权重用 **sqrt(时长)**：直接用时长会让"左手固定音型/持续低音"霸占整个直方图
    // （实测《圣诞快乐，劳伦斯先生》就是被持续的 G# 带跑，估成了 G# 而不是 C# 小调）
    var weight = math.sqrt(math.max(0.0, n.durationSec));
    if (i == 0) weight *= 1.6;
    if (i == notes.length - 1) weight *= 2.0;
    hist[pc] += weight;
  }
  final total = hist.reduce((a, b) => a + b);
  if (total <= 0) return ('C', 'major');
  for (var i = 0; i < 12; i++) {
    hist[i] /= total;
  }

  double corr(List<double> profile, int tonic) {
    var mp = 0.0, mh = 0.0;
    for (var i = 0; i < 12; i++) {
      mp += profile[i];
      mh += hist[i];
    }
    mp /= 12;
    mh /= 12;
    var num = 0.0, dp = 0.0, dh = 0.0;
    for (var i = 0; i < 12; i++) {
      final p = profile[(i - tonic + 12) % 12] - mp;
      final h = hist[i] - mh;
      num += p * h;
      dp += p * p;
      dh += h * h;
    }
    if (dp == 0 || dh == 0) return 0;
    return num / math.sqrt(dp * dh);
  }

  var best = -2.0;
  var bestTonic = 0;
  var bestMode = 'major';
  for (var t = 0; t < 12; t++) {
    // 不给大调加偏置：关系大小调的色度几乎相同，一旦加偏置小调永远输
    // （实测：A 小调音阶、C# 小调音阶都被判成大调 → 调号错 → 简谱数字整体错位）
    final maj = corr(_krumhanslMajor, t);
    if (maj > best) {
      best = maj;
      bestTonic = t;
      bestMode = 'major';
    }
    final min = corr(_krumhanslMinor, t);
    if (min > best) {
      best = min;
      bestTonic = t;
      bestMode = 'minor';
    }
  }
  // ⚠️ 返回的是**简谱调号**（"1 = 什么"），不是主音：
  //    小调必须换算成**关系大调**（A 小调 → `1=C`，C# 小调 → `1=E`）。
  //    旧实现直接把主音当 1、还加个 'm'（返回 "G#m" 这种）——
  //    `keyInfoOf()` 根本认不了，整首的简谱数字会全体错位（用户报的"音完全不对"就是这个）。
  final tonic = bestMode == 'minor' ? (bestTonic + 3) % 12 : bestTonic;
  return (_preferFewerAccidentals(tonic), bestMode);
}

/// 同音高挑**记号更少**的写法：G#(8 升) → Ab(4 降)、D#(9 升) → Eb、A#(10 升) → Bb。
/// 简谱里出现"8 个升号"的调号没有意义，用户只会觉得是 bug。
String _preferFewerAccidentals(int pc) {
  const sharpNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  // 大调调号升降号个数：C=0 G=1 D=2 A=3 E=4 B=5 F#=6 C#=7 / F=1 Bb=2 Eb=3 Ab=4 Db=5 Gb=6
  const sharpCount = {0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6, 1: 7};
  const flatCount = {5: 1, 10: 2, 3: 3, 8: 4, 1: 5, 6: 6};
  const flatNames = {5: 'F', 10: 'Bb', 3: 'Eb', 8: 'Ab', 1: 'Db', 6: 'Gb'};
  final sharp = sharpCount[pc] ?? 99;
  final flat = flatCount[pc] ?? 99;
  if (flat < sharp && flatNames.containsKey(pc)) return flatNames[pc]!;
  return sharpNames[pc];
}

/// 便于界面显示：把浮点音高写成 "C4 +12¢" 这种
String describePitch(double midi) {
  final r = midi.round();
  final names = _pitchNames[((r % 12) + 12) % 12];
  final octave = r ~/ 12 - 1;
  final cents = ((midi - r) * 100).round();
  return '$names$octave${cents == 0 ? '' : (cents > 0 ? ' +$cents¢' : ' $cents¢')}';
}

/* ------------------------------------------------------------------ *
 * 复调结果的后处理：泛音去重 + 主旋律提取
 * ------------------------------------------------------------------ */

/// 去掉**泛音鬼影**：几乎同时起音、间隔正好落在泛音列上（八度/十二度/两个八度），
/// 而且高音那个能量明显更低 —— 判定为低音的泛音，丢掉。
///
/// 合成音色、亮音色尤其明显：基频 60 常会同时识别出 72、79。
///
/// ⚠️ 这一招**分不出"真的八度叠置"和"泛音鬼影"**：实测（钢琴采样渲染的和弦）里，
/// 真的 C5 是 (响度 0.43 / 时长 0.19s)，鬼影 C5 是 (0.48 / 0.21s)，完全重叠。
/// 所以这里的判据只能取"明显更轻"这一条，宁可留下鬼影也不能删掉真的叠置音；
/// 想彻底分开得靠**频谱残差验证**（见 docs 里的和弦识别记录）。
List<DetectedNote> dropHarmonicGhosts(List<DetectedNote> notes) {
  if (notes.length < 2) return List<DetectedNote>.from(notes);
  final byStart = List<DetectedNote>.from(notes)
    ..sort((a, b) => a.startSec != b.startSec ? a.startSec.compareTo(b.startSec) : a.midi.compareTo(b.midi));
  final dropped = <int>{};
  for (var i = 0; i < byStart.length; i++) {
    if (dropped.contains(i)) continue;
    for (var j = i + 1; j < byStart.length; j++) {
      if (byStart[j].startSec - byStart[i].startSec > 0.05) break;
      final interval = (byStart[j].midi - byStart[i].midi).round();
      if (interval != 12 && interval != 19 && interval != 24) continue;
      if (byStart[j].confidence <= byStart[i].confidence * 0.75) dropped.add(j);
    }
  }
  final out = <DetectedNote>[];
  for (var i = 0; i < byStart.length; i++) {
    if (!dropped.contains(i)) out.add(byStart[i]);
  }
  return out;
}

/// 合并**同一音高的重复检出**：滑动窗口拼接时同一个音偶尔会被报两次
/// （实测：低音 + 和弦那一段里 C4 同时出现 (0.49,0.42s) 与 (0.32,0.38s) 两个事件）。
///
/// 判据是"**同一次触键**"：起音时间相差 ≤150ms 才算重复。
/// 不能只按"时间重叠"来并——同一个音高在两个和弦里各弹一次（3.0s 与 2.0s 的 G4）
/// 会被并成一个长音，节奏就没了（实测踩过：最后一个和弦的 G4/B4 整对消失）。
List<DetectedNote> mergeDuplicateNotes(List<DetectedNote> notes) {
  if (notes.length < 2) return List<DetectedNote>.from(notes);
  final byPitch = <int, List<DetectedNote>>{};
  for (final n in notes) {
    byPitch.putIfAbsent(n.midi.round(), () => []).add(n);
  }
  final out = <DetectedNote>[];
  for (final list in byPitch.values) {
    list.sort((a, b) => a.startSec.compareTo(b.startSec));
    DetectedNote? cur;
    for (final n in list) {
      if (cur == null) {
        cur = n;
        continue;
      }
      final sameStrike = (n.startSec - cur.startSec).abs() <= 0.15;
      if (sameStrike) {
        cur = DetectedNote(
          startSec: math.min(cur.startSec, n.startSec),
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

/// 主旋律提取：从（可能是复调的）音符里挑出一条单声部旋律线。
///
///   1. **泛音去重**（[dropHarmonicGhosts]）；
///   2. **声部跟踪**：与"当前旋律音"重叠的候选分两种——
///      只比当前音早结束一点点（≤120ms，正常换音的交叠）就当成下一个旋律音接上；
///      明显同时发声的，用 `能量 − 0.20×与上一个旋律音的音程 + 0.02×音区` 打分，分高者当旋律；
///   3. **低音清理**：丢掉比整条旋律中位数低 12 个半音以上的漏网伴奏。
List<DetectedNote> pickMelodyNotes(List<DetectedNote> notes) {
  if (notes.length <= 1) return List<DetectedNote>.from(notes);

  final deduped = dropHarmonicGhosts(notes);

  double score(DetectedNote n, double referenceMidi) {
    final interval = (n.midi - referenceMidi).abs().clamp(0.0, 12.0);
    final register = (n.midi - 60) / 12.0;
    return n.confidence - 0.20 * (interval / 12.0) + 0.02 * register;
  }

  final kept = <DetectedNote>[];
  DetectedNote? current;
  for (final n in deduped) {
    if (current == null) {
      kept.add(n);
      current = n;
      continue;
    }
    // 说明：同起音的和弦音**不**在这里做"取最高声部"的处理 ——
    // 实测那样会把漏过泛音去重的鬼影（能量略高于 0.75×基频的那种）选成旋律，
    // 小星星样本的命中率从 42/42 掉到 41/42。交给下面的连续性打分更稳。
    if (n.startSec >= current.endSec - 0.02 || current.endSec - n.startSec <= 0.12) {
      kept.add(n);
      current = n;
      continue;
    }
    final referenceMidi = kept.length >= 2 ? kept[kept.length - 2].midi : current.midi;
    if (score(n, referenceMidi) > score(current, referenceMidi)) {
      kept[kept.length - 1] = n;
      current = n;
    }
  }

  if (kept.length <= 2) return kept;

  final sortedMidi = kept.map((n) => n.midi).toList()..sort();
  final median = sortedMidi[sortedMidi.length ~/ 2];
  return kept.where((n) => n.midi >= median - 12).toList();
}
