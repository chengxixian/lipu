/// 纯 Dart 音频 DSP 内核：FFT / 频谱峰值插值 / YIN 基频检测 / 谐波显著度旋律提取。
///
/// 设计约束：
/// * 只依赖 `dart:math` 与 `dart:typed_data`，**不导入 Flutter**，可在任意 Dart 环境（含 isolate）跑；
/// * 所有分析函数对空数组、长度不足、全零输入安全（返回 hz = 0 的无音高结果）；
/// * 热路径（单帧 1024/2048 点 FFT、YIN 差分函数）不分配大数组，内部复用缓冲区，
///   以便哼唱录制时按 10~20ms 一帧实时调用。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 一个八度的半音数。
const double kSemitonesPerOctave = 12.0;

/// MIDI 音高 69 对应 A4 = 440Hz。
const double kA4Hz = 440.0;
const int kA4Midi = 69;

const double _ln2 = 0.6931471805599453;

/// 频率 -> MIDI 音高（可为小数，便于表示音分偏差）。hz <= 0 时返回 [double.nan]。
double hzToMidi(double hz) {
  if (hz <= 0 || !hz.isFinite) return double.nan;
  return kA4Midi + 12.0 * (math.log(hz / kA4Hz) / _ln2);
}

/// MIDI 音高 -> 频率。midi 非有限时返回 0。
double midiToHz(double midi) {
  if (!midi.isFinite) return 0;
  return kA4Hz * math.pow(2.0, (midi - kA4Midi) / 12.0).toDouble();
}

/// 汉宁窗（周期型，分母 n），返回长度 n 的新数组。
Float64List hannWindow(int n) {
  final w = Float64List(n < 0 ? 0 : n);
  if (n <= 1) {
    if (n == 1) w[0] = 1.0;
    return w;
  }
  final k = 2.0 * math.pi / n;
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(k * i);
  }
  return w;
}

/// 基 2 迭代 FFT（原地，size 必须是 2 的幂）。
///
/// 构造时预计算位反转表与旋转因子，`forward` 不分配内存；
/// `magnitudeSpectrum` 内部复用 re/im 与幅度缓冲。
class Fft {
  Fft(this.size)
      : assert(size > 0),
        assert((size & (size - 1)) == 0, 'size 必须是 2 的幂') {
    _rev = Int32List(size);
    final bits = _log2(size);
    for (var i = 0; i < size; i++) {
      _rev[i] = _reverseBits(i, bits);
    }
    _cos = Float64List(size >> 1);
    _sin = Float64List(size >> 1);
    for (var i = 0; i < (size >> 1); i++) {
      final a = -2.0 * math.pi * i / size;
      _cos[i] = math.cos(a);
      _sin[i] = math.sin(a);
    }
    _re = Float64List(size);
    _im = Float64List(size);
    _mag = Float64List((size >> 1) + 1);
  }

  final int size;
  late final Int32List _rev;
  late final Float64List _cos;
  late final Float64List _sin;
  late final Float64List _re;
  late final Float64List _im;
  late final Float64List _mag;

  static int _log2(int n) {
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    return bits;
  }

  static int _reverseBits(int x, int bits) {
    var v = x;
    var r = 0;
    for (var i = 0; i < bits; i++) {
      r = (r << 1) | (v & 1);
      v >>= 1;
    }
    return r;
  }

