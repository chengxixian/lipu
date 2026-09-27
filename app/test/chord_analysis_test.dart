/// 和弦判读测试：模板匹配、缺音/多音/八度重复的识别、整谱扫描与摘要
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/chord_analysis.dart';
import 'package:jianpu_app/core/parse.dart';

void main() {
  group('和弦模板匹配', () {
    test('基本三和弦', () {
      expect(guessChord([60, 64, 67]).label, 'C');
      expect(guessChord([60, 64, 67]).quality, '大三');
      expect(guessChord([62, 65, 69]).label, 'Dm');
      expect(guessChord([67, 71, 74]).label, 'G');
      expect(guessChord([59, 62, 65]).label, 'Bdim');
    });

    test('七和弦与转位（转位不影响判定）', () {
      expect(guessChord([60, 64, 67, 71]).label, 'Cmaj7');
      expect(guessChord([62, 65, 69, 72]).label, 'Dm7');
      expect(guessChord([67, 71, 74, 77]).label, 'G7');
      expect(guessChord([52, 55, 60, 64]).label, 'C'); // E-G-C-E → C 大三
      expect(guessChord([55, 60, 64, 67]).label, 'C'); // G-C-E-G → C 大三（转位）
    });

    test('缺音/多音会被标出来（这正是"和弦不准"的两种表现）', () {
      // C 大三缺五音
      final missingFifth = guessChord([60, 64]);
      expect(missingFifth.recognized, isTrue);
      expect(missingFifth.label, 'C');
      // 只有两个音时不判（信息不足）
      expect(guessChord([60]).recognized, isFalse);
      // C 大三 + 一个不属于它的音（比如 F）→ 标成"多"
      final withExtra = guessChord([60, 64, 67, 65]);
      expect(withExtra.recognized, isTrue);
      expect(withExtra.extraSteps.isNotEmpty || withExtra.label == 'F', isTrue,
          reason: '要么判成带多音的和弦，要么判成另一个和弦，不能无脑通过');
    });

    test('八度重复会被标出来（泛音鬼影的典型形态）', () {
      final g = guessChord([60, 64, 67, 72]); // C4 E4 G4 C5
      expect(g.octaveDoubled, contains('C'));
      expect(g.label, 'C');
    });

    test('认不出来时不乱猜', () {
      // 一堆半音堆叠（音簇），不该硬套成某个和弦
      final g = guessChord([60, 61, 62, 63]);
      expect(g.recognized, isFalse);
    });
  });

  group('整谱扫描', () {
    test('扫出所有含和弦的音符并给出摘要', () {
      final score = parseJianpu('1=C 4/4\n[1 3 5] [4 6 1\'] [5 7 2\'] [1 3 5] |]');
      final items = analyzeScoreChords(score);
      expect(items.length, 4);
      expect(items.first.midis, [60, 64, 67]);
      expect(items.first.guess.label, 'C');
      expect(items[1].guess.label, 'F');
      expect(items[2].guess.label, 'G');
      final summary = chordSummary(items);
      expect(summary, contains('和弦 4 处'));
      expect(summary, contains('C×2'));
      expect(summary, contains('F×1'));
    });

    test('没有和弦时不给入口（摘要为空、列表为空）', () {
      final score = parseJianpu('1=C 4/4\n1 2 3 4 |]');
      expect(analyzeScoreChords(score), isEmpty);
      expect(chordSummary(const []), '');
    });

    test('大谱表两个声部里的和弦都能扫到', () {
      final score = parseJianpu('1=C 4/4\n高音: [1 3 5] - - - |\n低音: [1,, 3,, 5,,] - - - |]');
      final items = analyzeScoreChords(score);
      expect(items.length, 2);
      expect(items.map((e) => e.guess.label).toSet(), {'C'});
    });
  });
}
