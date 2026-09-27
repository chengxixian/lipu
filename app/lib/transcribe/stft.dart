/// 人声分离模型要的 STFT/ISTFT（宿主契约照 UVR-MDX KARA2 的模型卡，参数不能改）：
///
/// ```
/// 44100 Hz 立体声
/// n_fft 5120、hop 1024、periodic Hann（0.5 - 0.5cos(2πn/N)）
/// 帧居中：两端 reflect padding n_fft/2
/// 取 2561 个 bin 里的**前 2048 个**，且 bins 0..2 置零  → 输入 [1,4,2048,256]
/// 一块 = 256 帧 = 261,120 样本
/// 反变换：输出 bins 2048..2560 置零 → iSTFT → 逐块 overlap-add
/// ```
///
/// 5120 点 FFT 用 `fft_mixed.dart` 的混合基实现（5120 = 5×1024，不是 2 的幂）。
///
/// ⚠️ **信道顺序**：模型卡只说"顺序错了输出就错"，没写明是 `[L实, L虚, R实, R虚]`
/// 还是 `[L实, R实, L虚, R虚]`。这里默认前者（UVR/MDX 系的常见排法），
/// 并把它做成参数，接模型时若分离质量不对，先换这个顺序试。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'fft_mixed.dart';

class StftConst {
  static const int sampleRate = 44100;
  static const int nFft = 5120;
  static const int hop = 1024;
  static const int chunkFrames = 256;

  /// 一块覆盖的样本数（256 帧、帧距 1024 → 255 个 hop）
  static const int chunkSamples = hop * (chunkFrames - 1);

  /// 频谱 bin 总数（n_fft/2 + 1）
  static const int totalBins = nFft ~/ 2 + 1;

  /// 模型只吃前 2048 个 bin
  static const int modelBins = 2048;

  /// 前 3 个 bin 要置零（直流/极低频，模型不处理）
  static const int zeroLowBins = 3;
}

/// 周期 Hann 窗（注意是 periodic 不是 symmetric：分母用 N）
Float64List hannPeriodic(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
  }
  return w;
}

/// 反射取样本（两端 reflect padding，与模型卡的"frames centered with reflect padding"一致）
double _reflect(Float64List x, int i) {
  final n = x.length;
  if (n == 0) return 0;
  if (n == 1) return x[0];
  var j = i;
  while (j < 0 || j >= n) {
    if (j < 0) j = -j;
    if (j >= n) j = 2 * n - 2 - j;
  }
  return x[j];
}

/// 一块立体声 → 模型输入 `[4, 2048, chunkFrames]`（按 实/虚、左/右 排布，见文件头说明）
///
/// [start] 是这一块在整段音频里的起始样本下标（可为负，会走 reflect padding）。
Float32List stftChunk({
  required Float64List left,
  required Float64List right,
  required int start,
  Float64List? window,
  bool imagFirst = false,
}) {
  final w = window ?? hannPeriodic(StftConst.nFft);
  const nFft = StftConst.nFft, hop = StftConst.hop;
  const frames = StftConst.chunkFrames, bins = StftConst.modelBins;
  final out = Float32List(4 * bins * frames);

  final re = Float64List(nFft), im = Float64List(nFft);
  for (var t = 0; t < frames; t++) {
    final center = start + t * hop;
    final from = center - nFft ~/ 2;
    for (final ch in [0, 1]) {
      final src = ch == 0 ? left : right;
      for (var i = 0; i < nFft; i++) {
        re[i] = _reflect(src, from + i) * w[i];
        im[i] = 0;
      }
      fft5120(re, im);
      for (var b = 0; b < bins; b++) {
        final zeroed = b < StftConst.zeroLowBins;
        // 通道 0/1 是左/右；每个通道内 实部 与 虚部 各占一个通道
        final chRe = imagFirst ? 1 + ch * 2 : ch * 2;
        final chIm = imagFirst ? 0 + ch * 2 : ch * 2 + 1;
        out[(chRe * bins + b) * frames + t] = zeroed ? 0 : re[b];
        out[(chIm * bins + b) * frames + t] = zeroed ? 0 : im[b];
      }
    }
  }
  return out;
}

/// 模型输出 `[4, 2048, chunkFrames]` → 还原立体声，并**逐块 overlap-add** 到 [outLeft]/[outRight]
///
/// [start] 与 [stftChunk] 相同；[weight] 累加窗的平方（用于最后的归一化，标准 overlap-add 做法）。
void istftChunk({
  required Float32List spec,
  required Float64List outLeft,
  required Float64List outRight,
  required Float64List weight,
  required int start,
  Float64List? window,
  bool imagFirst = false,
}) {
  final w = window ?? hannPeriodic(StftConst.nFft);
  const nFft = StftConst.nFft, hop = StftConst.hop;
  const frames = StftConst.chunkFrames, bins = StftConst.modelBins;
  final re = Float64List(nFft), im = Float64List(nFft);

  for (var t = 0; t < frames; t++) {
    final center = start + t * hop;
    final from = center - nFft ~/ 2;
    for (final ch in [0, 1]) {
      final dst = ch == 0 ? outLeft : outRight;
      final chRe = imagFirst ? 1 + ch * 2 : ch * 2;
      final chIm = imagFirst ? 0 + ch * 2 : ch * 2 + 1;
      for (var i = 0; i < nFft; i++) {
        re[i] = 0;
        im[i] = 0;
      }
      // 只填回模型给的前 2048 个 bin（2048..2560 置零，符合契约）
      for (var b = 0; b < bins; b++) {
        re[b] = spec[(chRe * bins + b) * frames + t];
        im[b] = spec[(chIm * bins + b) * frames + t];
        // 共轭对称补齐，逆变换才是实信号
        final mirror = nFft - b;
        if (b > 0 && mirror < nFft) {
          re[mirror] = re[b];
          im[mirror] = -im[b];
        }
      }
      fft5120(re, im, inverse: true);
      for (var i = 0; i < nFft; i++) {
        final j = from + i;
        if (j < 0 || j >= dst.length) continue;
        final ww = w[i];
        dst[j] += re[i] * ww; // 合成窗
        if (ch == 0) weight[j] += ww * ww; // 窗平方用于归一化
      }
    }
  }
}

/// overlap-add 归一化：把累加结果除以窗平方和
void normalizeOverlapAdd(Float64List out, Float64List weight) {
  for (var i = 0; i < out.length; i++) {
    final wsum = weight[i];
    if (wsum > 1e-8) out[i] /= wsum;
  }
}