  /// 原地正变换；re/im 长度必须等于 [size]。
  void forward(Float64List re, Float64List im) {
    if (re.length != size || im.length != size) {
      throw ArgumentError('re/im 长度必须为 $size（re=${re.length}, im=${im.length}）');
    }
    // 1) 位反转置换
    for (var i = 0; i < size; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    // 2) 蝶形运算（标准 radix-2 Cooley-Tukey）
    for (var len = 2; len <= size; len <<= 1) {
      final half = len >> 1;
      final step = size ~/ len;
      for (var i = 0; i < size; i += len) {
        var k = 0;
        for (var j = i; j < i + half; j++) {
          final c = _cos[k];
          final s = _sin[k];
          final l = j + half;
          final tr = re[l] * c - im[l] * s;
          final ti = re[l] * s + im[l] * c;
          re[l] = re[j] - tr;
          im[l] = im[j] - ti;
          re[j] += tr;
          im[j] += ti;
          k += step;
        }
      }
    }
  }

  /// 幅度谱，长度 size/2 + 1（含 DC 与 Nyquist）。内部复用缓冲区，返回值只在下一次调用前有效。
  ///
  /// 输入超过 size 时截断，不足时补零；同时施加汉宁窗以抑制频谱泄漏。
  Float64List magnitudeSpectrum(Float64List samples) {
    final n = math.min(samples.length, size);
    for (var i = 0; i < size; i++) {
      _re[i] = 0.0;
      _im[i] = 0.0;
    }
    for (var i = 0; i < n; i++) {
      // 周期型汉宁窗：端点不为零，避免首样本被完全抹掉
      _re[i] = samples[i] * (0.5 - 0.5 * math.cos(2.0 * math.pi * i / size));
    }
    forward(_re, _im);
    final half = size >> 1;
    for (var i = 0; i <= half; i++) {
      final re = _re[i];
      final im = _im[i];
      _mag[i] = math.sqrt(re * re + im * im);
    }
    return _mag;
  }
}

/// 频谱峰值抛物线插值：在 [bin] 处用相邻三点拟合抛物线，返回 (binIndex, 精确bin, 幅度)。
///
/// 边界 bin（0 或最后一个）无法三点拟合时返回 null。
(double, double, double)? parabolicPeak(Float64List mag, int bin) {
  if (bin <= 0 || bin >= mag.length - 1) return null;
  final a = mag[bin - 1];
  final b = mag[bin];
  final c = mag[bin + 1];
  final denom = a - 2.0 * b + c;
  if (denom == 0.0) return (bin.toDouble(), bin.toDouble(), b);
  var delta = 0.5 * (a - c) / denom;
  if (delta > 0.5) delta = 0.5;
  if (delta < -0.5) delta = -0.5;
  final peak = b - 0.25 * (a - c) * delta;
  return (bin.toDouble(), bin + delta, peak);
}

/// 一帧的基频检测结果。
class PitchFrame {
  /// 基频（Hz）。0 表示无音高（静音 / 噪声 / 不可判）。
  final double hz;

  /// 置信度 0..1（YIN 下为 1 - CMNDF 最小值）。
  final double confidence;

  const PitchFrame(this.hz, this.confidence);

  /// 无音高结果。
  static const PitchFrame none = PitchFrame(0.0, 0.0);

  bool get voiced => hz > 0 && confidence > 0;

  @override
  String toString() =>
      'PitchFrame(${hz.toStringAsFixed(2)}Hz, conf=${confidence.toStringAsFixed(3)})';
}

/// 单声部基频检测（YIN / CMNDF），适合哼唱、独奏、清晰主旋律。
///
/// 实现要点：差分函数 -> 累积均值归一化（CMNDF）-> 绝对阈值（默认 0.15）
/// -> 抛物线插值取亚采样精度；并做一次「次谐波优先」检查以抵抗低八度误判。
class YinDetector {
  YinDetector({
    required this.sampleRate,
    this.frameSize = 1024,
    this.threshold = 0.15,
    this.minHz = 55,
    this.maxHz = 1200,
  })  : assert(frameSize > 0),
        assert((frameSize & (frameSize - 1)) == 0, 'frameSize 必须是 2 的幂') {
    _maxLag = math.min(frameSize ~/ 2, (sampleRate / math.max(minHz, 1e-9)).ceil());
    if (_maxLag < 2) _maxLag = 2;
    _diff = Float64List(_maxLag + 1);
    _cmnd = Float64List(_maxLag + 1);
    _work = Float64List(frameSize);
    _tauMin = math.max(2, (sampleRate / math.max(maxHz, 1e-9)).floor());
    if (_tauMin > _maxLag) _tauMin = _maxLag;
    _tauMax = _maxLag;
  }

  final int sampleRate;
  final int frameSize;
  final double threshold;
  final double minHz;
  final double maxHz;

  late final int _tauMin;
  late final int _tauMax;
  late final int _maxLag;
  late final Float64List _diff;
  late final Float64List _cmnd;
  late final Float64List _work;

