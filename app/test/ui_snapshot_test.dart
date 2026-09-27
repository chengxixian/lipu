/// 界面与版面快照：波浪进度条（离屏渲染，不走 widget 树，避免动画挂住测试）
/// 以及 A4 长谱版面回归（验证几十小节不会被压成一条细线）
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/render/staff_layout.dart';
import 'package:jianpu_app/render/staff_painter.dart';
import 'package:jianpu_app/ui/wavy_progress.dart';

Future<void> _save(int w, int h, void Function(Canvas) paint, String path) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  paint(canvas);
  final image = await recorder.endRecording().toImage(w, h);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
  image.dispose();
}

Future<void> _loadFonts() async {
  final bravura = File('assets/fonts/Bravura.otf');
  if (bravura.existsSync()) {
    final loader = FontLoader('Bravura')
      ..addFont(Future.value(ByteData.sublistView(bravura.readAsBytesSync())));
    await loader.load();
  }
  final hei = File(r'C:\Windows\Fonts\simhei.ttf');
  if (hei.existsSync()) {
    final loader = FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(hei.readAsBytesSync())));
    await loader.load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFonts();
    final dir = Directory('build/snapshots');
    if (!dir.existsSync()) dir.createSync(recursive: true);
  });

  test('波浪进度条：四种进度离屏渲染', () async {
    const w = 900;
    const h = 360;
    final path = 'build/snapshots/wavy_progress.png';
    await _save(w, h, (canvas) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Paint()..color = const Color(0xFF1C1B1F));
      final values = <double?>[0.15, 0.45, 0.8, null];
      for (var i = 0; i < values.length; i++) {
        canvas.save();
        canvas.translate(40, 40.0 + i * 80);
        WavyPainter(
          progress: values[i],
          phase: 0.18 * (i + 1),
          color: const Color(0xFFD0BCFF),
          trackColor: const Color(0xFF49454F),
          height: 34,
          wavelength: 60,
        ).paint(canvas, Size(w - 80, 34));
        canvas.restore();
      }
    }, path);
    expect(File(path).lengthSync(), greaterThan(1500));
    // ignore: avoid_print
    print('已保存 $path');
  });

  test('A4 长谱版面：几十小节应排成多行而不是被压窄', () async {
    // 把小星星重复 10 遍 -> 约 40+ 小节、180+ 个音（接近用户实测的 AI 转写规模）
    final one = '1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |';
    final body = List.filled(11, one).join();
    final score = parseJianpu('1=C 4/4 ♩=96\n$body|]');
    const a4 = 794.0;
    final doc = layoutScore(score, width: a4, style: const StaffStyle(space: 11));

    // 文档宽度必须就是 A4 宽（之前的问题是被 FittedBox 整体缩掉）
    expect(doc.width, a4);
    // 几十小节应该排成十几行以上，而不是一行塞满
    final systemCount = doc.ops.whereType<LineOp>().where((l) => (l.x2 - l.x1) > a4 * 0.8).length ~/ 5;
    // ignore: avoid_print
    print('A4 版面：${score.measures.length} 小节 / ${score.noteCount} 个音'
        ' -> ${doc.width.toInt()}×${doc.height.toInt()}，约 $systemCount 行');
    expect(systemCount, greaterThanOrEqualTo(6), reason: '长谱应分成多行谱表');
    expect(doc.height, greaterThan(400));

    final path = 'build/snapshots/a4_long_score.png';
    await _save(a4.ceil() + 48, doc.height.ceil() + 48, (canvas) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, a4 + 48, doc.height + 48),
        Paint()..color = const Color(0xFFDDDDDD),
      );
      canvas.translate(24, 24);
      canvas.drawRect(Rect.fromLTWH(0, 0, a4, doc.height), Paint()..color = const Color(0xFFFFFFFF));
      StaffPainter(doc, color: const Color(0xFF111111), accent: const Color(0xFF6750A4))
          .paint(canvas, Size(doc.width, doc.height));
    }, path);
    // ignore: avoid_print
    print('已保存 $path');
  });
}
