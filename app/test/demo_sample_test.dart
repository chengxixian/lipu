/// 内置示例音频：必须是**能用的** WAV，而且包里不再有小星星/茉莉花。
///
/// 用户要求把示例换成他给的曲子（Merry Christmas Mr. Lawrence）并去掉小星星/茉莉花；
/// 那两首只作为测试音源留在 `test/fixtures/`（不进包）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';

const String kDemo = 'assets/samples/merry_christmas.wav';

void main() {
  test('内置示例音频存在、格式正确、长度合理', () {
    final f = File(kDemo);
    expect(f.existsSync(), isTrue, reason: '缺少内置示例音频 $kDemo');
    final clip = prepareWavBytes(f.readAsBytesSync(), 'demo');
    // 扒谱内部按 22050Hz 处理，示例就按这个采样率转好，省一次重采样
    expect(clip.sampleRate, 22050);
    expect(clip.samples.length, greaterThan(22050 * 30), reason: '示例太短了');
    expect(clip.durationSec, greaterThan(30));
    // ignore: avoid_print
    print('内置示例：${clip.durationSec.toStringAsFixed(1)} 秒 / '
        '${clip.sampleRate}Hz / ${f.lengthSync() ~/ 1024}KB');
  });

  test('包里不再有小星星/茉莉花（只留测试音源）', () {
    final names = Directory('assets/samples')
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .where((n) => !n.startsWith('.'))
        .toList();
    // ignore: avoid_print
    print('打包进 App 的示例音频：$names');
    expect(names, contains('merry_christmas.wav'));
    for (final gone in ['xiaoxingxing.wav', 'molihua.wav', 'polyphonic.wav']) {
      expect(names, isNot(contains(gone)), reason: '$gone 不应该再打进包里');
      // 但作为测试音源要还在（Basic Pitch 精度对照就靠它们）
      expect(File('test/fixtures/$gone').existsSync(), isTrue,
          reason: '测试音源 test/fixtures/$gone 不能删');
    }
  });
}
