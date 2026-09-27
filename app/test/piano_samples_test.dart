/// 内置钢琴采样（真实录音）的完整性测试
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/audio/piano_samples.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PianoSampleSet set;

  setUpAll(() async {
    set = await PianoSampleSet.load();
  });

  test('30 个采样齐全：A0 起每小三度到 C8，44.1kHz', () {
    expect(set.sampleRate, 44100);
    expect(set.samples.length, 30);
    expect(set.samples.first.midi, 21); // A0
    expect(set.samples.last.midi, 108); // C8
    for (var i = 1; i < set.samples.length; i++) {
      expect(set.samples[i].midi - set.samples[i - 1].midi, 3, reason: '采样间隔应为小三度');
    }
    expect(set.license, contains('CC-BY'), reason: '必须保留 CC-BY 授权信息');
    expect(set.attribution, contains('Salamander'));
  });

  test('每个采样的长度/循环点/峰值都合理，且不是静音', () {
    for (final s in set.samples) {
      expect(s.frames, greaterThan(44100), reason: '${s.file} 至少要 1 秒');
      expect(s.loopStart, greaterThan(0), reason: '${s.file} 循环起点应为正');
      expect(s.loopEnd, s.frames, reason: '${s.file} 循环终点应是文件结尾');
      expect(s.loopLength, greaterThan(4410), reason: '${s.file} 循环段至少要 0.1 秒');
      expect(s.peak, greaterThan(0.1), reason: '${s.file} 峰值过低');
      expect(s.peak, lessThanOrEqualTo(1.0), reason: '${s.file} 峰值溢出');

      // 开头 0.1 秒必须有实际波形（防止转出静音文件）
      var sum = 0.0;
      for (var i = 0; i < 4410; i++) {
        sum += s.pcm[i].abs();
      }
      expect(sum / 4410, greaterThan(200), reason: '${s.file} 开头几乎是静音');
    }
  });

  test('取最近采样：最多移调 1.5 个半音', () {
    PianoSample pick(int m) => set.nearest(m);
    expect(pick(21).midi, 21);
    expect(pick(22).midi, 21);
    expect(pick(23).midi, 24);
    expect(pick(24).midi, 24);
    expect(pick(60).midi, 60);
    expect(pick(61).midi, 60);
    expect(pick(62).midi, 63);
    expect(pick(108).midi, 108);
    expect(pick(10).midi, 21, reason: '超出范围时取最近的端点');
    expect(pick(120).midi, 108);
    for (var m = 21; m <= 108; m++) {
      expect((pick(m).midi - m).abs(), lessThanOrEqualTo(2), reason: 'midi=$m');
    }
  });

  test('实测基频与等程律相差不超过 40 音分（钢琴本身的伸张调律）', () {
    for (final s in set.samples) {
      final expected = 440 * math.pow(2, (s.midi - 69) / 12.0);
      final cents = 1200 * (math.log(s.freq / expected) / math.ln2);
      expect(cents.abs(), lessThan(40), reason: '${s.file} 偏差 ${cents.toStringAsFixed(1)} 音分');
    }
  });
}
