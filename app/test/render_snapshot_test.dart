/// 渲染快照测试：把排版结果输出成 PNG，便于人工检查五线谱绘制是否正确
/// （顺便充当排版回归测试：文件能生成、尺寸合理、颜色有墨迹）
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/render/staff_layout.dart';
import 'package:jianpu_app/render/staff_painter.dart';

final samples = <String, String>{
  '01_小星星': '''标题：小星星
词：佚名
1=C 4/4 ♩=96
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |
5 5 4 4 | 3 3 2 - | 5 5 4 4 | 3 3 2 - |
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]''',
  '02_节奏型': '''标题：节奏与记号测试
1=G 4/4 ♩=88
5 5 6 5 | 1' 7 1' - | 4/ 4/ #4 3 | 2 0 1 - |
3// 3// 3/ 3/ | 6~ 6 5 - - | 1' 1' 7 6 | 5 - - - |]''',
  '03_茉莉花': '''标题：茉莉花（片段）
1=D 4/4 ♩=72
3 3 5 6 | 1' 6 5 6 | 5 5 3 5 | 6 - - - |
3 3 5 6 | 1' 6 5 6 | 5 5 3 5 | 6 - - - |]''',
  '04_小调低音': '''标题：低音区与低音谱号
1=Am 3/4 ♩=100
6, 7, 1 2 3 4 | 5 4 3 2 1 7, | 6, - - |]''',
  // 和弦 + 大谱表：高音谱走旋律与和弦，低音谱走左手
  '05_和弦大谱表': '''标题：和弦与大谱表
1=C 4/4 ♩=96
高音: [1 3 5] [4 6 1'] [5 7 2'] [1 3 5] |
高音: [4 6 1'] [2 4 6] [5 7 2'] [1 3 5] |
低音: 1,, - - - | 4,, - - - |
低音: 5,, - - - | 1,, - - - |]''',
  // 长谱：用来检查 A4 分页
  '06_长谱分页': [
    '标题：长谱分页检查',
    '1=C 4/4 ♩=96',
    for (var i = 0; i < 12; i++)
      "高音: [1 3 5] [4 6 1'] [5 7 2'] [1 3 5] | [4 6 1'] [2 4 6] [5 7 2'] [1 3 5] |",
    for (var i = 0; i < 12; i++) '低音: 1,, - - - | 1,, - - - |',
  ].join('\n'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // flutter test 环境不会自动加载 pubspec 里的字体，这里显式加载
    // 1) 乐谱字体 Bravura（SMuFL）
    final bravura = File('assets/fonts/Bravura.otf');
    if (bravura.existsSync()) {
      final loader = FontLoader('Bravura')
        ..addFont(Future.value(ByteData.sublistView(bravura.readAsBytesSync())));
      await loader.load();
    }
    // 2) 文本字体（标题/歌词）：注册成默认族名，保证中文与拉丁字符都能显示
    for (final path in [r'C:\Windows\Fonts\simhei.ttf', r'C:\Windows\Fonts\arial.ttf']) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  test('渲染快照到 build/snapshots', () async {
    final outDir = Directory('build/snapshots');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    for (final entry in samples.entries) {
      final score = parseJianpu(entry.value);
      // A4 版面：794 × 1123 逻辑像素（96dpi 下的 A4）
      final doc = layoutScore(
        score,
        width: 794,
        style: const StaffStyle(space: 11, pageHeight: 1123),
      );
      for (final page in doc.pages) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, doc.width, page.height));
        canvas.drawRect(Rect.fromLTWH(0, 0, doc.width, page.height), Paint()..color = const Color(0xFFFFFFFF));
        StaffPainter(StaffDocument(doc.width, page.height, page.ops), color: const Color(0xFF111111), accent: const Color(0xFF6750A4))
            .paint(canvas, Size(doc.width, page.height));
        final image = await recorder.endRecording().toImage(doc.width.ceil(), page.height.ceil());
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final suffix = doc.pages.length > 1 ? '_p${page.index + 1}' : '';
        final file = File('${outDir.path}/${entry.key}$suffix.png');
        file.writeAsBytesSync(png!.buffer.asUint8List());
        expect(file.lengthSync(), greaterThan(2000), reason: '${entry.key} 生成失败');
        // ignore: avoid_print
        print('snapshot: ${file.path}  ${doc.width.toInt()}x${page.height.toInt()}  '
            'ops=${page.ops.length}  小节 ${page.firstMeasure + 1}-${page.lastMeasure + 1}');
      }

      expect(doc.ops.length, greaterThan(40), reason: '${entry.key} 绘制指令太少，排版可能有问题');
      expect(doc.pages.length, greaterThanOrEqualTo(1));
      final notes = score.measures.fold<int>(0, (a, m) => a + m.items.length);
      expect(notes, greaterThan(0));
    }
  });

  test('A4 分页：长谱必须切成多页，且每页都在页高之内', () {
    final score = parseJianpu(samples['06_长谱分页']!);
    const style = StaffStyle(space: 11, pageHeight: 1123);
    final doc = layoutScore(score, width: 794, style: style);

    expect(doc.pages.length, greaterThan(1), reason: '48 小节的谱子不可能只占一页');
    for (final p in doc.pages) {
      expect(p.height, 1123, reason: '每页都是 A4 高');
      expect(p.usedHeight, lessThanOrEqualTo(1123), reason: '第 ${p.index + 1} 页内容溢出');
    }
    // 小节要被完整地分到各页，不重不漏
    final covered = <int>[];
    for (final p in doc.pages) {
      for (var i = p.firstMeasure; i <= p.lastMeasure; i++) {
        covered.add(i);
      }
    }
    expect(covered.toSet().length, score.measures.length);
    expect(covered.length, score.measures.length);
  });
}
