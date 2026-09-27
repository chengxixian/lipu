/// 用**频谱残差**判断"疑似泛音"到底是真和弦音、还是低音的泛音鬼影。
///
/// 为什么需要它：Basic Pitch 只回答"这个音高有没有能量"，看不出这点能量是**自己那根弦发的**
/// 还是**下方某个音的某次谐波**。而响度/时长分不开这两者——实测真实钢琴采样渲染的和弦里，
/// 真的 C5 是 (响度 0.43, 时长 0.19s)，C3 谐波造成的鬼影 C5 是 (0.48, 0.21s)，完全重叠。
///
/// 做法（残差检验）：钢琴的谐波包络是平滑衰减的，于是
///   1. 取候选音起音处的一小段音频做 FFT；
///   2. 用**低音自己其它分音**（避开所有已检出音的基频位置，免得被真实音污染）
///      最小二乘拟合它的谐波包络 `log A = a + b·log k`；
///   3. 用这条包络预测"候选音频率处本该有多少能量"；
///   4. 实测**明显高于**预测（默认 1.7 倍）→ 多出来的能量只能来自一根真实的弦 → 保留；
///      实测与预测相符 → 这个峰就是低音的谐波 → 判为鬼影，删掉。
///
/// 保守起见：拟合点不足、窗口太短、频率超出可分析范围时**一律保留**（宁留鬼影，不删真音）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart' show midiToHz, hannWindow;
import 'melody.dart' show DetectedNote;

/// 相对基频的泛音半音数：八度 12、十二度 19、两个八度 24、17 度 28、19 度 31、两个八度+五度 34
const List<int> kHarmonicSteps = [12, 19, 24, 28, 31, 34];

/// 频谱残差去鬼影。[samples] 必须是**与 [sampleRate] 一致**的单声道波形。
List<DetectedNote> dropHarmonicGhostsSpectral(
  List<DetectedNote> notes,
  Float64List samples, {
  required int sampleRate,
  double margin = 1.05,
  double maxLevelRatio = 0.6,
  int fftSize = 8192,
  int maxHarmonic = 14,
}) {
  if (notes.length < 2 || samples.isEmpty) return List<DetectedNote>.from(notes);

  final byStart = List<DetectedNote>.from(notes)
    ..sort((a, b) => a.startSec != b.startSec ? a.startSec.compareTo(b.startSec) : a.midi.compareTo(b.midi));

  // 所有已检出音的基频：拟合谐波包络时要避开这些频率（那里可能真的有音）
  final fundamentals = <double>[for (final n in byStart) midiToHz(n.midi)];

  // 同一时刻的和弦共用一次 FFT
  final spectra = <int, Float64List>{};
  Float64List spectrumFor(DetectedNote n) {
    final bucket = (n.startSec * 20).round();
    return spectra.putIfAbsent(bucket, () => _magnitudeSpectrum(samples, sampleRate, n.startSec, fftSize));
  }

  final dropped = <int>{};
  for (var i = 0; i < byStart.length; i++) {
    if (dropped.contains(i)) continue;
    final low = byStart[i];
    final mag = spectrumFor(low);
    if (mag.isEmpty) continue;
    final fLow = midiToHz(low.midi);
    for (var j = i + 1; j < byStart.length; j++) {
      if (byStart[j].startSec - low.startSec > 0.05) break;
      final interval = (byStart[j].midi - low.midi).round();
      if (!kHarmonicSteps.any((h) => (interval - h).abs() <= 1)) continue;
      final high = byStart[j];
      // **两个条件都成立才删**（取交集，宁可留鬼影也不删真音）：
      //   ① 能量被低音的谐波包络"完全解释掉"（频谱残差 ≈ 0）；
      //   ② 明显更轻（真实叠置音通常不会只有低音的一半多一点）。
      final explained = !_hasResidual(
        mag: mag,
        fftSize: fftSize,
        sampleRate: sampleRate,
        fLow: fLow,
        fHigh: midiToHz(high.midi),
        fundamentals: fundamentals,
        margin: margin,
        maxHarmonic: maxHarmonic,
      );
      final quiet = high.confidence <= low.confidence * maxLevelRatio;
      if (explained && quiet) dropped.add(j);
    }
  }
  final out = <DetectedNote>[];
  for (var i = 0; i < byStart.length; i++) {
    if (!dropped.contains(i)) out.add(byStart[i]);
  }
  return out;
}

