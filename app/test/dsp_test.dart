/// dsp.dart 单元测试（纯 Dart 计算，无 Flutter 依赖；仅用 flutter_test 作为运行器）。
///
/// 全部误差数值都会 print 出来，便于人工核对精度。
// ignore_for_file: avoid_print
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/dsp.dart';

const int kSr = 22050;

/// 确定性伪随机数（避免 Random 实现差异导致测试不稳定），xorshift32。
class _Rng {
  int _s;
  _Rng(int seed) : _s = (seed == 0 ? 0x9E3779B9 : seed) & 0xFFFFFFFF;

  double nextUnit() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s / 4294967296.0;
  }

  /// [-amp, amp] 均匀白噪声
  double noise(double amp) => (nextUnit() * 2.0 - 1.0) * amp;
}

Float64List _sine(double hz, int n, {double amp = 1.0, int sr = kSr}) {
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amp * math.sin(2.0 * math.pi * hz * i / sr);
  }
  return out;
}

/// 三角波：只含奇次谐波，系数 1/k² 交替符号
Float64List _triangle(double hz, int n, {double amp = 1.0, int sr = kSr}) {
  final out = Float64List(n);
  var sign = 1.0;
  final norm = 8.0 / (math.pi * math.pi);
  for (var k = 1; k <= 9; k += 2) {
    final a = norm * sign / (k * k);
    for (var i = 0; i < n; i++) {
      out[i] += amp * a * math.sin(2.0 * math.pi * hz * k * i / sr);
    }
    sign = -sign;
  }
  return out;
}

/// 锯齿波：谐波系数 1/k，可指定谐波个数与衰减
Float64List _saw(
  double hz,
  int n, {
  int harmonics = 5,
  double amp = 1.0,
  int sr = kSr,
}) {
  final out = Float64List(n);
  var norm = 0.0;
  for (var k = 1; k <= harmonics; k++) {
    norm += 1.0 / k;
  }
  norm = 0.7 / norm;
  for (var k = 1; k <= harmonics; k++) {
    final a = norm / k;
    for (var i = 0; i < n; i++) {
      out[i] += amp * a * math.sin(2.0 * math.pi * hz * k * i / sr);
    }
  }
  return out;
}

/// 叠加若干 (频率, 幅度) 正弦分量
Float64List _mix(List<(double, double)> partials, int n, {int sr = kSr}) {
  final out = Float64List(n);
  for (final (hz, amp) in partials) {
    for (var i = 0; i < n; i++) {
      out[i] += amp * math.sin(2.0 * math.pi * hz * i / sr);
    }
  }
  return out;
}

void _addNoise(Float64List s, double amp, _Rng rng) {
  for (var i = 0; i < s.length; i++) {
    s[i] += rng.noise(amp);
  }
}

/// 音分误差
double _cents(double measured, double expected) => 1200.0 * math.log(measured / expected) / math.ln2;

int _peakBin(Float64List mag) {
  var bi = 1;
  for (var i = 2; i < mag.length; i++) {
    if (mag[i] > mag[bi]) bi = i;
  }
  return bi;
}

/// 朴素 DFT（O(n²)）作为 FFT 的交叉验证基准，只算指定 bin
double _naiveDftMag(Float64List x, int k) {
  var re = 0.0;
  var im = 0.0;
  final n = x.length;
  for (var i = 0; i < n; i++) {
    final a = -2.0 * math.pi * k * i / n;
    re += x[i] * math.cos(a);
    im += x[i] * math.sin(a);
  }
  return math.sqrt(re * re + im * im);
}

