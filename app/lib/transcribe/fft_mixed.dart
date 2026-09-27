/// 混合基 FFT：专门为了人声分离模型的 `n_fft = 5120`。
///
/// 为什么需要它：5120 = **5 × 1024**，不是 2 的幂 ✗ —— 常见的基 2 FFT 直接不能用，
/// 而零填充到 8192 会得到**错误的频点**（模型卡的宿主契约明确说窗口/bin 数不能换，
/// 见 `docs/和弦识别-测量记录.md` 的人声分离契约）。
///
/// 做法：Cooley-Tukey 分解 `N = 5 × M`：先做一次 radix-5 蝶形，再对 5 组长度 M 的子序列
/// 各做一次基 2 FFT ✓。M = 1024 是 2 的幂，所以复用现成的基 2 实现。
///
/// 与 Bluestein（chirp-z）相比：混合基是 O(N log N) 且常数小，
/// 每帧约 10 万次运算；Bluestein 要三次 16384 点 FFT（贵十几倍），
/// 而分离一段音频要跑 256 帧 × 2 声道，差的就是几秒与几十秒。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 就地基 2 FFT（输入长度必须是 2 的幂）
void fftRadix2(Float64List re, Float64List im, {bool inverse = false, bool scale = true}) {
  final n = re.length;
  if (n <= 1) return;
  if (n & (n - 1) != 0) {
    throw ArgumentError('基 2 FFT 要求 2 的幂长度，收到 $n');
  }
  // 位反转置换
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
    final ang = (inverse ? 2 : -2) * math.pi / len;
    final wr = math.cos(ang);
    final wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len >> 1; k++) {
        final ur = re[i + k], ui = im[i + k];
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
  if (inverse && scale) {
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

/// 就地 FFT，长度 = `5 × 2^k`（分离模型要的 5120 = 5 × 1024）
///
/// 按 Cooley-Tukey 抽取：把输入按 `n mod 5` 分成 5 组、各做长度 M = N/5 的基 2 FFT，
/// 再用长度 5 的 DFT 组合：
///   `X[p + s·M] = Σ_{m=0..4} (X_m[p] · W_N^{m·p}) · W_5^{m·s}`
/// （`p = K mod M`、`s = K div M`，所以写回的下标就是自然序 K ✓）
void fft5120(Float64List re, Float64List im, {bool inverse = false}) {
  final n = re.length;
  if (n % 5 != 0) throw ArgumentError('这个实现要求长度能被 5 整除，收到 $n');
  final m = n ~/ 5;
  if (m & (m - 1) != 0) throw ArgumentError('$n / 5 = $m 必须是 2 的幂');
  final sign = inverse ? 1.0 : -1.0;

  // 1) 按 n mod 5 分组，各做长度 m 的基 2 FFT，结果存到 subs[m][p]
  final subsRe = List<Float64List>.generate(5, (_) => Float64List(m));
  final subsIm = List<Float64List>.generate(5, (_) => Float64List(m));
  for (var r = 0; r < 5; r++) {
    for (var j = 0; j < m; j++) {
      subsRe[r][j] = re[5 * j + r];
      subsIm[r][j] = im[5 * j + r];
    }
    // 子 FFT 不缩放：总缩放交给外层（否则 1/m 与 1/n 会叠乘）
    fftRadix2(subsRe[r], subsIm[r], inverse: inverse, scale: false);
  }

  // 2) 组合：先乘 W_N^{m·p}，再做 5 点 DFT
  final w5r = List<double>.filled(5, 0), w5i = List<double>.filled(5, 0);
  for (var s = 0; s < 5; s++) {
    final a = sign * 2 * math.pi * s / 5;
    w5r[s] = math.cos(a);
    w5i[s] = math.sin(a);
  }
  final outRe = Float64List(n), outIm = Float64List(n);
  final tr = List<double>.filled(5, 0), ti = List<double>.filled(5, 0);
  for (var p = 0; p < m; p++) {
    for (var r = 0; r < 5; r++) {
      // 旋转因子 W_N^{r·p}
      final a = sign * 2 * math.pi * ((r * p) % n) / n;
      final c = math.cos(a), s2 = math.sin(a);
      final xr = subsRe[r][p], xi = subsIm[r][p];
      tr[r] = xr * c - xi * s2;
      ti[r] = xr * s2 + xi * c;
    }
    for (var s = 0; s < 5; s++) {
      var sr = 0.0, si = 0.0;
      for (var r = 0; r < 5; r++) {
        final idx = (r * s) % 5;
        sr += tr[r] * w5r[idx] - ti[r] * w5i[idx];
        si += tr[r] * w5i[idx] + ti[r] * w5r[idx];
      }
      outRe[p + s * m] = sr;
      outIm[p + s * m] = si;
    }
  }
  re.setAll(0, outRe);
  im.setAll(0, outIm);
  if (inverse) {
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

/// 便捷：对实数信号做一次 FFT，返回前 `n/2+1` 个复数值（频谱）
({Float64List re, Float64List im}) rfft(Float64List signal) {
  final n = signal.length;
  final re = Float64List(n);
  final im = Float64List(n);
  re.setAll(0, signal);
  if (n % 5 == 0 && ((n ~/ 5) & ((n ~/ 5) - 1)) == 0) {
    fft5120(re, im);
  } else {
    fftRadix2(re, im);
  }
  final half = n ~/ 2 + 1;
  return (re: Float64List.sublistView(re, 0, half), im: Float64List.sublistView(im, 0, half));
}
