/// 八度点本地检测 + 纠正：用**合成图**做回归（不联网、不依赖真实谱页）。
///
/// 为什么要本地检测：八度点是简谱里最小的记号（1~2 像素），云端视觉模型读它不稳定
/// （实测同一张春风吹原图，两次分别给出"整页一个 0 都没有"和"高点几乎全丢"两种相反的错）。
/// 而"数字正上方/正下方有没有点"是几何问题，本地连通域分析更可靠。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/omr/ai_notes.dart';
import 'package:jianpu_app/omr/octave_hint.dart';
import 'package:jianpu_app/omr/omr.dart';
import 'package:jianpu_app/omr/omr_core.dart';
import 'package:jianpu_app/omr/omr_service.dart';
import 'package:jianpu_app/omr/omr_templates.dart';

/// 一个音的视觉描述
class _N {
  final String digit;
  final int up;
  final int down;
  const _N(this.digit, {this.up = 0, this.down = 0});
}

/// 渲染一行简谱（数字 + 上下八度点），返回灰度图
Future<GrayImage> renderLine(List<_N> notes, String font,
    {double fontSize = 56, double gap = 84}) async {
  final w = (notes.length * gap + gap).ceil();
  final h = (fontSize * 2.6).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF));
  final tp = TextPainter(textDirection: TextDirection.ltr);
  final cy = h / 2;
  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    final x = gap * (i + 0.5);
    tp.text = TextSpan(
      text: n.digit,
      style: TextStyle(fontSize: fontSize, fontFamily: font, color: const Color(0xFF000000)),
    );
    tp.layout();
    tp.paint(canvas, Offset(x - tp.width / 2, cy - tp.height / 2));
    final dotR = fontSize * 0.06;
    for (var k = 0; k < n.up; k++) {
      final dy = cy - tp.height / 2 - fontSize * (0.22 + 0.22 * k);
      canvas.drawCircle(Offset(x, dy), dotR, Paint()..color = const Color(0xFF000000));
    }
    for (var k = 0; k < n.down; k++) {
      final dy = cy + tp.height / 2 + fontSize * (0.22 + 0.22 * k);
      canvas.drawCircle(Offset(x, dy), dotR, Paint()..color = const Color(0xFF000000));
    }
  }
  final img = await recorder.endRecording().toImage(w.ceil(), h.ceil());
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  return GrayImage.fromRgba(data!.buffer.asUint8List(), w.ceil(), h.ceil());
}

/// 跑本地流水线取八度读数（和 App 里 isolate 跑的是同一个函数）
List<LocalOctaveLine> localLinesOf(GrayImage g, GlyphClassifier c) =>
    localOctaveLines(recognizeJianpuPage(g, c).result);

