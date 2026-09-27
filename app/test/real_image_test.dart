/// 真实简谱图片的识别诊断：把中间过程画成 PNG，便于定位问题
///
///   file: samples/real/春风吹_p1.jpg
/// 输出到 build/snapshots/real_*.png，并打印每行的识别文本与置信度。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/omr/omr_service.dart';
import 'package:jianpu_app/omr/omr_templates.dart';

/// 可用环境变量 REAL_IMG 指定要诊断的图片
String get kImage => Platform.environment['REAL_IMG'] ?? 'samples/real/春风吹_p1.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // flutter test 环境没有系统字体，模板必须用显式加载的真实字体来建，
    // 否则所有模板都会渲染成同一个占位方块，识别结果毫无参考价值。
    final fontFiles = <String, String>{
      'RealSerif': r'C:\Windows\Fonts\times.ttf',
      'RealSans': r'C:\Windows\Fonts\arial.ttf',
      'RealHei': r'C:\Windows\Fonts\simhei.ttf', // 黑体：最接近简谱印刷体的粗笔画
      'RealKai': r'C:\Windows\Fonts\simkai.ttf',
      'RealCourier': r'C:\Windows\Fonts\cour.ttf',
      'RealCalibri': r'C:\Windows\Fonts\calibri.ttf',
    };
    final loaded = <String>[];
    for (final e in fontFiles.entries) {
      final f = File(e.value);
      if (!f.existsSync()) continue;
      final loader = FontLoader(e.key)..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      loaded.add(e.key);
    }
    // ignore: avoid_print
    print('加载到的测试字体: $loaded');
    debugClassifierOverride = await buildGlyphClassifier(fonts: loaded);
    // ignore: avoid_print
    print('模板数量: ${debugClassifierOverride!.templates.length}');
  });

  tearDownAll(() => debugClassifierOverride = null);

  test('真实简谱：识别诊断', () async {
    final file = File(kImage);
    expect(file.existsSync(), isTrue, reason: '缺少测试图片 $kImage');
    final outDir = Directory('build/snapshots');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    final bytes = file.readAsBytesSync();
    Map<String, dynamic>? last;
    final outcome = await recognizeImageBytes(
      bytes,
      onProgress: (f, stage) {
        last = {'f': f, 'stage': stage};
      },
    );
    // ignore: avoid_print
    print('进度回调最后一次: $last');

    final result = outcome.result;
    // ignore: avoid_print
    print('=== 版面：检测到 ${result.bands.length} 行（图 ${result.imageWidth}x${result.imageHeight}）===');
    for (final b in result.bands) {
      // ignore: avoid_print
      print('[行${b.index}] y=${b.y0}..${b.y1} 选中=${b.selected} 评分=${b.score.toStringAsFixed(2)} '
          '置信=${(b.meanConfidence * 100).toStringAsFixed(0)}% 记号数=${b.tokens.length}');
      // ignore: avoid_print
      print('        文本: ${b.text}');
      // ignore: avoid_print
      print('        依据: ${b.reason}');
    }
    // ignore: avoid_print
    print('=== 诊断信息 ===');
    for (final d in result.diagnostics) {
      // ignore: avoid_print
      print('  $d');
    }

    // 1) 二值化图（直接复用服务层的导出）
    final pageBinary = outcome.binary!;
    final binPng = await binToPng(pageBinary);
    File('${outDir.path}/real_01_binary.png').writeAsBytesSync(binPng);
    // ignore: avoid_print
    print('已保存 ${outDir.path}/real_01_binary.png');

    // 2) 原图 + 行框 + 字形框
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final scaleX = src.width / pageBinary.w;
    final scaleY = src.height / pageBinary.h;
    // ignore: avoid_print
    print('尺寸: 原图 ${src.width}x${src.height} -> 分析图 ${pageBinary.w}x${pageBinary.h} '
        '(缩放 ${scaleX.toStringAsFixed(2)}x)');

    await _savePng(
      src.width,
      src.height,
      (canvas) {
        canvas.drawImage(src, Offset.zero, Paint());
        for (final b in result.bands) {
          final paint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = b.selected ? const Color(0xFF2E7D32) : const Color(0x55FF0000);
          canvas.drawRect(
            Rect.fromLTRB(0, b.y0 * scaleY, src.width.toDouble(), b.y1 * scaleY),
            paint,
          );
          for (final t in b.tokens) {
            if (t.kind != 'note' && t.kind != 'rest') continue;
            final boxPaint = Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = t.confidence >= 0.72 ? const Color(0xFF1565C0) : const Color(0xFFD32F2F);
            canvas.drawRect(
              Rect.fromLTRB(t.x * scaleX, t.y * scaleY, (t.x + t.w) * scaleX, (t.y + t.h) * scaleY),
              boxPaint,
            );
          }
        }
      },
      '${outDir.path}/real_02_boxes.png',
    );
    src.dispose();
  });

  test('真实简谱：识别质量回归断言', () async {
    final bytes = File(kImage).readAsBytesSync();
    final outcome = await recognizeImageBytes(bytes);
    final bands = outcome.result.bands;
    final selected = bands.where((b) => b.selected).toList();

    String digitsOf(String s) => s.replaceAll(RegExp(r'[^0-7]'), '');
    final allDigits = digitsOf(selected.map((b) => b.text).join(' '));
    // ignore: avoid_print
    print('选中 ${selected.length} 行，数字流前 120 位: '
        '${allDigits.length > 120 ? allDigits.substring(0, 120) : allDigits}');

    // 1) 整页双声部共 8 条旋律线，应识别出足够多的音符
    expect(selected.length, greaterThanOrEqualTo(6), reason: '应选中至少 6 条旋律线');
    expect(allDigits.length, greaterThanOrEqualTo(120), reason: '整页应有大量数字');

    // 2) 上声部开头的 3̇3̇3̇3̇ / 2̇2̇2̇2̇ / 1̇1̇1̇1̇ 必须连号出现
    for (final pattern in ['3333', '2222', '1111']) {
      expect(allDigits.contains(pattern), isTrue,
          reason: '应识别出连续四个 $pattern（数字流开头：'
              '${allDigits.substring(0, allDigits.length.clamp(0, 80))}）');
    }

    // 3) 标题/英文副标题行不能被当成简谱行
    for (final b in selected) {
      expect(RegExp(r'[A-G]').hasMatch(b.text), isFalse,
          reason: '被选中的行里出现字母，多半是标题行：${b.text}');
    }

    // 4) 双声部应被拆开（否则行带会明显偏高）
    final heights = selected.map((b) => b.y1 - b.y0).toList()..sort();
    expect(heights.first, lessThan(160), reason: '存在过高的行带说明声部没拆开: $heights');
  });
}

Future<void> _savePng(int w, int h, void Function(Canvas) paint, String path) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  paint(canvas);
  final image = await recorder.endRecording().toImage(w, h);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
  image.dispose();
  // ignore: avoid_print
  print('已保存 $path');
}
