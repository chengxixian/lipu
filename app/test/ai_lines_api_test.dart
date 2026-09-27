/// 真 API 对照测试：**整页一次** vs **分行并发**，并覆盖"单行旋律谱 / 钢琴双行谱"两种谱式
/// （需要 DEEPSEEK_API_KEY，否则自动跳过）
///
///   $env:DEEPSEEK_API_KEY='sk-...'; flutter test test/ai_lines_api_test.dart
///
/// 要守住的东西：
///   · 切行 + 拼接之后音数不缩水、曲名仍来自页面标题区；
///   · **单行旋律谱**（二十二）不能凭空多出一个低音声部，开头音符顺序正确；
///   · **钢琴双行谱**（春风吹）低音声部不能丢；
///   · 关掉"思考"后单次请求仍是秒级（防回归到 100 秒）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/omr/ai_lines.dart';
import 'package:jianpu_app/omr/ai_notes.dart';
import 'package:jianpu_app/omr/cloud_recognizer.dart';
import 'package:jianpu_app/omr/omr.dart' show ScoreLayoutMode;

const String kDir = 'samples/real';

void main() {
  final key = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final model = Platform.environment['DEEPSEEK_MODEL'] ?? kDefaultCloudModel;

  CloudRecognizer newRecognizer() => OpenAiCompatibleRecognizer(CloudConfig(apiKey: key, model: model));

  test('钢琴双行谱（春风吹 p1）：分行后低音声部不能丢、音数不缩水', () async {
    if (key.isEmpty) {
      markTestSkipped('未设置 DEEPSEEK_API_KEY，跳过联网测试');
      return;
    }
    final file = File('$kDir/春风吹_p1.jpg');
    expect(file.existsSync(), isTrue, reason: '缺少测试图片 ${file.path}');
    final bytes = file.readAsBytesSync();
    final recognizer = newRecognizer();

    // 对照：整页一次
    AiNotesScore? whole;
    var wholeSecs = 0.0;
    for (var attempt = 0; attempt < 2 && whole == null; attempt++) {
      final t0 = DateTime.now();
      final r = await recognizer.recognize(bytes, mimeType: 'image/jpeg');
      wholeSecs = DateTime.now().difference(t0).inMilliseconds / 1000;
      whole = parseAiNotes(r.raw ?? r.jianpuText);
    }
    expect(whole, isNotNull, reason: '整页那一路应当返回结构化 JSON');

    final t1 = DateTime.now();
    final split = await recognizePageByLines(imageBytes: bytes, recognizer: recognizer);
    final splitSecs = DateTime.now().difference(t1).inMilliseconds / 1000;
    expect(split, isNotNull, reason: '这一页应当能切出多段并成功拼接');
    final r = split!;
    final v2 = r.score.notes.where((n) => n.staff == 2).length;
    // ignore: avoid_print
    print('春风吹：整页 ${wholeSecs.toStringAsFixed(1)}s/${whole!.notes.length} 音'
        '（v2=${whole.notes.where((n) => n.staff == 2).length}）；'
        '分行 ${splitSecs.toStringAsFixed(1)}s/${r.score.notes.length} 音（v2=$v2），'
        '谱式=${r.layout == ScoreLayoutMode.grandStaff ? "双行" : "单行"}，'
        '${r.systems} 段 小节=${r.measuresPerSystem.join("/")}');
    for (final d in r.diag) {
      // ignore: avoid_print
      print('  · $d');
    }

    expect(r.layout, ScoreLayoutMode.grandStaff, reason: '这一页是钢琴双行谱');
    expect(v2, greaterThan(20), reason: '低音声部不能丢（实测整页那路 v2=${whole.notes.where((n) => n.staff == 2).length}）');
    expect(r.score.notes.length, greaterThan((whole.notes.length * 0.7).round()));
    expect(r.score.title, contains('春风吹'));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('单行旋律谱（二十二 p1）：不得凭空多出低音声部，开头音符对', () async {
    if (key.isEmpty) {
      markTestSkipped('未设置 DEEPSEEK_API_KEY，跳过联网测试');
      return;
    }
    final bytes = File('$kDir/二十二_p1.jpg').readAsBytesSync();
    final t0 = DateTime.now();
    final r = await recognizePageByLines(imageBytes: bytes, recognizer: newRecognizer());
    final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
    expect(r, isNotNull, reason: '这一页应当能切出多段并成功拼接');
    final v1 = r!.score.notes.where((n) => n.staff == 1).length;
    final v2 = r.score.notes.where((n) => n.staff == 2).length;
    // ignore: avoid_print
    print('二十二 p1：${secs.toStringAsFixed(1)}s，${r.systems} 段，'
        '${r.score.notes.length} 音（v1=$v1 v2=$v2），'
        '谱式=${r.layout == ScoreLayoutMode.singleLine ? "单行" : "双行"}，'
        '小节=${r.measuresPerSystem.join("/")}，曲名=${r.score.title} 调=${r.score.keyName}');
    for (final d in r.diag) {
      // ignore: avoid_print
      print('  · $d');
    }

    expect(r.layout, ScoreLayoutMode.singleLine, reason: '二十二 是单行旋律谱');
    expect(v2 * 5, lessThan(v1), reason: '单行谱不该有大量"低音声部"（实测 v1=$v1 v2=$v2）');
    expect(v1, greaterThan(150), reason: '整页音符数不该缩水');
    expect(r.score.title, contains('二十二'));
    // 每行最后一个音：开头 5·5 523 21 65 → 前两个音是 5、5
    final head = (r.score.notes.where((n) => n.staff == 1).toList()..sort((a, b) => a.start.compareTo(b.start)))
        .take(2)
        .map((n) => n.degree)
        .toList();
    expect(head, [5, 5], reason: '开头两个音应当是 5 5');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('单行旋律谱（二十二 p2）同样不乱造声部', () async {
    if (key.isEmpty) {
      markTestSkipped('未设置 DEEPSEEK_API_KEY，跳过联网测试');
      return;
    }
    final bytes = File('$kDir/二十二_p2.jpg').readAsBytesSync();
    final r = await recognizePageByLines(imageBytes: bytes, recognizer: newRecognizer());
    expect(r, isNotNull);
    final v1 = r!.score.notes.where((n) => n.staff == 1).length;
    final v2 = r.score.notes.where((n) => n.staff == 2).length;
    // ignore: avoid_print
    print('二十二 p2：${r.systems} 段，${r.score.notes.length} 音（v1=$v1 v2=$v2），'
        '谱式=${r.layout == ScoreLayoutMode.singleLine ? "单行" : "双行"}');
    for (final d in r.diag) {
      // ignore: avoid_print
      print('  · $d');
    }
    expect(r.layout, ScoreLayoutMode.singleLine);
    expect(v1, greaterThan(120));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('关掉思考后单次请求仍然是秒级（回归：别又退回 100 秒）', () async {
    if (key.isEmpty) {
      markTestSkipped('未设置 DEEPSEEK_API_KEY，跳过联网测试');
      return;
    }
    final bytes = File('$kDir/春风吹_p1.jpg').readAsBytesSync();
    final recognizer = newRecognizer();
    final t0 = DateTime.now();
    final result = await recognizer.recognize(bytes, mimeType: 'image/jpeg');
    final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
    final ai = parseAiNotes(result.raw ?? result.jianpuText);
    // ignore: avoid_print
    print('快速模式整页：${secs.toStringAsFixed(1)}s，${ai?.notes.length ?? -1} 个音');
    expect(ai, isNotNull);
    // 开着"思考"时实测 110~127 秒；这里给一个宽松但足够区分的上限
    expect(secs, lessThan(60), reason: '快速模式不应当再花一分钟以上（实测约 6~7 秒）');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
