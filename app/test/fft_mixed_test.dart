/// 混合基 FFT 测试：与**朴素 DFT** 对照（正确性不靠自证）。
///
/// 分离模型要 `n_fft = 5120 = 5 × 1024`，不是 2 的幂，所以专门写了 radix-5 + radix-2
/// 的混合基实现；这里用小尺寸（10 = 5×2、20 = 5×4）逐点对照 O(N²) 的朴素 DFT，
/// 再用 5120 点做正弦/逆变换往返验证。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/fft_mixed.dart';

/// 朴素 DFT（O(N²)，只用于测试对照）
({Float64List re, Float64List im}) naiveDft(Float64List x, {bool inverse = false}) {
  final n = x.length;
  final re = Float64List(n), im = Float64List(n);
  final sign = inverse ? 1.0 : -1.0;
  for (var k = 0; k < n; k++) {
    var sr = 0.0, si = 0.0;
    for (var t = 0; t < n; t++) {
      final a = sign * 2 * math.pi * k * t / n;
      sr += x[t] * math.cos(a);
      si += x[t] * math.sin(a);
    }
    re[k] = inverse ? sr / n : sr;
    im[k] = inverse ? si / n : si;
  }
  return (re: re, im: im);
}

void main() {
  Float64List signal(int n, double Function(int) f) =>
      Float64List.fromList(List<double>.generate(n, f));

  test('长度 10（5×2）：与朴素 DFT 逐点一致', () {
    final n = 10;
    final x = signal(n, (i) => math.sin(i * 1.3) + 0.4 * math.cos(i * 2.7));
    final want = naiveDft(x);
    final re = Float64List.fromList(x), im = Float64List(n);
    fft5120(re, im);
    for (var k = 0; k < n; k++) {
      expect(re[k], closeTo(want.re[k], 1e-9), reason: '实部 k=$k');
      expect(im[k], closeTo(want.im[k], 1e-9), reason: '虚部 k=$k');
    }
  });

  test('长度 20（5×4）：与朴素 DFT 逐点一致', () {
    final n = 20;
    final x = signal(n, (i) => math.sin(i * 0.7) * math.exp(-i / 30) + 0.2);
    final want = naiveDft(x);
    final re = Float64List.fromList(x), im = Float64List(n);
    fft5120(re, im);
    for (var k = 0; k < n; k++) {
      expect(re[k], closeTo(want.re[k], 1e-9));
      expect(im[k], closeTo(want.im[k], 1e-9));
    }
  });

  test('5120 点：已知正弦的峰值落在正确的频点', () {
    const n = 5120;
    const bin = 100;
    final x = signal(n, (i) => math.cos(2 * math.pi * bin * i / n));
    final spec = rfft(x);
    var best = 0;
    var bestMag = -1.0;
    for (var k = 1; k < spec.re.length; k++) {
      final mag = math.sqrt(spec.re[k] * spec.re[k] + spec.im[k] * spec.im[k]);
      if (mag > bestMag) {
        bestMag = mag;
        best = k;
      }
    }
    expect(best, bin, reason: '峰值必须落在第 $bin 个频点');
    // 峰值能量应当接近 N/2
    expect(bestMag, closeTo(n / 2, n * 0.02));
  });

  test('5120 点：正变换 → 逆变换能还原（往返误差极小）', () {
    const n = 5120;
    final x = signal(n, (i) => math.sin(i * 0.013) + 0.3 * math.cos(i * 0.21));
    final re = Float64List.fromList(x), im = Float64List(n);
    fft5120(re, im);
    fft5120(re, im, inverse: true);
    var maxErr = 0.0;
    for (var i = 0; i < n; i++) {
      maxErr = math.max(maxErr, (re[i] - x[i]).abs());
    }
    expect(maxErr, lessThan(1e-9), reason: '往返最大误差 $maxErr');
  });

  test('基 2 路径仍然正确（1024 点往返）', () {
    const n = 1024;
    final x = signal(n, (i) => math.sin(i * 0.05) + 0.1);
    final re = Float64List.fromList(x), im = Float64List(n);
    fftRadix2(re, im);
    fftRadix2(re, im, inverse: true);
    for (var i = 0; i < n; i += 97) {
      expect(re[i], closeTo(x[i], 1e-9));
    }
  });

  test('长度不合法时明确报错（不静默算错）', () {
    expect(() => fftRadix2(Float64List(6), Float64List(6)), throwsArgumentError);
    expect(() => fft5120(Float64List(12), Float64List(12)), throwsArgumentError); // 12/5 不是 2 的幂
  });
}
