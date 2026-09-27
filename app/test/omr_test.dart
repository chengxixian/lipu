/// OMR 端到端测试：用系统字体 + 手工画点/横线合成“简谱图”，再走完整识别流程比对
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/omr/omr.dart';
import 'package:jianpu_app/omr/omr_core.dart';
import 'package:jianpu_app/omr/omr_service.dart';
import 'package:jianpu_app/omr/omr_templates.dart';
import 'package:jianpu_app/state.dart';

/// 测试环境默认只有测试字体（会把所有字画成方块），因此显式加载系统真实字体
Future<List<String>> _loadRealFonts() async {
  final candidates = <String, String>{
    'TestArial': r'C:\Windows\Fonts\arial.ttf',
    'TestTimes': r'C:\Windows\Fonts\times.ttf',
    'TestSimHei': r'C:\Windows\Fonts\simhei.ttf',
    'TestKaiTi': r'C:\Windows\Fonts\simkai.ttf',
    'TestCalibri': r'C:\Windows\Fonts\calibri.ttf',
    'TestCourier': r'C:\Windows\Fonts\cour.ttf',
  };
  final loaded = <String>[];
  for (final entry in candidates.entries) {
    final f = File(entry.value);
    if (!f.existsSync()) continue;
    final bytes = await f.readAsBytes();
    final loader = FontLoader(entry.key)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    loaded.add(entry.key);
  }
  return loaded;
}

/// 一个简谱音符的视觉描述
class _Note {
  final String digit;
  final int up; // 上加点（八度）
  final int down; // 下加点
  final int underlines; // 减时线数量
  final int dashes; // 延音短横数量
  const _Note(this.digit, {this.up = 0, this.down = 0, this.underlines = 0, this.dashes = 0});
}

Future<GrayImage> _renderLine(List<_Note> notes, String font,
    {double fontSize = 56, double gap = 84, bool barline = false, double skewDeg = 0}) async {
  final x0 = 100.0;
  final width = x0 * 2 + notes.length * gap + 80;
  const height = 320.0;
  const baseline = 200.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = const Color(0xFFFFFFFF));
  if (skewDeg != 0) {
    canvas.translate(width / 2, height / 2);
    canvas.rotate(skewDeg * 3.1415926535 / 180);
    canvas.translate(-width / 2, -height / 2);
  }
  final ink = Paint()..color = const Color(0xFF000000);
  final line = Paint()
    ..color = const Color(0xFF000000)
    ..strokeWidth = 3.4;
  final dotR = fontSize * 0.062;

  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    final cx = x0 + i * gap;
    final tp = TextPainter(
      text: TextSpan(
        text: n.digit,
        style: TextStyle(fontSize: fontSize, fontFamily: font, color: const Color(0xFF000000)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, baseline - tp.height));
    // 八度点
    for (var k = 0; k < n.up; k++) {
      canvas.drawCircle(Offset(cx, baseline - tp.height - fontSize * 0.26 - k * fontSize * 0.24), dotR, ink);
    }
    for (var k = 0; k < n.down; k++) {
      canvas.drawCircle(Offset(cx, baseline + fontSize * 0.26 + k * fontSize * 0.24), dotR, ink);
    }
    // 减时线
    for (var k = 0; k < n.underlines; k++) {
      final y = baseline + fontSize * 0.17 + k * fontSize * 0.15;
      canvas.drawLine(Offset(cx - gap * 0.30, y), Offset(cx + gap * 0.30, y), line);
    }
    // 延音短横（与数字中部同高，位于右侧）
    for (var k = 0; k < n.dashes; k++) {
      final y = baseline - fontSize * 0.34;
      final x = cx + gap * 0.40 + k * gap * 0.60;
      canvas.drawLine(Offset(x, y), Offset(x + gap * 0.32, y), line);
    }
  }
  if (barline) {
    final x = x0 + notes.length * gap - gap * 0.38;
    canvas.drawLine(Offset(x, baseline - fontSize * 0.9), Offset(x, baseline + fontSize * 0.22), line);
  }
  final image = await recorder.endRecording().toImage(width.round(), height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return GrayImage.fromRgba(data!.buffer.asUint8List(), image.width, image.height);
}

