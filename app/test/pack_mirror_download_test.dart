/// 真实下载验证：用 App 自己的下载器从**镜像站**拉完整模型并核对 SHA256。
///
///   $env:PACK_DOWNLOAD_E2E='1'; flutter test test/pack_mirror_download_test.dart
///
/// 平时跳过（147MB 太大，不该进日常测试）。它验证的正是"手机端下载失败"这条反馈：
///   · 镜像源（hf-mirror.com）能不能真的下完；
///   · 下载器在**换源**时能不能续传；
///   · 落地前的 SHA256 是否与规格一致（镜像给错文件必须被拒）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/model_packs.dart';

void main() {
  test('镜像站能否下完 CRNN 包并通过校验', () async {
    if (Platform.environment['PACK_DOWNLOAD_E2E'] != '1') {
      markTestSkipped('未设置 PACK_DOWNLOAD_E2E=1，跳过（147MB 下载）');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('pack_dl');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = ModelPackStore(root: dir);

    final stages = <String>[];
    var lastFraction = 0.0;
    final sw = Stopwatch()..start();
    final file = await store.download(
      kPianoCrnnPack,
      onStage: (s) {
        stages.add(s);
        // ignore: avoid_print
        print('  · $s');
      },
      onProgress: (p) {
        // 每 10% 打一行，避免刷屏
        if (p.fraction - lastFraction >= 0.1) {
          lastFraction = p.fraction;
          // ignore: avoid_print
          print('    ${(p.fraction * 100).toStringAsFixed(0)}%  '
              '${(p.received / 1048576).toStringAsFixed(1)}MB');
        }
      },
    );
    sw.stop();
    final mb = file.lengthSync() / 1048576;
    // ignore: avoid_print
    print('下载完成：${mb.toStringAsFixed(1)}MB，用时 ${sw.elapsed.inSeconds}s '
        '（${(mb / sw.elapsed.inSeconds).toStringAsFixed(2)}MB/s）');

    expect(file.lengthSync(), kPianoCrnnPack.bytes, reason: '字节数必须与规格一致');
    final sha = await ModelPackStore.sha256OfFile(file);
    expect(sha, kPianoCrnnPack.sha256, reason: 'SHA256 必须一致（镜像给错文件要在这里被拒）');
    expect(await store.stateOf(kPianoCrnnPack), PackState.ready);
    expect(stages, isNotEmpty, reason: '应当把下载阶段汇报给界面');
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('下载源列表齐全（镜像在前、官方在后，且都能本地导入兜底）', () {
    expect(kPianoCrnnPack.sources.length, greaterThanOrEqualTo(2),
        reason: '国内手机连不上 huggingface.co，必须有镜像');
    expect(kPianoCrnnPack.sources.first.url, contains('hf-mirror.com'));
    expect(kPianoCrnnPack.sources.any((s) => s.url.contains('huggingface.co')), isTrue);
    expect(kPianoCrnnPack.downloadable, isTrue);
    expect(kTsumugiPack.downloadable, isFalse, reason: 'Tsumugi 目前只能本地导入');
  });
}
