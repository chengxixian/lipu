/// 端到端测试：在真实桌面端验证 **Verovio 渲染链路**可用。
///
/// 覆盖：资源解压 → WebView 加载 harness → WASM 初始化 → MusicXML → SVG → A4 分页 → PNG 导出。
/// 单元测试跑不了 WebView（flutter test 没有平台视图），所以这部分只能在真桌面跑：
///   flutter test integration_test/verovio_e2e_test.dart -d windows
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/omr/ai_notes.dart';
import 'package:jianpu_app/render/verovio_view.dart';

/// 等到 [test] 为真或超时；返回是否等到了
Future<bool> waitFor(WidgetTester tester, bool Function() test, {Duration timeout = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return test();
}

const String _kSimple = '''标题：小星星
1=C 4/4 ♩=96
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |
5 5 4 4 | 3 3 2 - | 5 5 4 4 | 3 3 2 - |
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]''';

const String _kGrand = '''标题：和弦与大谱表
1=C 4/4 ♩=96
高音: [1 3 5] [4 6 1'] [5 7 2'] [1 3 5] |
高音: [4 6 1'] [2 4 6] [5 7 2'] [1 3 5] |
低音: 1,, - - - | 4,, - - - |
低音: 5,, - - - | 1,, - - - |]''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Verovio 能在真机上排版我们的 MusicXML 并导出 PNG', (tester) async {
    final controller = VerovioController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: VerovioScoreView(controller: controller)),
    ));

    final ready = await waitFor(tester, () => controller.ready);
    if (!ready) {
      // ignore: avoid_print
      print('--- Verovio 诊断 ---');
      for (final d in controller.diagnostics) {
        // ignore: avoid_print
        print('  $d');
      }
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}lipu_verovio');
      // ignore: avoid_print
      print('  目录存在: ${dir.existsSync()}  路径: ${dir.path}');
      if (dir.existsSync()) {
        for (final f in dir.listSync()) {
          // ignore: avoid_print
          print('    ${f.path.split(Platform.pathSeparator).last}  ${f.statSync().size} 字节');
        }
      }
    }
    expect(ready, isTrue, reason: 'Verovio 未能就绪：${controller.status.error}');
    // ignore: avoid_print
    print('Verovio 就绪');

    final outDir = Directory('build/snapshots');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    // ---- 1) 单谱表：小星星 ----
    await controller.render(toMusicXML(parseJianpu(_kSimple), padIncompleteMeasures: true));
    final done = await waitFor(tester, () => !controller.status.rendering);
    expect(done, isTrue, reason: '渲染超时');
    expect(controller.status.error, isNull, reason: '渲染报错：${controller.status.error}');
    expect(controller.pages, greaterThanOrEqualTo(1));
    // ignore: avoid_print
    print('小星星：${controller.pages} 页');

    final png = await controller.exportPng(1, factor: 2.0);
    expect(png, isNotNull, reason: 'PNG 导出失败');
    expect(png!.length, greaterThan(3000));
    File('${outDir.path}/verovio_simple_p1.png').writeAsBytesSync(png);
    // ignore: avoid_print
    print('导出 verovio_simple_p1.png  ${png.length} 字节');

    // ---- 1b) 版面必须是 A4 比例（这里守的是"手机上一页被拉宽压扁"那个 bug）----
    await controller.requestMetrics();
    await waitFor(tester, () => controller.metrics.isNotEmpty, timeout: const Duration(seconds: 15));
    final m = controller.metrics;
    // ignore: avoid_print
    print('版面实测：viewport=${m['viewportW']} 纸张=${m['paperW']}x${m['paperH']} '
        'svg=${m['svgW']}x${m['svgH']} viewBox=${m['viewBox']}');
    final paperW = (m['paperW'] as num).toDouble();
    final paperH = (m['paperH'] as num).toDouble();
    final svgW = (m['svgW'] as num).toDouble();
    final svgH = (m['svgH'] as num).toDouble();
    expect(m['viewBox'], isNotNull, reason: 'SVG 必须有 viewBox，否则宽度自适应会丢掉宽高比');
    expect(paperW, lessThanOrEqualTo((m['viewportW'] as num).toDouble()),
        reason: '纸张不能超出视口宽度');
    // A4 = 210:297 ≈ 0.7071；裁掉页脚空白前，SVG 与纸张的高宽比应当一致
    expect(svgH / svgW, closeTo(1123 / 794, 0.02), reason: 'SVG 不是 A4 比例（被压扁/拉宽了）');
    expect(paperH / paperW, greaterThan(1123 / 794 - 0.25),
        reason: '纸张高度没有跟着 SVG 走（宽度自适应把高度塌掉了）');

    // ---- 2) 大谱表 + 和弦 ----
    await controller.render(toMusicXML(parseJianpu(_kGrand), padIncompleteMeasures: true));
    await waitFor(tester, () => !controller.status.rendering);
    expect(controller.status.error, isNull, reason: '大谱表渲染报错：${controller.status.error}');
    final grandPng = await controller.exportPng(1, factor: 2.0);
    expect(grandPng, isNotNull);
    File('${outDir.path}/verovio_grand_p1.png').writeAsBytesSync(grandPng!);
    // ignore: avoid_print
    print('大谱表导出 verovio_grand_p1.png  ${grandPng.length} 字节');

    // ---- 3) 长谱：必须分成多页，翻页要生效 ----
    final longText = StringBuffer('标题：长谱分页\n1=C 4/4 ♩=96\n');
    for (var i = 0; i < 24; i++) {
      longText.writeln("1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |");
    }
    await controller.render(toMusicXML(parseJianpu(longText.toString()), padIncompleteMeasures: true));
    await waitFor(tester, () => !controller.status.rendering);
    expect(controller.status.error, isNull, reason: '长谱渲染报错：${controller.status.error}');
    // ignore: avoid_print
    print('长谱：${controller.pages} 页');
    expect(controller.pages, greaterThan(1), reason: '96 小节应该分成多页');

    await controller.gotoPage(2);
    await waitFor(tester, () => controller.page == 2, timeout: const Duration(seconds: 20));
    expect(controller.page, 2, reason: '翻页没有生效');
    final page2 = await controller.exportPng(2, factor: 2.0);
    expect(page2, isNotNull);
    File('${outDir.path}/verovio_long_p2.png').writeAsBytesSync(page2!);
    // ignore: avoid_print
    print('第 2 页导出 verovio_long_p2.png  ${page2.length} 字节');

    // ---- 4) 休止符（停顿）必须真的画在谱面上 ----
    // 用真 API 识别春风吹留下的固定样例（test/fixtures/chunfengchui_p1.json），
    // 这份结果里第 1 小节是「0 0 0 712」——前 3 拍是停顿。
    final fixture = File('test/fixtures/chunfengchui_p1.json');
    expect(fixture.existsSync(), isTrue, reason: '缺少 AI 识谱样例：${fixture.path}');
    final ai = parseAiNotes(fixture.readAsStringSync());
    expect(ai, isNotNull, reason: '样例应当是结构化 JSON');
    final aiScore = scoreFromAiNotes(ai!);
    final aiXml = toMusicXML(aiScore, padIncompleteMeasures: true);
    final restTags = RegExp(r'<rest/>').allMatches(aiXml).length;
    // ignore: avoid_print
    print('春风吹样例：${aiScore.measures.length} 小节 / ${aiScore.pitchCount} 个音，'
        'MusicXML 休止符 $restTags 个');
    expect(restTags, greaterThan(5), reason: '原谱里停顿很多，MusicXML 必须有休止符');
    expect(aiScore.measures.first.items.first, isA<RestItem>(),
        reason: '第一小节开头就是 3 拍停顿');

    await controller.render(aiXml);
    await waitFor(tester, () => !controller.status.rendering, timeout: const Duration(seconds: 60));
    expect(controller.status.error, isNull, reason: '渲染报错：${controller.status.error}');
    final rendered = await controller.web!.evaluateJavascript(source: 'window.vrvProbe()');
    final probe = jsonDecode(rendered.toString()) as Map<String, dynamic>;
    // ignore: avoid_print
    print('渲染后：休止符层 ${probe['rests']} 个 / 符头 ${probe['noteheads']} 个');
    expect((probe['rests'] as num).toInt(), greaterThan(0),
        reason: 'Verovio 画面上必须能看到休止符（没有就是"停顿丢了"）');
    final aiPng = await controller.exportPng(1, factor: 2.0);
    expect(aiPng, isNotNull);
    File('${outDir.path}/chunfengchui_ai_p1.png').writeAsBytesSync(aiPng!);
    // ignore: avoid_print
    print('导出 ${outDir.path}/chunfengchui_ai_p1.png  ${aiPng.length} 字节');
  });
}
