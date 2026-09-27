/// 调号估计测试：**返回的必须是简谱调号（1=什么）**，而且小调要换算成关系大调。
///
/// 背景：用户报"CRNN 扒钢琴谱音完全不对"，查下来是调号估错 + 返回了主音（旧实现返回 "G#m"）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/melody.dart';

DetectedNote _n(int midi, double dur) =>
    DetectedNote(startSec: 0, endSec: dur, midi: midi.toDouble(), confidence: 0.9);

/// 造一条音阶（每个音重复 [repeat] 次）
///
/// [emphasize] 里的音级会**多出现几倍**：真实音乐里主和弦音总是被强调，
/// 而"每个音一样多"的纯音阶在数学上**分不出关系大小调**（色度完全相同），
/// 拿它做判据是不公平的。
List<DetectedNote> scale(
  List<int> pcs, {
  int octave = 4,
  int repeat = 1,
  double dur = 0.5,
  List<int> emphasize = const [],
  int emphasisFactor = 4,
}) {
  final out = <DetectedNote>[];
  for (var r = 0; r < repeat; r++) {
    for (final pc in pcs) {
      final times = emphasize.contains(pc) ? emphasisFactor : 1;
      for (var k = 0; k < times; k++) {
        out.add(_n(12 * (octave + 1) + pc, dur));
      }
    }
  }
  return out;
}

void main() {
  test('C 大调音阶 → 1=C（大调）', () {
    final (name, mode) = estimateKey(scale([0, 2, 4, 5, 7, 9, 11], repeat: 4));
    expect(name, 'C');
    expect(mode, 'major');
  });

  test('G 大调音阶 → 1=G', () {
    final (name, mode) = estimateKey(scale([7, 9, 11, 0, 2, 4, 6], repeat: 4));
    expect(name, 'G');
    expect(mode, 'major');
  });

  test('A 小调音阶 → 关系大调 1=C（不是 "Am"！）', () {
    final (name, mode) = estimateKey(scale([9, 11, 0, 2, 4, 5, 7], repeat: 4));
    // 关系大小调**共用调号**，所以简谱调号都是 1=C（mode 只用于显示）
    expect(name, 'C', reason: '简谱惯例：小调换算成关系大调，A 小调 → 1=C');
    expect(mode, anyOf('minor', 'major'), reason: 'A 小调与 C 大调共用调号，两者都算对');
  });

  test('C# 小调音阶（《圣诞快乐，劳伦斯先生》的调）→ 1=E 或 6=C#，绝不能是 G#', () {
    // C# D# E F# G# A B
    // C# 小调：主和弦 C#-E-G# 强调
    final (name, mode) = estimateKey(scale([1, 3, 4, 6, 8, 9, 11], repeat: 5, emphasize: [1, 4, 8]));
    // ignore: avoid_print
    print('  C# 小调音阶 → 估计为 $name（$mode）');
    expect(mode, 'minor');
    expect(name, 'E', reason: 'C# 小调的关系大调是 E（4 个升号）');
  });

  test('返回的名字必须是简谱能认的调号（不带 "m" 后缀）', () {
    for (final pcs in [
      [0, 2, 4, 5, 7, 9, 11], // C 大调
      [9, 11, 0, 2, 4, 5, 7], // A 小调
      [2, 4, 5, 7, 9, 10, 0], // D 小调
    ]) {
      final (name, _) = estimateKey(scale(pcs, repeat: 3));
      expect(name.endsWith('m'), isFalse,
          reason: '简谱调号是"1=什么"，不能返回主音（旧实现返回 $name）');
      expect(RegExp(r'^[A-G]#?$').hasMatch(name), isTrue, reason: '拿到的名字是 "$name"');
    }
  });
}