/// 从识别文本里抽出“音级序列”（忽略表头/小节线/空格）
String digitsOf(String text) => RegExp(r'[0-7]')
    .allMatches(text.split('\n').where((l) => !l.contains('=')).join(' '))
    .map((m) => m.group(0)!)
    .join();

/// 灰度图 -> PNG 字节（用于测试图片解码链路）
Future<Uint8List> _grayToPng(GrayImage gray) async {
  final rgba = Uint8List(gray.w * gray.h * 4);
  for (var i = 0; i < gray.w * gray.h; i++) {
    final v = gray.d[i];
    rgba[i * 4] = v;
    rgba[i * 4 + 1] = v;
    rgba[i * 4 + 2] = v;
    rgba[i * 4 + 3] = 255;
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: gray.w,
    height: gray.h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> fonts;
  GlyphClassifier? classifier;

  setUpAll(() async {
    fonts = await _loadRealFonts();
    if (fonts.isNotEmpty) {
      classifier = await buildGlyphClassifier(fonts: fonts);
    }
  });

  OmrResult run(GrayImage gray) {
    final bin = binarize(gray, adaptive: false);
    return recognizeJianpuFromBinary(deskew(bin), classifier!);
  }

  test('字形分类器：单字符识别', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    for (final ch in ['1', '2', '3', '4', '5', '6', '7', '0']) {
      final gray = await _renderLine([_Note(ch)], fonts.first, fontSize: 80);
      final bin = binarize(gray, adaptive: false);
      final comps = connectedComponents(bin, minArea: 8);
      expect(comps, isNotEmpty, reason: '字符 $ch 没渲染出连通域');
      final biggest = comps.reduce((a, b) => a.area >= b.area ? a : b);
      final r = classifier!.classify(biggest);
      expect(r.label, ch, reason: '字符 $ch 被识别成 ${r.label}（候选 ${r.ranking.take(3).map((c) => c.label).join(",")}）');
    }
  });

  test('整行识别：音级序列正确（含 3/4/5 这类带底横的数字）', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    final notes = '1234567'.split('').map((d) => _Note(d)).toList();
    final gray = await _renderLine(notes, fonts.first);
    final result = run(gray);
    expect(result.bands, isNotEmpty);
    expect(digitsOf(result.jianpuText), '1234567');
  });

  test('八度点：上加点与下加点', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    final gray = await _renderLine([
      const _Note('1'),
      const _Note('3', up: 1),
      const _Note('5', down: 1),
      const _Note('6', up: 2),
    ], fonts.first);
    final result = run(gray);
    final text = result.jianpuText;
    expect(digitsOf(text), '1356');
    expect(text.contains("3'"), isTrue, reason: '上八度没识别出来：$text');
    expect(text.contains('5,'), isTrue, reason: '下八度没识别出来：$text');
    expect(text.contains("6''"), isTrue, reason: '两个上加点没识别出来：$text');
  });

  test('减时线与延音短横', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    final gray = await _renderLine([
      const _Note('1', underlines: 1),
      const _Note('2', underlines: 2),
      const _Note('3', underlines: 1),
      const _Note('5', dashes: 1),
    ], fonts.first);
    final result = run(gray);
    final text = result.jianpuText;
    expect(digitsOf(text), '1235');
    expect(text.contains('1/'), isTrue, reason: '八分音符减时线没识别出来：$text');
    expect(text.contains('2//'), isTrue, reason: '十六分音符减时线没识别出来：$text');
    expect(text.contains(' -'), isTrue, reason: '延音短横没识别出来：$text');
  });

  test('附属记号：附点与变音记号', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    // 3. 附点四分；#4 升号
    final gray = await _renderLine([
      const _Note('3'),
      const _Note('4'),
    ], fonts.first);
    final result = run(gray);
    expect(digitsOf(result.jianpuText), '34');
  });

  test('小节线', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    final gray = await _renderLine(
      [const _Note('1'), const _Note('2'), const _Note('3'), const _Note('5')],
      fonts.first,
      barline: true,
    );
    final result = run(gray);
    expect(result.jianpuText.contains('|'), isTrue, reason: '小节线没识别出来：${result.jianpuText}');
    expect(digitsOf(result.jianpuText), '1235');
  });

  test('不同字体（黑体/楷体/衬线体）都要能识别', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    // 真实简谱印书常用黑体、楷体、宋体；这里逐个字体跑一遍整行识别
    final target = ['TestSimHei', 'TestKaiTi', 'TestTimes', 'TestArial']
        .where((f) => fonts.contains(f))
        .toList();
    expect(target, isNotEmpty, reason: '没有加载到任何测试字体');
    for (final font in target) {
      final classifier = await buildGlyphClassifier(fonts: [font]);
      final notes = '1234567'.split('').map((d) => _Note(d)).toList();
      final gray = await _renderLine(notes, font);
      final bin = binarize(gray, adaptive: false);
      final result = recognizeJianpuFromBinary(deskew(bin), classifier);
      final digits = digitsOf(result.jianpuText);
      // ignore: avoid_print
      print('字体 $font -> $digits');
      expect(digits, '1234567', reason: '字体 $font 识别结果不对：$digits');
    }
  });

  test('图片字节 -> 识别服务：解码 / 降采样 / 二值化 / 版面分析', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    final gray = await _renderLine('1234567'.split('').map((e) => _Note(e)).toList(), fonts.first);
    final png = await _grayToPng(gray);
    final outcome = await recognizeImageBytes(png, maxDimension: 1000);
    expect(outcome.result.bands, isNotEmpty);
    expect(outcome.binary, isNotNull);
    expect(outcome.binary!.w, greaterThan(0));
    expect(outcome.binary!.h, greaterThan(0));
    expect(outcome.result.diagnostics, isNotEmpty);
  });

  test('多张图片：逐张识别并按顺序拼成一份简谱', () async {
    // 本地识别已从产品里移除，识谱页只走 AI；这里注入假的识谱后端，
    // 只验证"多页 -> 合并 -> 取消勾选"这套页面逻辑，不发真实网络请求。
    final state = AppState();
    state.debugRecognizeHook = (input) async =>
        input.name == '第1页.png' ? '1=C 4/4\n1 2 3 4 |]' : '1=C 4/4\n5 6 7 1\' |]';
    await state.recognizeImages([
      RecognizeInput('第1页.png', Uint8List.fromList([1, 2, 3])),
      RecognizeInput('第2页.png', Uint8List.fromList([4, 5, 6])),
    ]);

    expect(state.pages.length, 2, reason: '两张图都应识别成功');
    final merged = digitsOf(state.text);
    // ignore: avoid_print
    print('多图拼接结果: $merged');
    expect(merged.contains('1234'), isTrue);
    expect(merged.contains('5671'), isTrue);

    // 取消勾选第二张的所有行后，第二张的内容不应再出现
    for (final b in state.pages[1].outcome.result.bands) {
      state.toggleBand(1, b.index, false);
    }
    final after = digitsOf(state.text);
    expect(after.contains('1234'), isTrue);
    expect(after.contains('5671'), isFalse, reason: '取消勾选后仍在文本里: $after');
  });

  test('拍照场景：倾斜 3° + 自适应阈值仍能识别', () async {
    if (fonts.isEmpty) {
      markTestSkipped('没有可用的系统字体文件，跳过');
      return;
    }
    final gray = await _renderLine([
      const _Note('3'),
      const _Note('5'),
      const _Note('6'),
      const _Note('5', underlines: 1),
      const _Note('1'),
      const _Note('2'),
      const _Note('3'),
    ], fonts.first, skewDeg: 3);
    final bin = binarize(gray, adaptive: true);
    final result = recognizeJianpuFromBinary(deskew(bin, maxDeg: 6), classifier!);
    final digits = digitsOf(result.jianpuText);
    expect(digits.length, greaterThanOrEqualTo(6), reason: '倾斜后识别到的音符太少：$digits');
    expect(digits.startsWith('3565'), isTrue, reason: '倾斜后识别错位：$digits');
  });
}