void main() {
  group('FFT 与频谱峰值', () {
    test('hannWindow 端点与对称性', () {
      final w = hannWindow(8);
      expect(w.length, 8);
      expect(w[0], closeTo(0.0, 1e-12));
      // 周期型汉宁窗：w[n/2] = 1
      expect(w[4], closeTo(1.0, 1e-12));
      expect(w[1], closeTo(w[7], 1e-12));
      expect(hannWindow(0).length, 0);
      expect(hannWindow(1)[0], 1.0);
    });

    test('FFT 与朴素 DFT 交叉验证', () {
      const n = 256;
      // magnitudeSpectrum 内部加汉宁窗，这里用同一窗函数构造输入后再逐 bin 对比
      final w = hannWindow(n);
      final x = Float64List(n);
      final raw = _sine(1000, n);
      for (var i = 0; i < n; i++) {
        x[i] = raw[i] * w[i];
      }
      final fft = Fft(n);
      final mag = fft.magnitudeSpectrum(raw);
      expect(mag.length, n ~/ 2 + 1);
      var worst = 0.0;
      for (var k = 0; k <= n ~/ 2; k++) {
        final err = (mag[k] - _naiveDftMag(x, k)).abs();
        worst = math.max(worst, err);
      }
      print('[FFT] 与朴素 DFT 全部 ${n ~/ 2 + 1} 个 bin 的最大绝对幅度差 = '
          '${worst.toStringAsExponential(3)}');
      expect(worst, lessThan(1e-6));
    });

    test('FFT 长度非法时抛错', () {
      expect(() => Fft(3), throwsA(isA<AssertionError>()));
      final f = Fft(8);
      expect(() => f.forward(Float64List(4), Float64List(8)), throwsArgumentError);
    });

    for (final hz in [440.0, 2000.0, 100.0]) {
      test('正弦 $hz Hz：峰值 bin 与抛物线插值精度', () {
        const size = 2048;
        final x = _sine(hz, size);
        final fft = Fft(size);
        final mag = fft.magnitudeSpectrum(x);
        final binHz = kSr / size;

        final bi = _peakBin(mag);
        final trueBin = hz / binHz;
        final binErr = (bi - trueBin).abs();
        print('[FFT $hz Hz] 峰值 bin=$bi 理论 bin=${trueBin.toStringAsFixed(3)} '
            'bin 误差=${binErr.toStringAsFixed(4)} (1 bin = ${binHz.toStringAsFixed(3)} Hz)');
        expect(binErr, lessThan(1.0));

        final pk = parabolicPeak(mag, bi);
        expect(pk, isNotNull);
        final (_, exactBin, peakMag) = pk!;
        final estHz = exactBin * binHz;
        final hzErr = (estHz - hz).abs();
        print('[FFT $hz Hz] 插值 bin=${exactBin.toStringAsFixed(4)} '
            '-> ${estHz.toStringAsFixed(3)} Hz，误差=${hzErr.toStringAsFixed(4)} Hz，'
            '峰值幅度=${peakMag.toStringAsFixed(3)}');
        expect(hzErr, lessThan(2.0));
      });
    }

    test('parabolicPeak 边界返回 null，非峰处仍可插值', () {
      final mag = Float64List.fromList([1, 2, 3, 2, 1]);
      expect(parabolicPeak(mag, 0), isNull);
      expect(parabolicPeak(mag, 4), isNull);
      final pk = parabolicPeak(mag, 2)!;
      expect(pk.$2, closeTo(2.0, 1e-9));
    });

    test('静音输入安全', () {
      final fft = Fft(1024);
      final mag = fft.magnitudeSpectrum(Float64List(1024));
      var sum = 0.0;
      for (final v in mag) {
        sum += v;
      }
      expect(sum, 0.0);
      // 空数组也不应抛异常
      expect(fft.magnitudeSpectrum(Float64List(0)).length, 513);
      // 短于 fftSize 的输入补零处理
      expect(fft.magnitudeSpectrum(Float64List(100)).length, 513);
    });
  });

  group('音高换算', () {
    test('A4 = 440Hz <-> midi 69', () {
      expect(hzToMidi(440.0), closeTo(69.0, 1e-9));
      expect(midiToHz(69.0), closeTo(440.0, 1e-9));
    });

    test('midi 60 约为 261.63Hz', () {
      final hz = midiToHz(60);
      print('[换算] midi 60 -> ${hz.toStringAsFixed(4)} Hz，误差=${(hz - 261.6256).abs().toStringAsFixed(4)} Hz');
      expect((hz - 261.63).abs(), lessThan(0.5));
      expect(hzToMidi(hz), closeTo(60.0, 1e-9));
    });

    test('往返一致性与非法输入', () {
      for (final m in [21.0, 48.0, 60.0, 69.0, 96.0, 108.0]) {
        expect(hzToMidi(midiToHz(m)), closeTo(m, 1e-9));
      }
      expect(hzToMidi(0), isNaN);
      expect(hzToMidi(-5), isNaN);
      expect(midiToHz(double.nan), 0.0);
      expect(midiToHz(double.infinity), 0.0);
      // 一个八度恰好 12 个半音
      expect(hzToMidi(880.0) - hzToMidi(440.0), closeTo(12.0, 1e-9));
    });
  });

  group('YIN 单声部基频', () {
    test('正弦 / 三角波 / 锯齿波（含 5% 白噪声）误差 < 25 音分', () {
      final det = YinDetector(sampleRate: kSr, frameSize: 1024);
      const n = 2048;
      final rng = _Rng(20240501);
      final cases = <(String, double, Float64List Function(double, int))>[
        ('正弦', 220.0, (f, n) => _sine(f, n)),
        ('正弦', 440.0, (f, n) => _sine(f, n)),
        ('正弦', 880.0, (f, n) => _sine(f, n)),
        ('三角波', 220.0, (f, n) => _triangle(f, n)),
        ('三角波', 440.0, (f, n) => _triangle(f, n)),
        ('三角波', 880.0, (f, n) => _triangle(f, n)),
        ('锯齿波(5 次谐波)', 220.0, (f, n) => _saw(f, n, harmonics: 5)),
        ('锯齿波(5 次谐波)', 440.0, (f, n) => _saw(f, n, harmonics: 5)),
        ('锯齿波(5 次谐波)', 880.0, (f, n) => _saw(f, n, harmonics: 5)),
      ];
      var worst = 0.0;
      for (final (name, f0, gen) in cases) {
        final x = gen(f0, n);
        _addNoise(x, 0.05, rng);
        final r = det.detect(x);
        final err = r.hz > 0 ? _cents(r.hz, f0) : double.infinity;
        worst = math.max(worst, err.abs());
        print('[YIN] $name ${f0}Hz -> ${r.hz.toStringAsFixed(2)}Hz '
            '误差=${err.toStringAsFixed(2)} 音分，confidence=${r.confidence.toStringAsFixed(3)}');
        expect(r.hz, greaterThan(0));
        expect(err.abs(), lessThan(25.0), reason: '$name ${f0}Hz 误差 ${err.toStringAsFixed(2)} 音分');
      }
      print('[YIN] 上述 9 例最大误差 = ${worst.toStringAsFixed(2)} 音分');
    });

    test('静音 / 直流 / 全零输入返回 hz = 0', () {
      final det = YinDetector(sampleRate: kSr, frameSize: 1024);
      final silent = det.detect(Float64List(1024));
      print('[YIN] 全零 -> hz=${silent.hz}, voiced=${silent.voiced}');
      expect(silent.hz, 0.0);
      expect(silent.voiced, isFalse);

      final dc = Float64List(1024);
      dc.fillRange(0, 1024, 0.7);
      final rdc = det.detect(dc);
      print('[YIN] 直流 -> hz=${rdc.hz}, voiced=${rdc.voiced}');
      expect(rdc.hz, 0.0);

      // 空数组（短于 frameSize 会补零）
      expect(det.detect(Float64List(0)).hz, 0.0);

      final rng = _Rng(7);
      final noise = Float64List(1024);
      for (var i = 0; i < noise.length; i++) {
        noise[i] = rng.noise(0.3);
      }
      final rn = det.detect(noise);
      print('[YIN] 纯白噪声 -> hz=${rn.hz.toStringAsFixed(2)}, confidence=${rn.confidence.toStringAsFixed(3)}');
    });

    test('抗八度错误：二次谐波更强的 200Hz 不应跳到 400Hz', () {
      final det = YinDetector(sampleRate: kSr, frameSize: 1024);
      const n = 2048;
      // 基频 200Hz 幅度 1.0，二次谐波 400Hz 幅度 2.0
      final x = _mix([(200.0, 1.0), (400.0, 2.0)], n);
      final r = det.detect(x);
      print('[YIN 抗八度] 200Hz(1.0) + 400Hz(2.0) -> ${r.hz.toStringAsFixed(2)}Hz '
          '误差=${_cents(r.hz, 200.0).toStringAsFixed(2)} 音分，confidence=${r.confidence.toStringAsFixed(3)}');
      expect(_cents(r.hz, 200.0).abs(), lessThan(25.0));

      // 更极端：400Hz 幅度是基频 4 倍（如实记录是否仍能守住低八度）
      final x2 = _mix([(200.0, 1.0), (400.0, 4.0)], n);
      final r2 = det.detect(x2);
      print('[YIN 抗八度-极端] 200Hz(1.0) + 400Hz(4.0) -> ${r2.hz.toStringAsFixed(2)}Hz '
          '相对 200Hz 误差=${_cents(r2.hz, 200.0).toStringAsFixed(2)} 音分，'
          '相对 400Hz 误差=${_cents(r2.hz, 400.0).toStringAsFixed(2)} 音分');

      // 纯二次谐波（无基频能量）时，YIN 只能给出 400Hz，这是方法的固有局限
      final x3 = _sine(400.0, n);
      final r3 = det.detect(x3);
      print('[YIN 局限] 纯 400Hz 正弦 -> ${r3.hz.toStringAsFixed(2)}Hz（无基频分量可依据）');
      expect(_cents(r3.hz, 400.0).abs(), lessThan(25.0));
    });

    test('低音区帧长限制：55Hz 需要足够长的帧', () {
      const n = 4096;
      final short = YinDetector(sampleRate: kSr, frameSize: 1024);
      final long = YinDetector(sampleRate: kSr, frameSize: 4096);
      final x = _sine(55.0, n);
      final rs = short.detect(x);
      final rl = long.detect(x);
      print('[YIN 低音] 55Hz：frameSize=1024 -> ${rs.hz.toStringAsFixed(2)}Hz '
          '（lag 上限 512 = ${(kSr / 512).toStringAsFixed(1)}Hz 下限，低于此无法估计）');
      print('[YIN 低音] 55Hz：frameSize=4096 -> ${rl.hz.toStringAsFixed(2)}Hz '
          '误差=${_cents(rl.hz, 55.0).toStringAsFixed(2)} 音分');
      expect(rl.hz, closeTo(55.0, 2.0));
    });
  });

  group('Salience 旋律提取', () {
    test('主旋律 440Hz + 伴奏 110/330Hz：结果落在 440Hz 附近', () {
      const n = 4096;
      final x = _mix([(440.0, 1.0), (110.0, 0.5), (330.0, 0.5)], n);
      final det = SalienceDetector(sampleRate: kSr, fftSize: 2048);
      final r = det.detect(x);
      final err = r.hz > 0 ? _cents(r.hz, 440.0) : double.infinity;
      print('[Salience] 440(1.0)+110(0.5)+330(0.5) -> ${r.hz.toStringAsFixed(2)}Hz '
          '误差=${err.toStringAsFixed(2)} 音分，confidence=${r.confidence.toStringAsFixed(3)}');
      expect(r.hz, greaterThan(0));
      expect(err.abs(), lessThan(30.0));
    });

    test('salienceCurve 在 440Hz 附近有局部极大', () {
      const n = 4096;
      final x = _mix([(440.0, 1.0), (110.0, 0.5), (330.0, 0.5)], n);
      final det = SalienceDetector(sampleRate: kSr, fftSize: 2048);
      final curve = det.salienceCurve(x);
      expect(curve, isNotEmpty);
      // 调试：打印关键候选的显著度与频谱峰值
      final dbgFft = Fft(2048);
      final w = hannWindow(2048);
      final buf = Float64List(2048);
      for (var i = 0; i < 2048; i++) {
        buf[i] = x[i] * w[i];
      }
      final mag = dbgFft.magnitudeSpectrum(buf);
      final binHz = kSr / 2048;
      final dbg = <double>[55, 110, 220, 330, 440, 660, 880, 1320];
      print('[Salience 调试] 频谱峰值：${dbg.map((f) => '${f}Hz=${mag[(f / binHz).round()].toStringAsFixed(2)}').join(', ')}');
      print('[Salience 调试] 曲线（55..700Hz）：${curve.where((e) => midiToHz(e.$1) <= 700).map((e) => '${midiToHz(e.$1).toStringAsFixed(1)}=${e.$2.toStringAsFixed(3)}').join(', ')}');
      var bi = 0;
      for (var i = 1; i < curve.length; i++) {
        if (curve[i].$2 > curve[bi].$2) bi = i;
      }
      final peakMidi = curve[bi].$1;
      final peakHz = midiToHz(peakMidi);
      print('[Salience] 曲线 ${curve.length} 个候选（${midiToHz(curve.first.$1).toStringAsFixed(1)}'
          '~${midiToHz(curve.last.$1).toStringAsFixed(1)}Hz），'
          '显著度峰值 midi=${peakMidi.toStringAsFixed(2)} (${peakHz.toStringAsFixed(2)}Hz) '
          '-> 相对 440Hz 误差=${_cents(peakHz, 440.0).toStringAsFixed(2)} 音分');
      expect((peakHz - 440.0).abs() / 440.0, lessThan(0.03));

      // 存在一个 midi 在 440Hz 的 ±35 音分内、且显著度不低于全局峰值 95% 的候选
      final target = hzToMidi(440.0);
      var nearMax = 0.0;
      var nearMidi = double.nan;
      for (final (m, s) in curve) {
        if ((m - target).abs() < 0.35 && s > nearMax) {
          nearMax = s;
          nearMidi = m;
        }
      }
      print('[Salience] 440Hz 邻域最大显著度=${nearMax.toStringAsFixed(4)} '
          '(midi=${nearMidi.toStringAsFixed(2)})，全局峰值=${curve[bi].$2.toStringAsFixed(4)}');
      expect(nearMax, greaterThan(curve[bi].$2 * 0.95));
    });

    test('纯 880Hz 正弦不应被判成低八度 440Hz', () {
      const n = 4096;
      final x = _sine(880.0, n);
      final det = SalienceDetector(sampleRate: kSr, fftSize: 2048);
      final r = det.detect(x);
      print('[Salience 抗八度] 纯 880Hz -> ${r.hz.toStringAsFixed(2)}Hz '
          '误差=${_cents(r.hz, 880.0).toStringAsFixed(2)} 音分');
      expect(_cents(r.hz, 880.0).abs(), lessThan(40.0));
    });

    test('谐波丰富的主旋律（12 次谐波锯齿波）不跳到高八度', () {
      const n = 4096;
      final x = _saw(440.0, n, harmonics: 12);
      final det = SalienceDetector(sampleRate: kSr, fftSize: 2048);
      final r = det.detect(x);
      final err = r.hz > 0 ? _cents(r.hz, 440.0) : double.infinity;
      print('[Salience] 12 次谐波锯齿波 440Hz -> ${r.hz.toStringAsFixed(2)}Hz '
          '误差=${err.toStringAsFixed(2)} 音分');
      expect(err.abs(), lessThan(40.0));
    });

    test('基频占优的纯低音（110Hz）返回基频而非更高八度', () {
      const n = 4096;
      final x = _sine(110.0, n);
      final det = SalienceDetector(sampleRate: kSr, fftSize: 2048);
      final r = det.detect(x);
      // 低音区精度受 FFT 分辨率限制：bin = 10.77Hz，110Hz 处 1 bin ≈ 165 音分，
      // 抛物线插值仍有约 5~10 音分系统偏差（详见最终报告"已知限制"）。
      final err = r.hz > 0 ? _cents(r.hz, 110.0) : double.infinity;
      print('[Salience] 纯 110Hz -> ${r.hz.toStringAsFixed(2)}Hz 误差=${err.toStringAsFixed(2)} 音分'
          '（低音区受 bin 分辨率限制）');
      expect(err.abs(), lessThan(60.0));
      // 关键是不跳到 220Hz（+1200 音分）
      expect((r.hz - 220.0).abs(), greaterThan(50.0));
    });

    test('静音 / 空输入安全返回 hz = 0', () {
      final det = SalienceDetector(sampleRate: kSr, fftSize: 1024);
      expect(det.detect(Float64List(0)).hz, 0.0);
      expect(det.detect(Float64List(1024)).hz, 0.0);
      expect(det.salienceCurve(Float64List(0)), isEmpty);
      print('[Salience] 静音/空输入 -> hz=0，曲线为空');
    });

    test('候选网格覆盖 55Hz..1600Hz 且按半音递增', () {
      final det = SalienceDetector(sampleRate: kSr, fftSize: 2048);
      final curve = det.salienceCurve(_sine(440.0, 2048));
      final steps = <double>[];
      for (var i = 1; i < curve.length; i++) {
        steps.add(curve[i].$1 - curve[i - 1].$1);
      }
      print('[Salience] 网格半音步长 min=${steps.reduce(math.min).toStringAsFixed(6)} '
          'max=${steps.reduce(math.max).toStringAsFixed(6)}，候选数=${curve.length}');
      expect(steps.reduce(math.min), closeTo(1.0, 1e-6));
      expect(steps.reduce(math.max), closeTo(1.0, 1e-6));
      expect(midiToHz(curve.first.$1), closeTo(55.0, 0.5));
      expect(midiToHz(curve.last.$1), greaterThan(1500.0));
    });
  });

  group('性能与安全性', () {
    test('单帧 FFT / YIN 耗时满足实时要求（10~20ms 一帧）', () {
      final fft = Fft(2048);
      final frame = _sine(440.0, 2048);
      final sw1 = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        fft.magnitudeSpectrum(frame);
      }
      sw1.stop();
      final fftMs = sw1.elapsedMicroseconds / 200 / 1000.0;

      final yin = YinDetector(sampleRate: kSr, frameSize: 1024);
      final yinFrame = _sine(220.0, 2048);
      final sw2 = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        yin.detect(yinFrame);
      }
      sw2.stop();
      final yinMs = sw2.elapsedMicroseconds / 100 / 1000.0;

      final sal = SalienceDetector(sampleRate: kSr, fftSize: 2048);
      final salFrame = _sine(440.0, 2048);
      final sw3 = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        sal.detect(salFrame);
      }
      sw3.stop();
      final salMs = sw3.elapsedMicroseconds / 100 / 1000.0;

      print('[性能] 2048 点 FFT+幅度谱 ${fftMs.toStringAsFixed(3)} ms/帧；'
          'YIN(1024 帧) ${yinMs.toStringAsFixed(3)} ms/帧；'
          'Salience(2048) ${salMs.toStringAsFixed(3)} ms/帧');
      expect(fftMs, lessThan(5.0));
      expect(yinMs, lessThan(10.0));
      expect(salMs, lessThan(20.0));
    });

    test('空数组与全零输入对所有 API 安全', () {
      final empty = Float64List(0);
      expect(rms(empty), 0.0);
      expect(zeroCrossingRate(empty), 0.0);
      expect(Fft(512).magnitudeSpectrum(empty).length, 257);
      expect(YinDetector(sampleRate: kSr, frameSize: 512).detect(empty).hz, 0.0);
      expect(SalienceDetector(sampleRate: kSr, fftSize: 512).detect(empty).hz, 0.0);
      expect(SalienceDetector(sampleRate: kSr, fftSize: 512).salienceCurve(empty), isEmpty);
      final zeros = Float64List(4096);
      expect(YinDetector(sampleRate: kSr, frameSize: 1024).detect(zeros).hz, 0.0);
      expect(SalienceDetector(sampleRate: kSr, fftSize: 2048).detect(zeros).hz, 0.0);
      print('[安全] 空数组/全零输入：所有 API 均无异常且返回 hz=0');
    });
  });

  group('RMS 与过零率', () {
    test('正弦 RMS = A/√2', () {
      final x = _sine(440.0, 4096, amp: 0.5);
      final r = rms(x);
      print('[RMS] 440Hz A=0.5 -> ${r.toStringAsFixed(6)}，理论 ${(0.5 / math.sqrt2).toStringAsFixed(6)}，'
          '误差=${(r - 0.5 / math.sqrt2).abs().toStringAsExponential(3)}');
      expect(r, closeTo(0.5 / math.sqrt2, 1e-3));
      expect(rms(Float64List(0)), 0.0);
      expect(rms(Float64List(64)), 0.0);
    });

    test('过零率与频率一致', () {
      final x = _sine(440.0, 4096);
      final z = zeroCrossingRate(x);
      final expectZ = 2.0 * 440.0 / kSr;
      print('[ZCR] 440Hz -> ${z.toStringAsFixed(6)}，理论 ${expectZ.toStringAsFixed(6)}');
      expect(z, closeTo(expectZ, 1e-3));

      final noise = Float64List(4096);
      final rng = _Rng(99);
      for (var i = 0; i < noise.length; i++) {
        noise[i] = rng.noise(1.0);
      }
      final zn = zeroCrossingRate(noise);
      print('[ZCR] 白噪声 -> ${zn.toStringAsFixed(6)}（接近 0.5）');
      expect(zn, greaterThan(0.4));
      expect(zn, lessThan(0.6));

      expect(zeroCrossingRate(Float64List(1)), 0.0);
      expect(zeroCrossingRate(Float64List(0)), 0.0);
    });
  });
}