  /// 输入长度应 >= frameSize（更长则截断，更短则补零）；返回该帧的基频估计。
  PitchFrame detect(Float64List frame) {
    final n = frameSize;
    if (frame.length < n) {
      // 长度不足时补零（不做外推），仍然给出结果
      for (var i = 0; i < n; i++) {
        _work[i] = i < frame.length ? frame[i] : 0.0;
      }
    } else {
      for (var i = 0; i < n; i++) {
        _work[i] = frame[i];
      }
    }
    // 去均值，消除直流对差分函数的影响
    var mean = 0.0;
    for (var i = 0; i < n; i++) {
      mean += _work[i];
    }
    mean /= n;
    var energy = 0.0;
    for (var i = 0; i < n; i++) {
      final v = _work[i] - mean;
      _work[i] = v;
      energy += v * v;
    }
    if (energy <= 1e-12) return PitchFrame.none; // 静音 / 恒定值

    // 1) 差分函数 d(tau) = sum_{j=0}^{n-tau-1} (x[j] - x[j+tau])^2
    final w = _work;
    final d = _diff;
    d[0] = 0.0;
    final lim = _maxLag < n - 1 ? _maxLag : n - 1;
    for (var tau = 1; tau <= lim; tau++) {
      var sum = 0.0;
      final m = n - tau;
      for (var j = 0; j < m; j++) {
        final diff = w[j] - w[j + tau];
        sum += diff * diff;
      }
      d[tau] = sum;
    }
    for (var tau = lim + 1; tau <= _maxLag; tau++) {
      d[tau] = d[lim];
    }

    // 2) 累积均值归一化 -> CMNDF
    final cm = _cmnd;
    cm[0] = 1.0;
    var running = 0.0;
    for (var tau = 1; tau <= _maxLag; tau++) {
      running += d[tau];
      cm[tau] = running > 0 ? d[tau] * tau / running : 1.0;
    }

    // 3) 找"第一个显著谷底"：
    //    候选周期越多，归一化差分越小（最小值必然出现在最长周期），
    //    而真实周期是**最短**的那个显著谷底；取第一个下穿阈值的谷底可避免低八度误判。
    //    若阈值内无谷底（如基频弱、谐波强的音），退化为"相对能量最小的谷底"。
    var best = -1;
    var relaxed = false;
    for (var t = _tauMin; t <= _tauMax; t++) {
      if (cm[t] <= cm[best < 0 ? _tauMin : best]) best = t;
    }
    if (best < 0) return PitchFrame.none;
    final globalMin = cm[best];

    // 第一个低于阈值的谷底（含谷底内的局部最小下降段）
    var tau = _tauMin;
    while (tau <= _tauMax) {
      if (cm[tau] < threshold) {
        while (tau + 1 <= _tauMax && cm[tau + 1] < cm[tau]) {
          tau++;
        }
        break;
      }
      tau++;
    }
    if (tau > _tauMax) {
      // 绝对阈值未下穿：用差分能量相对最小值判断（YIN 论文的 d'(tau) 启发式）
      final tol = threshold * 1.35;
      var found = -1;
      for (var t = _tauMin; t <= _tauMax; t++) {
        if (d[t] <= globalMin * (1.0 + tol) && cm[t] <= 0.85) {
          while (t + 1 <= _tauMax && cm[t + 1] < cm[t] && d[t + 1] <= globalMin * (1.0 + tol)) {
            t++;
          }
          found = t;
          break;
        }
      }
      if (found < 0) return PitchFrame.none;
      tau = found;
      relaxed = true;
    }
    best = tau;

    // 4) 抛物线插值到亚采样精度（用谷底三点，先记录数值以免被后续写入覆盖）
    final xm = best > _tauMin ? cm[best - 1] : cm[best];
    final x0 = cm[best];
    final xp = best < _tauMax ? cm[best + 1] : cm[best];
    var refined = best.toDouble();
    final denom = xm - 2.0 * x0 + xp;
    if (denom != 0.0) {
      final delta = 0.5 * (xm - xp) / denom;
      if (delta > -1.0 && delta < 1.0) refined = best + delta;
    }
    if (refined < 2.0) refined = 2.0;

    final hz = sampleRate / refined;
    if (hz < minHz * 0.8 || hz > maxHz * 1.25) return PitchFrame.none;
    // 置信度：阈值内谷底直接取 1 - CMNDF；放宽判定时按裕度折减
    final conf = relaxed ? (1.0 - x0).clamp(0.0, 1.0) * 0.6 : (1.0 - x0).clamp(0.0, 1.0);
    return PitchFrame(hz, conf);
  }
}

/// 复音/混音里的主旋律提取：谐波求和显著度（harmonic salience）。
///
/// 对候选 F0 网格（按半音划分）累加其前 [maxHarmonics] 次谐波处的谱幅度，
/// 第 k 次谐波权重 = harmonicDecay^(k-1)；再做轻微平滑与低八度抑制。
///
/// 候选得分 = 基频谱峰强度 + [harmonicTieBreakWeight] × 谐波显著度。
/// 纯谐波求和天然偏向低音（低八度候选能把高音候选的整条谐波列都算进自己的谐波
/// 列，例如 440 是 110 的 4 次谐波），单靠它会把伴奏低音判成主旋律；因此最终
/// 排名以"基频分量本身是否有确凿谱峰能量"为主，与需求中的低八度规则一致。
class SalienceDetector {
  SalienceDetector({
    required this.sampleRate,
    this.fftSize = 2048,
    this.minHz = 55,
    this.maxHz = 1600,
    this.maxHarmonics = 12,
    this.harmonicDecay = 0.85,
    this.fundamentalWeight = 0.28,
  })  : assert(fftSize > 0),
        assert((fftSize & (fftSize - 1)) == 0, 'fftSize 必须是 2 的幂') {
    _fft = Fft(fftSize);
    _window = hannWindow(fftSize);
    _buf = Float64List(fftSize);
    _mag = Float64List((fftSize >> 1) + 1);
  }

