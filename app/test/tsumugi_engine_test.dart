/// Tsumugi 解码——**区间打分矩阵**部分的测试（纯函数，不需要 ONNX）。
///
/// 打分规则照 `semi_crf.py` 的移植契约：
///   对角 `t==u` 用 `interval_diag`；`t<u` 用 query·key 双线性；
///   `t>u` 非法；再加 note_bias 与长度项（checkpoint 用的是 `none` + 0.0）。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/tsumugi_engine.dart';

void main() {
  // 小规模张量：3 帧 × 2 音高 × 4 维
  const frames = 3, keys = 2, dim = 4;

  Float32List query() {
    final q = Float32List(frames * keys * dim);
    for (var t = 0; t < frames; t++) {
      for (var k = 0; k < keys; k++) {
        for (var d = 0; d < dim; d++) {
          q[(t * keys + k) * dim + d] = (t + 1) * (k + 1) * (d + 1) * 0.1;
        }
      }
    }
    return q;
  }

  Float32List key() {
    final k2 = Float32List(frames * keys * dim);
    for (var u = 0; u < frames; u++) {
      for (var k = 0; k < keys; k++) {
        for (var d = 0; d < dim; d++) {
          k2[(u * keys + k) * dim + d] = (d + 1) * 0.5 - u * 0.05;
        }
      }
    }
    return k2;
  }

  Float32List diag() {
    final d = Float32List(frames * keys);
    for (var i = 0; i < d.length; i++) {
      d[i] = 100.0 + i;
    }
    return d;
  }

  /// 手工算 query[begin] · key[end]（官方 einsum("tnd,snd->stn")）
  double dot(Float32List q, Float32List k, int begin, int end, int pitch) {
    var s = 0.0;
    for (var d = 0; d < dim; d++) {
      s += q[(begin * keys + pitch) * dim + d] * k[(end * keys + pitch) * dim + d];
    }
    return s;
  }

  test('对角项 = 双线性项 + interval_diag（官方是"加上"，不是替换）', () {
    final q = query(), kk = key(), d = diag();
    final s = buildIntervalScores(
      intervalQuery: q,
      intervalKey: kk,
      intervalDiag: d,
      frames: frames,
      keys: keys,
      dim: dim,
    );
    for (var t = 0; t < frames; t++) {
      for (var p = 0; p < keys; p++) {
        final want = dot(q, kk, t, t, p) + (100.0 + t * keys + p);
        expect(intervalScoreAt(s, frames, keys, t: t, u: t, k: p), closeTo(want, 1e-3));
      }
    }
  });

  test('非对角项 = query[t] · key[u]（双线性）', () {
    final q = query(), kk = key();
    final s = buildIntervalScores(
      intervalQuery: q,
      intervalKey: kk,
      intervalDiag: diag(),
      frames: frames,
      keys: keys,
      dim: dim,
    );
    // 手工算 t=0,u=2,k=1 的点积
    var want = 0.0;
    for (var d = 0; d < dim; d++) {
      want += q[(0 * keys + 1) * dim + d] * kk[(2 * keys + 1) * dim + d];
    }
    expect(intervalScoreAt(s, frames, keys, t: 0, u: 2, k: 1), closeTo(want, 1e-4));
  });

  test('t > u 非法（-inf），不会被 Viterbi 选中', () {
    final s = buildIntervalScores(
      intervalQuery: query(),
      intervalKey: key(),
      intervalDiag: diag(),
      frames: frames,
      keys: keys,
      dim: dim,
    );
    expect(intervalScoreAt(s, frames, keys, t: 2, u: 0, k: 0), double.negativeInfinity);
    expect(intervalScoreAt(s, frames, keys, t: 1, u: 1, k: 0).isFinite, isTrue);
  });

  test('note_bias 加到所有合法区间上', () {
    final q = query(), kk = key(), d = diag();
    final a = buildIntervalScores(
        intervalQuery: q, intervalKey: kk, intervalDiag: d, frames: frames, keys: keys, dim: dim);
    final b = buildIntervalScores(
        intervalQuery: q,
        intervalKey: kk,
        intervalDiag: d,
        frames: frames,
        keys: keys,
        dim: dim,
        noteBias: 2.5);
    expect(intervalScoreAt(b, frames, keys, t: 0, u: 1, k: 0) -
            intervalScoreAt(a, frames, keys, t: 0, u: 1, k: 0),
        closeTo(2.5, 1e-4));
    expect(intervalScoreAt(b, frames, keys, t: 1, u: 1, k: 1) -
            intervalScoreAt(a, frames, keys, t: 1, u: 1, k: 1),
        closeTo(2.5, 1e-4));
  });

  test('长度缩放照官方：score *= |end-begin|（none 则不变）', () {
    final q = query(), kk = key(), d = diag();
    final none = buildIntervalScores(
        intervalQuery: q,
        intervalKey: kk,
        intervalDiag: d,
        frames: frames,
        keys: keys,
        dim: dim,
        lengthScaling: SemiCrfLengthScaling.none);
    final linear = buildIntervalScores(
        intervalQuery: q,
        intervalKey: kk,
        intervalDiag: d,
        frames: frames,
        keys: keys,
        dim: dim,
        lengthScaling: SemiCrfLengthScaling.linear);
    // 区间 [0,2]：|2-0| = 2 → linear 的分数应当是 none 的 2 倍
    final a = intervalScoreAt(none, frames, keys, t: 0, u: 2, k: 0);
    final b = intervalScoreAt(linear, frames, keys, t: 0, u: 2, k: 0);
    expect(b, closeTo(a * 2, 1e-3));
  });

  test('长度惩罚照官方：score -= |end-begin| * penalty', () {
    final q = query(), kk = key(), d = diag();
    final base = buildIntervalScores(
        intervalQuery: q, intervalKey: kk, intervalDiag: d, frames: frames, keys: keys, dim: dim);
    final pen = buildIntervalScores(
        intervalQuery: q,
        intervalKey: kk,
        intervalDiag: d,
        frames: frames,
        keys: keys,
        dim: dim,
        lengthPenalty: 1.5);
    // [0,2]：|2-0| = 2 → 比基准少 3.0（frames=3，索引 0..2）
    expect(intervalScoreAt(base, frames, keys, t: 0, u: 2, k: 1) -
            intervalScoreAt(pen, frames, keys, t: 0, u: 2, k: 1),
        closeTo(3.0, 1e-3));
  });

  test('topIntervals 按分数排序，便于排障', () {
    final s = buildIntervalScores(
      intervalQuery: query(),
      intervalKey: key(),
      intervalDiag: diag(),
      frames: frames,
      keys: keys,
      dim: dim,
    );
    final top = topIntervals(s, frames, keys, limit: 3);
    expect(top.length, 3);
    expect(top.first.score, greaterThanOrEqualTo(top.last.score));
    // 对角项是 100 起步，所以最高分一定来自对角
    expect(top.first.startFrame, top.first.endFrame);
  });

  test('帧/时间换算与官方一致（hop 512 @22.05kHz）', () {
    expect(TsumugiConst.framesFor(22050), (22050 / 512).ceil());
    expect(TsumugiConst.frameToSec(100), closeTo(100 * 512 / 22050, 1e-9));
    expect(TsumugiConst.segmentSamples, 220500);
    expect(TsumugiConst.channels, 2, reason: '模型要双声道输入');
  });

  group('分段 Viterbi（官方 viterbi() 的移植）', () {
    /// 造一个分数矩阵：只在给定的 (begin,end,key) 处给正分
    Float32List scoresWith(int frames, int tracks, Map<(int, int, int), double> entries) {
      final s = Float32List(frames * frames * tracks);
      s.fillRange(0, s.length, double.negativeInfinity);
      entries.forEach((key, value) {
        final (begin, end, k) = key;
        s[(begin * frames + end) * tracks + k] = value;
      });
      return s;
    }

    test('挑出分数最高的那个区间', () {
      final frames = 6, tracks = 1;
      // [1,3] 得 5 分最高；另给一些低分区间干扰
      final s = scoresWith(frames, tracks, {
        (1, 3, 0): 5.0,
        (0, 1, 0): 1.0,
        (4, 5, 0): 2.0,
      });
      final noise = Float32List((frames - 1) * tracks); // 全 0：skip 不加分
      final res = viterbiDecodeIntervals(
          scores: s, noiseScore: noise, frames: frames, tracks: tracks);
      final picked = res.single.where((i) => i.startFrame == 1 && i.endFrame == 3);
      expect(picked.length, 1, reason: '应当选中 [1,3]');
    });

    test('对角项 >0 的帧会作为"单帧音"发射出来', () {
      final frames = 4, tracks = 1;
      final s = scoresWith(frames, tracks, {
        (0, 0, 0): 3.0,
        (2, 2, 0): 4.0,
      });
      final noise = Float32List((frames - 1) * tracks);
      final res = viterbiDecodeIntervals(
          scores: s, noiseScore: noise, frames: frames, tracks: tracks);
      final singles = res.single.where((i) => i.startFrame == i.endFrame).toList();
      expect(singles.map((i) => i.startFrame).toSet(), {0, 2});
    });

    test('多轨道（多个音高）各自独立解码', () {
      final frames = 5, tracks = 2;
      final s = scoresWith(frames, tracks, {
        (0, 2, 0): 3.0,
        (2, 4, 1): 3.5,
      });
      final noise = Float32List((frames - 1) * tracks);
      final res = viterbiDecodeIntervals(
          scores: s, noiseScore: noise, frames: frames, tracks: tracks);
      expect(res.length, 2);
      expect(res[0].any((i) => i.key == 0 && i.startFrame == 0 && i.endFrame == 2), isTrue);
      expect(res[1].any((i) => i.key == 1 && i.startFrame == 2 && i.endFrame == 4), isTrue);
    });

    test('全负分时不会硬凑区间（只有正的才算事件）', () {
      final frames = 3, tracks = 1;
      final s = Float32List(frames * frames * tracks);
      s.fillRange(0, s.length, -1.0);
      final noise = Float32List((frames - 1) * tracks);
      final res = viterbiDecodeIntervals(
          scores: s, noiseScore: noise, frames: frames, tracks: tracks);
      expect(res.single, isEmpty);
    });

    test('noiseScore 长度不对时直接报错（对照官方 _validate_shapes）', () {
      final s = Float32List(4 * 4 * 1);
      expect(
        () => viterbiDecodeIntervals(scores: s, noiseScore: Float32List(1), frames: 4, tracks: 1),
        throwsArgumentError,
      );
    });
  });
}