Future<String> loadFonts() async {
  final fonts = <String, String>{
    'TestArial': r'C:\Windows\Fonts\arial.ttf',
    'TestSimHei': r'C:\Windows\Fonts\simhei.ttf',
    'TestCalibri': r'C:\Windows\Fonts\calibri.ttf',
  };
  final loaded = <String>[];
  for (final e in fonts.entries) {
    final f = File(e.value);
    if (!f.existsSync()) continue;
    final loader = FontLoader(e.key)
      ..addFont(Future.value(ByteData.sublistView(await f.readAsBytes())));
    await loader.load();
    loaded.add(e.key);
  }
  return loaded.isEmpty ? 'TestArial' : loaded.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    debugClassifierOverride = null;
  });

  group('本地八度点读数', () {
    test('上下加点 / 没有点，都能读出来', () async {
      final font = await loadFonts();
      debugClassifierOverride = await buildGlyphClassifier(fonts: [font]);
      // 1(无点) 2(上1点) 3(下1点) 5(上2点)
      final g = await renderLine(const [
        _N('1'),
        _N('2', up: 1),
        _N('3', down: 1),
        _N('5', up: 2),
      ], font);
      final lines = localLinesOf(g, debugClassifierOverride!);
      expect(lines, isNotEmpty, reason: '应当切出一行');
      final l = lines.first;
      // ignore: avoid_print
      print('本地读数：degrees=${l.degrees} octaves=${l.octaves}');
      // 至少要把"有点/没点"区分出来：无点的应当是 0，上点的是 1，下点的是 -1
      expect(l.degrees.length, greaterThanOrEqualTo(3));
      expect(l.octaves.where((o) => o == 1).length, greaterThanOrEqualTo(1),
          reason: '上加点要读成 +1：${l.octaves}');
      expect(l.octaves.where((o) => o == -1).length, greaterThanOrEqualTo(1),
          reason: '下加点要读成 -1：${l.octaves}');
    });

    test('全是无点的音 → 八度都是 0（不能凭空加点）', () async {
      final font = await loadFonts();
      debugClassifierOverride = await buildGlyphClassifier(fonts: [font]);
      final g = await renderLine(const [_N('1'), _N('2'), _N('3'), _N('5')], font);
      final lines = localLinesOf(g, debugClassifierOverride!);
      expect(lines, isNotEmpty);
      final octs = lines.first.octaves.whereType<int>().toList();
      // ignore: avoid_print
      print('无点行的八度：${lines.first.octaves}');
      expect(octs.where((o) => o != 0), isEmpty, reason: '没有点就不该有八度：${lines.first.octaves}');
    });
  });

  group('对齐 + 纠正', () {
    test('数字一致的位置才按本地读数改八度', () {
      // AI：1 2 3 5，全判成 +1（春风吹那种"把没点的音也当成有点"的错）
      final ai = parseAiNotes('{"title":"t","key":"1=C","beats":4,"beatType":4,'
          '"v1":[[1,1,0,1],[2,1,1,1],[3,1,2,1],[5,1,3,1]]}')!;
      // 本地：1(0) 2(+1) 3(0) 5(+1)
      final line = LocalOctaveLine(
        y: 0,
        degrees: const [1, 2, 3, 5],
        octaves: const [0, 1, 0, 1],
        text: '1 2\' 3 5\'',
      );
      final fix = fixOctavesFromLocal(ai, [line]);
      expect(fix.changed, 2, reason: '本地与 AI 不一致的 2 个音（1 和 3）应当被改成 0');
      final octs = fix.score.notes.map((n) => n.octave).toList();
      expect(octs, [0, 1, 0, 1]);
      // midi 也要跟着算对（1 从 +1 掉回 0 → 低 12）
      expect(fix.score.notes[0].midi, 60);
      expect(fix.score.notes[1].midi, 74);
    });

    test('数字对不上的地方不动（防止对齐漂移乱改）', () {
      final ai = parseAiNotes('{"title":"t","key":"1=C","beats":4,"beatType":4,'
          '"v1":[[1,1,0,1],[2,1,1,1],[3,1,2,1],[5,1,3,1]]}')!;
      // 本地这一行数字是 1 7 3 5（第 2 个认错了），八度说第 2 个是 0
      final line = LocalOctaveLine(
        y: 0,
        degrees: const [1, 7, 3, 5],
        octaves: const [0, 0, 0, 0],
        text: '1 7 3 5',
      );
      final fix = fixOctavesFromLocal(ai, [line]);
      final octs = fix.score.notes.map((n) => n.octave).toList();
      expect(octs[1], 1, reason: '数字对不上（7 vs 2）→ 不动第 2 个音：$octs');
      expect(octs[0], 0, reason: '数字对得上的照改');
    });

    test('完全对不上的行直接跳过', () {
      final ai = parseAiNotes('{"title":"t","key":"1=C","beats":4,"beatType":4,'
          '"v1":[[1,1,0,1],[2,1,1,1],[3,1,2,1]]}')!;
      final line = LocalOctaveLine(
        y: 0,
        degrees: const [5, 5, 5, 5, 5, 5],
        octaves: const [0, 0, 0, 0, 0, 0],
        text: '5 5 5 5 5 5',
      );
      final fix = fixOctavesFromLocal(ai, [line]);
      expect(fix.changed, 0, reason: '匹配率太低就不该动：${fix.diagnostics}');
      expect(fix.diagnostics.join(), contains('没对齐'));
    });

    test('下声部也能对上（低音谱的音要落在 staff=2 上）', () {
      final ai = parseAiNotes('{"title":"t","key":"1=C","beats":4,"beatType":4,'
          '"v1":[[1,0,0,1],[2,0,1,1],[3,0,2,1],[5,0,3,1]],'
          '"v2":[[4,-1,0,1],[3,-1,1,1],[2,-1,2,1],[1,-1,3,1]]}')!;
      final line = LocalOctaveLine(
        y: 100,
        degrees: const [4, 3, 2, 1],
        octaves: const [-2, -2, -2, -2],
        text: '4,, 3,, 2,, 1,,',
      );
      final fix = fixOctavesFromLocal(ai, [line]);
      expect(fix.changed, 4, reason: '低音谱那 4 个音应当被改成 -2：${fix.diagnostics}');
      expect(fix.score.notes.where((n) => n.staff == 2).map((n) => n.octave).toList(),
          [-2, -2, -2, -2]);
    });
  });
}