  final int sampleRate;
  final int fftSize;
  final double minHz;
  final double maxHz;
  final int maxHarmonics;
  final double harmonicDecay;

  /// 基频谱峰项的权重（保留参数以保持构造签名稳定；实际由
  /// [harmonicTieBreakWeight] 与基频谱峰项共同决定候选排序）。
  final double fundamentalWeight;

  /// 候选得分中谐波显著度的次要权重（相对全谱峰值归一化）。
  final double harmonicTieBreakWeight = 0.15;

  late final Fft _fft;
  late final Float64List _window;
  late final Float64List _buf;
  late final Float64List _mag;

  /// 候选 F0 网格：自 minHz 起每半音一个，直到 maxHz。
  List<double> _gridHz() {
    final out = <double>[];
    final lo = math.log(math.max(minHz, 1e-6)) / _ln2;
    final hi = math.log(math.max(maxHz, minHz)) / _ln2;
    // 半音 = 1/12 个八度；用 log 域等距网格保证覆盖
    final semis = ((hi - lo) * 12.0).floor();
    for (var i = 0; i <= semis; i++) {
      out.add(math.pow(2.0, lo + i / 12.0).toDouble());
    }
    return out;
  }

  /// 输入长度应 >= fftSize（更长则截断，更短则补零）；返回最可能的主旋律音高。
  PitchFrame detect(Float64List frame) {
    if (frame.isEmpty) return PitchFrame.none;
    final grid = _gridHz();
    final res = _computeCurve(frame, penalize: true);
    if (res == null || res.curve.isEmpty) return PitchFrame.none;
    final curve = res.curve;
    final fs = res.fundamentalStrength;
    final maxMag = res.maxMag;
    final binHz = sampleRate / fftSize;
    final half = fftSize >> 1;

    // 选择准则：基频谱峰强度为主（与需求的低八度规则一致：基频分量本身要有能量），
    // 谐波显著度作次要与可视化用。
    var bestI = 0;
    var bestV = curve[0];
    for (var i = 1; i < grid.length; i++) {
      if (curve[i] > bestV) {
        bestV = curve[i];
        bestI = i;
      }
    }
    if (bestV <= 1e-9) return PitchFrame.none;
    // 基频谱峰需确凿存在（不是谱泄漏的旁瓣），否则视为无明确主旋律
    if (fs[bestI] < 0.15 * maxMag) return PitchFrame.none;

    final noteHz = grid[bestI];
    var hz = noteHz;
    // 亚半音细化：用基频所在 FFT bin 的抛物线插值给出谱峰精确位置。
    // 不在半音网格上做抛物线插值：低频处格距小于汉宁窗主瓣宽度，三点拟合病态。
    // 注意低音区精度受 bin 分辨率限制（2048 点 @22050Hz 时 1 bin ≈ 10.8Hz）。
    final bin = (noteHz / binHz).round();
    final pk = (bin >= 1 && bin < half) ? parabolicPeak(_mag, bin) : null;
    if (pk != null) {
      final refinedHz = pk.$2 * binHz;
      // 限制在半音以内，避免高次谐波或邻峰把结果拉走
      final ratio = refinedHz / noteHz;
      if (ratio > 0.9455 && ratio < 1.0595) {
        hz = refinedHz;
      }
    }

    // 置信度：基频谱峰相对全谱峰值 + 次高候选的裕度
    var second = 0.0;
    for (var i = 0; i < grid.length; i++) {
      if (i != bestI && curve[i] > second) second = curve[i];
    }
    var conf = fs[bestI] / maxMag;
    if (second > 0) {
      final margin = ((bestV - second) / bestV).clamp(0.0, 1.0);
      conf = (conf * (0.5 + 0.5 * margin)).clamp(0.0, 1.0);
    }
    return PitchFrame(hz, conf);
  }

