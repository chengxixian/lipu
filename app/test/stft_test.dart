/// STFT/ISTFT 测试：**往返一致性**（合成 → 分析 → 合成回去）是这类 DSP 唯一靠谱的自检。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/stft.dart';

void main() {
  Float64List tone(int n, double f, {double amp = 0.5}) =>
      Float64List.fromList(List<double>.generate(n, (i) => amp * math.sin(2 * math.pi * f * i / StftConst.sampleRate)));

  test('周期 Hann 窗：首项为 0、中点接近 1、且 w[i] == w[i+N/2] 的对称性', () {
    final w = hannPeriodic(StftConst.nFft);
    expect(w[0], closeTo(0.0, 1e-12));
    expect(w[StftConst.nFft ~/ 2], closeTo(1.0, 1e-12));
    // periodic：w[i] = 0.5-0.5cos(2πi/N)，因此 w[i] 与 w[N-i] 相等
    expect(w[100], closeTo(w[StftConst.nFft - 100], 1e-12));
  });

  test('契约常量与模型卡一致', () {
    expect(StftConst.sampleRate, 44100);
    expect(StftConst.nFft, 5120);
    expect(StftConst.hop, 1024);
    expect(StftConst.chunkFrames, 256);
    expect(StftConst.chunkSamples, 261120, reason: '一块 = 261,120 样本（模型卡写的）');
    expect(StftConst.totalBins, 2561);
    expect(StftConst.modelBins, 2048);
  });

  test('STFT 输出形状与整流后的量：直流/极低频 bin 被置零', () {
    final n = StftConst.chunkSamples + StftConst.nFft;
    final left = tone(n, 440);
    final right = tone(n, 554.37, amp: 0.3);
    final spec = stftChunk(left: left, right: right, start: StftConst.nFft ~/ 2);
    expect(spec.length, 4 * 2048 * 256);
    // bins 0..2 必须为 0
    for (var ch = 0; ch < 4; ch++) {
      for (var b = 0; b < StftConst.zeroLowBins; b++) {
        for (var t = 0; t < 256; t += 37) {
          expect(spec[(ch * 2048 + b) * 256 + t], 0.0);
        }
      }
    }
  });

  test('往返：分析→合成能还原原信号（中间帧区域误差极小）', () {
    // 取两块长度，做 STFT 再 ISTFT + overlap-add 归一化
    final n = StftConst.chunkSamples * 2 + StftConst.nFft;
    final left = tone(n, 440);
    final right = tone(n, 660, amp: 0.4);
    final outL = Float64List(n), outR = Float64List(n), weight = Float64List(n);

    for (var block = 0; block * StftConst.chunkSamples < n; block++) {
      final start = block * StftConst.chunkSamples + StftConst.nFft ~/ 2;
      final spec = stftChunk(left: left, right: right, start: start);
      istftChunk(
        spec: spec,
        outLeft: outL,
        outRight: outR,
        weight: weight,
        start: start,
      );
    }
    normalizeOverlapAdd(outL, weight);
    normalizeOverlapAdd(outR, weight);

    // 只检查被窗完整覆盖的中段（边界处本来就不该期望完美）
    var maxErr = 0.0;
    for (var i = StftConst.nFft; i < n - StftConst.nFft; i++) {
      maxErr = math.max(maxErr, (outL[i] - left[i]).abs());
    }
    expect(maxErr, lessThan(0.02), reason: '中段往返最大误差 $maxErr');
  });

  test('反射填充：起点为负也能取到值（不会越界）', () {
    final left = tone(4096, 440);
    final right = tone(4096, 440);
    final spec = stftChunk(left: left, right: right, start: -StftConst.nFft);
    expect(spec.length, 4 * 2048 * 256);
    var energy = 0.0;
    for (final v in spec) {
      energy += v.abs();
    }
    expect(energy.isFinite, isTrue);
    expect(energy, greaterThan(0));
  });

  test('信道顺序可切换（模型卡没写明，接模型时可能要换）', () {
    final left = tone(StftConst.chunkSamples + StftConst.nFft, 440);
    final right = tone(StftConst.chunkSamples + StftConst.nFft, 880);
    final a = stftChunk(left: left, right: right, start: StftConst.nFft ~/ 2);
    final b = stftChunk(left: left, right: right, start: StftConst.nFft ~/ 2, imagFirst: true);
    var diff = 0.0;
    for (var i = 0; i < a.length; i++) {
      diff += (a[i] - b[i]).abs();
    }
    expect(diff, greaterThan(0), reason: '两种排布应当不同（否则这个开关是假的）');
  });
}
