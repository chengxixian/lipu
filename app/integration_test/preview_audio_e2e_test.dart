/// 端到端测试：在真桌面端验证「真实钢琴采样试听」这条链路。
///
/// 覆盖：资源解包 → 采样加载 → 后台 isolate 渲染（含百分比进度回报）
///        → WAV 落盘 → audioplayers 播放；以及长曲子的渲染速度。
/// 单元测试跑不到真机上的插件与 AOT 路径，所以这部分只能在真桌面跑：
///   flutter test integration_test/preview_audio_e2e_test.dart -d windows
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/audio/piano_samples.dart';
import 'package:jianpu_app/audio/player.dart';
import 'package:jianpu_app/audio/sampler.dart';
import 'package:jianpu_app/core/app_paths.dart';
import 'package:jianpu_app/core/parse.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('内置钢琴采样能加载（30 个，44.1kHz）', (tester) async {
    final set = await PianoSampleSet.load();
    expect(set.samples.length, 30);
    expect(set.sampleRate, 44100);
    expect(set.license, contains('CC-BY'));
    // 抽查一个采样真的有波形
    final s = set.nearest(60);
    var sum = 0;
    for (var i = 0; i < 4410; i++) {
      sum += s.pcm[i].abs();
    }
    expect(sum, greaterThan(100000));
  });

  testWidgets('后台 isolate 渲染 + 进度回报 + 文件落盘 + 能播放', (tester) async {
    final player = ScorePlayer();
    final score = parseJianpu("1=C 4/4 ♩=96\n1 2 3 4 | 5 6 7 1' | 6 5 3 1 | 2 - - - |]");
    final stages = <String>[];
    final sw = Stopwatch()..start();
    await player.play(score, onStage: stages.add);
    sw.stop();

    expect(player.usingSamples, isTrue, reason: '应当用上真实钢琴采样而不是合成器兜底');
    expect(stages.any((s) => s.contains('%')), isTrue, reason: '合成过程应当回报百分比进度');

    final file = File(AppPaths.join(AppPaths.tempDir(), 'jianpu_preview.wav'));
    expect(file.existsSync(), isTrue, reason: '试听 WAV 应当已经写出来');
    final bytes = file.lengthSync();
    // 4 小节 @96bpm = 10 秒，加 1.4 秒尾音；44.1kHz 立体声 16bit = 176400 B/s
    expect(bytes / 176400, greaterThan(10), reason: '文件长度应当覆盖整首曲子');
    expect(bytes / 176400, lessThan(14));
    final head = file.readAsBytesSync().sublist(0, 4);
    expect(String.fromCharCodes(head), 'RIFF');

    print('演示曲：渲染+播放 ${sw.elapsedMilliseconds}ms，'
        '文件 ${(bytes / 1024 / 1024).toStringAsFixed(2)}MB，进度阶段数 ${stages.length}');
    print('阶段样本：${stages.take(3).toList()} … ${stages.isEmpty ? '' : stages.last}');

    await player.stop();
    await player.dispose();
  });

  testWidgets('5 分钟上限的长曲渲染速度', (tester) async {
    final set = await PianoSampleSet.load();
    final text = '1=C 4/4 ♩=120\n${"1 2 3 4 | 5 6 7 1' |" * 150}]';
    final score = parseJianpu(text);
    final dir = Directory.systemTemp.createTempSync('lipu_e2e');
    final path = '${dir.path}/long.wav';
    final progress = <double>[];
    final sw = Stopwatch()..start();
    final result = renderPianoWav(
      score: score,
      samples: set,
      path: path,
      maxSeconds: 300,
      onProgress: progress.add,
    );
    sw.stop();
    final seconds = result.frames / result.sampleRate;
    expect(seconds, closeTo(300, 1), reason: '应当被截到 5 分钟上限');
    expect(result.peak, greaterThan(0.2));
    expect(result.peak, lessThanOrEqualTo(1.0));
    expect(progress.last, closeTo(1.0, 1e-9));
    final size = File(path).lengthSync();
    print('300 秒长曲渲染 ${sw.elapsedMilliseconds}ms（${(seconds / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(1)}× 实时），'
        '文件 ${(size / 1024 / 1024).toStringAsFixed(1)}MB');
    dir.deleteSync(recursive: true);
  });
}