/// 候选音处**是否还剩能量**（实测明显高于低音谐波包络的预测）
///
/// 预测用**局部插值**而不是全局幂律：钢琴的谐波包络整体像 k^-b，但局部起伏不小，
/// 用 k=2..14 拟合一条直线去预测某一个分音，误差常常比"真实音带来的增量"还大
/// （实测第一版就是这么把真的和弦音删掉的：低音 + 和弦 recall 掉到 56%）。
/// 改成用待检验分音**左右最近的邻居**在 log-log 上插值，准得多。
bool _hasResidual({
  required Float64List mag,
  required int fftSize,
  required int sampleRate,
  required double fLow,
  required double fHigh,
  required List<double> fundamentals,
  required double margin,
  required int maxHarmonic,
}) {
  final nyquist = sampleRate / 2;
  if (fHigh <= 0 || fHigh >= nyquist * 0.9) return true;
  final kTarget = (fHigh / fLow).round();
  // k=2 时没有更低的邻居可以插值，外推不可靠 —— 保守保留
  if (kTarget < 3) return true;

  bool polluted(int k) {
    final f = fLow * k;
    if (f >= nyquist * 0.9) return true;
    for (final other in fundamentals) {
      if (other <= 0 || (other - fLow).abs() < 1) continue;
      if ((1200 * (math.log(f / other) / math.ln2)).abs() < 60) return true;
    }
    return false;
  }

  double level(int k) => _magAt(mag, fftSize, sampleRate, fLow * k);

  // 左右各找最多两个可用的邻居分音
  final lower = <(double, double)>[];
  for (var k = kTarget - 1; k >= 2 && lower.length < 2; k--) {
    if (polluted(k)) continue;
    final a = level(k);
    if (a > 1e-12) lower.add((math.log(k.toDouble()), math.log(a)));
  }
  final upper = <(double, double)>[];
  for (var k = kTarget + 1; k <= maxHarmonic && upper.length < 2; k++) {
    if (polluted(k)) break;
    final a = level(k);
    if (a > 1e-12) upper.add((math.log(k.toDouble()), math.log(a)));
  }
  if (lower.isEmpty) return true; // 没有下邻居 → 不外推，保守保留

  final x = math.log(kTarget.toDouble());
  double predicted;
  if (upper.isNotEmpty) {
    // 线性插值（log-log）
    final (x0, y0) = lower.first;
    final (x1, y1) = upper.first;
    final b = (y1 - y0) / (x1 - x0);
    predicted = math.exp(y0 + b * (x - x0));
  } else {
    // 只能外推：用最近两个下邻居的斜率
    final (x0, y0) = lower.first;
    final slope = lower.length >= 2 ? (y0 - lower[1].$2) / (x0 - lower[1].$1) : -1.5;
    predicted = math.exp(y0 + slope * (x - x0));
  }
  if (predicted <= 1e-12) return true;

  final observed = level(kTarget);
  // 只有"实测明显高于预测"才算这里真的多了一根弦；否则这点能量低音的谐波就解释完了
  return observed > predicted * margin;
}

/// 取 onset 之后一小段的幅度谱（跳过起音瞬态，取 20ms 之后）
Float64List _magnitudeSpectrum(Float64List samples, int sampleRate, double onsetSec, int fftSize) {
  final start = ((onsetSec + 0.02) * sampleRate).round();
  if (start >= samples.length) return Float64List(0);
  var len = math.min(fftSize, samples.length - start);
  if (len < 1024) return Float64List(0); // 太短不做判断
  var n = 1;
  while (n < len) {
    n <<= 1;
  }
  final re = Float64List(n);
  final im = Float64List(n);
  final w = hannWindow(len);
  for (var i = 0; i < len; i++) {
    re[i] = samples[start + i] * w[i];
  }
  _fft(re, im);
  final half = n >> 1;
  final mag = Float64List(half);
  for (var i = 0; i < half; i++) {
    mag[i] = math.sqrt(re[i] * re[i] + im[i] * im[i]);
  }
  return mag;
}

/// 频率 f 处的幅度（取附近 ±2 个 bin 的最大值，容忍一点频率误差）
double _magAt(Float64List mag, int fftSize, int sampleRate, double f) {
  if (mag.isEmpty) return 0;
  final bin = f * mag.length * 2 / sampleRate;
  final center = bin.round();
  var best = 0.0;
  for (var i = center - 2; i <= center + 2; i++) {
    if (i < 0 || i >= mag.length) continue;
    if (mag[i] > best) best = mag[i];
  }
  return best;
}

/// 就地 radix-2 FFT
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang);
    final wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len >> 1; k++) {
        final ur = re[i + k];
        final ui = im[i + k];
        final vr = re[i + k + (len >> 1)] * cr - im[i + k + (len >> 1)] * ci;
        final vi = re[i + k + (len >> 1)] * ci + im[i + k + (len >> 1)] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + (len >> 1)] = ur - vr;
        im[i + k + (len >> 1)] = ui - vi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}