  /// 便于测试/可视化：候选音高与其显著度（midi 从小到大，已做低八度抑制）。
  List<(double midi, double salience)> salienceCurve(Float64List frame) {
    if (frame.isEmpty) return const [];
    final grid = _gridHz();
    final res = _computeCurve(frame, penalize: true);
    if (res == null) return const [];
    final out = <(double, double)>[];
    for (var i = 0; i < grid.length; i++) {
      out.add((hzToMidi(grid[i]), res.curve[i]));
    }
    return out;
  }

  /// 计算显著度曲线（含 3 点半音平滑）与各候选的基频谱峰强度。
  /// 无有效能量时返回 null。
  _CurveResult? _computeCurve(Float64List frame, {required bool penalize}) {
    // 加窗 + 补零到 fftSize
    final n = math.min(frame.length, fftSize);
    for (var i = 0; i < fftSize; i++) {
      _buf[i] = i < n ? frame[i] * _window[i] : 0.0;
    }
    final mag = _fft.magnitudeSpectrum(_buf);
    _mag.setRange(0, mag.length, mag);
    final half = fftSize >> 1;
    final binHz = sampleRate / fftSize;

    var maxMag = 0.0;
    for (var i = 1; i <= half; i++) {
      if (_mag[i] > maxMag) maxMag = _mag[i];
    }
    if (maxMag <= 1e-12) return null;

    final grid = _gridHz();
    final harm = Float64List(grid.length);
    for (var c = 0; c < grid.length; c++) {
      final f0 = grid[c];
      var s = 0.0;
      var wsum = 0.0;
      var weight = 1.0;
      for (var k = 1; k <= maxHarmonics; k++) {
        final f = f0 * k;
        if (f > sampleRate * 0.5) break;
        // 谐波位置线性插值，抵消网格与 bin 的错位
        final pos = f / binHz;
        final i0 = pos.floor();
        if (i0 < 1 || i0 >= half) {
          weight *= harmonicDecay;
          continue;
        }
        final frac = pos - i0;
        final m = _mag[i0] * (1.0 - frac) + _mag[i0 + 1] * frac;
        s += m * weight;
        wsum += weight;
        weight *= harmonicDecay;
      }
      harm[c] = wsum > 0 ? s / wsum : 0.0;
    }

    // 基频谱峰强度：只有候选基频处确实存在局部谱峰时才计入，
    // 这样"某个音的 2/4 次谐波"这类伪候选（基频处只有泄漏旁瓣或谱谷）得零分。
    final fStrength = Float64List(grid.length);
    for (var c = 0; c < grid.length; c++) {
      final bin = (grid[c] / binHz).round();
      if (bin < 1 || bin > half) continue;
      if (_isLocalPeak(bin, half)) fStrength[c] = _mag[bin];
    }

    // 归一化后得分 = 基频谱峰强度 + 谐波显著度（次要权重），再平滑
    final raw = Float64List(grid.length);
    for (var c = 0; c < grid.length; c++) {
      raw[c] = fStrength[c] / maxMag + (harm[c] / maxMag) * harmonicTieBreakWeight;
    }
    final smooth = Float64List(grid.length);
    for (var i = 0; i < grid.length; i++) {
      final a = raw[i > 0 ? i - 1 : i];
      final b = raw[i];
      final c = raw[i < grid.length - 1 ? i + 1 : i];
      smooth[i] = (a + 2.0 * b + c) / 4.0;
    }

    // 倍频修正因子（作用在平滑后的得分上）
    final factor = Float64List(grid.length);
    factor.fillRange(0, factor.length, 1.0);
    if (penalize) {
      _correctOctave(grid, harm, factor, half, binHz);
    }
    final out = Float64List(grid.length);
    for (var i = 0; i < grid.length; i++) {
      out[i] = smooth[i] * factor[i];
    }
    return _CurveResult(out, fStrength, maxMag);
  }

  /// 低八度误判修正（谐波列内的基频主导原则）。
  ///
  /// 谐波求和天然偏向低音：候选越低，有效频带内的谐波越多，而且低候选能把高音
  /// 候选的整条谐波列都算进自己的谐波列（440 是 110 的 4 次谐波）。
  /// 判据：若候选 f0 的 2× / 4×（同一谐波列内更高的那个音）在**其基频处确凿存在
  /// 谱峰**，且该谱峰强度明显强于 f0 自身的基频谱峰，同时两者原始显著度相差不大
  /// （说明显著度差异由"谐波个数"而非"能量位置"造成），则判定 f0 只是把高音当成
  /// 了自己的谐波，压低 f0、让位给真正有能量的基频。
  void _correctOctave(
    List<double> grid,
    Float64List harm,
    Float64List factor,
    int half,
    double binHz,
  ) {
    for (var c = 0; c < grid.length; c++) {
      final f0 = grid[c];
      final bin = (f0 / binHz).round();
      if (bin < 1 || bin > half) continue;
      final ownStrength = _mag[bin];
      if (ownStrength <= 1e-12) continue;
      // 在 2× / 4× 两个倍频候选里挑基频谱峰最强的那个
      var bestK = 0;
      var bestStrength = ownStrength * 1.15; // 需明显强于自身基频才改判
      for (final k in const [2, 4]) {
        final idx = c + (k == 2 ? 12 : 24);
        if (idx >= grid.length) continue;
        final hb = (grid[idx] / binHz).round();
        if (hb < 1 || hb > half) continue;
        if (!_isLocalPeak(hb, half)) continue;
        if (_mag[hb] > bestStrength) {
          bestStrength = _mag[hb];
          bestK = k;
        }
      }
      if (bestK == 0) continue;
      final highIdx = c + (bestK == 2 ? 12 : 24);
      // 显著度需"相差不大"，否则原本的高分候选就是真基频
      if (harm[highIdx] < 0.4 * harm[c]) continue;
      factor[c] *= 0.5;
    }
  }

  /// bin 处是否为局部谱峰（对汉宁窗主瓣宽度留出余量）。
  bool _isLocalPeak(int bin, int half) {
    final lo = bin - 2 < 1 ? 1 : bin - 2;
    final hi = bin + 2 > half ? half : bin + 2;
    for (var i = lo; i <= hi; i++) {
      if (_mag[i] > _mag[bin]) return false;
    }
    return true;
  }
}

/// [_computeCurve] 的中间结果。
class _CurveResult {
  _CurveResult(this.curve, this.fundamentalStrength, this.maxMag);

  /// 平滑并做过倍频修正的候选得分曲线（与候选网格等长）。
  final Float64List curve;

  /// 各候选基频处的谱峰强度（基频处非局部谱峰则为 0）。
  final Float64List fundamentalStrength;

  /// 全谱最大幅度（用于归一化）。
  final double maxMag;
}

/// 均方根（音量强度），用于切分与清浊判断。
double rms(Float64List samples) {
  if (samples.isEmpty) return 0.0;
  var sum = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i];
    sum += v * v;
  }
  return math.sqrt(sum / samples.length);
}

/// 过零率（0..1），即相邻样本符号变化的占比，用于清浊/噪声判断。
double zeroCrossingRate(Float64List samples) {
  if (samples.length < 2) return 0.0;
  var count = 0;
  var prev = samples[0];
  for (var i = 1; i < samples.length; i++) {
    final cur = samples[i];
    if ((prev < 0 && cur >= 0) || (prev >= 0 && cur < 0)) count++;
    prev = cur;
  }
  return count / (samples.length - 1);
}
