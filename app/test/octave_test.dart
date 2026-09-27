/// 八度（数字上下的点）链路回归测试。
///
/// 背景：用户反馈"春风吹里原本的高音没有高、低音没有低"。实测下来**我们自己的链路
/// 没有问题**（文本 ↔ 模型 ↔ MusicXML 的八度都对得上），问题在视觉模型读不准那些
/// 1~2 像素的小点。这个文件守住两件事：
///   1. 我们的八度链路不许退化；
///   2. 读错八度时程序要能**自己发现**（`octaveVerdict`），并给出修正手段（`shiftOctave`）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/omr/ai_notes.dart';
import 'package:jianpu_app/state.dart';

/// 造一份结构化输出：[octaves] 依次给每个音的八度（都在 v1；[v2Octaves] 给下声部）
String aiJson(List<int> octaves, {List<int> v2Octaves = const [], int beats = 4}) {
  final notes = <String>[];
  var start = 0.0;
  for (final o in octaves) {
    notes.add('[1,$o,${start.toStringAsFixed(2)},1]');
    start += 1;
  }
  final v2 = <String>[];
  var s2 = 0.0;
  for (final o in v2Octaves) {
    v2.add('[1,$o,${s2.toStringAsFixed(2)},1]');
    s2 += 1;
  }
  return '{"title":"t","key":"1=C","beats":$beats,"beatType":4,"tempo":96,'
      '"v1":[${notes.join(',')}]${v2.isEmpty ? '' : ',"v2":[${v2.join(',')}]'}}';
}

void main() {
  group('八度链路（文本 → 模型 → MusicXML）', () {
    test('简谱文本里的八度点：1 1\' 1, 1,,', () {
      final score = parseJianpu("1=C 4/4\n1 1' 1, 1,, |]");
      final items = score.measures[0].items.whereType<NoteItem>().toList();
      expect(items.map((n) => n.octave).toList(), [0, 1, -1, -2]);
      expect(items.map((n) => notePitches(n, score.key).first.midi).toList(), [60, 72, 48, 36]);
      // 文本往返也不能丢
      final again = parseJianpu(toJianpu(score)).measures[0].items.whereType<NoteItem>().toList();
      expect(again.map((n) => n.octave).toList(), [0, 1, -1, -2]);
    });

    test('MusicXML 的 <octave> 要对（高音真的高、低音真的低）', () {
      final xml = toMusicXML(parseJianpu("1=C 4/4\n1 1' 1, 1,, |]"));
      final octaves = RegExp(r'<octave>(-?\d+)</octave>')
          .allMatches(xml)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      expect(octaves, [4, 5, 3, 2]);
    });

    test('AI 事件里的 octave 原样进乐谱（不被"归一化"）', () {
      final ai = parseAiNotes(aiJson([0, 1, -1, -2]))!;
      final items = scoreFromAiNotes(ai).measures[0].items.whereType<NoteItem>().toList();
      expect(items.map((n) => n.octave).toList(), [0, 1, -1, -2]);
    });
  });

  group('八度读错时程序要能自己发现', () {
    test('一个 0 都没有（把没点的音也当成有点）→ 判为坏', () {
      // 春风吹实测：模型给出 +1:143 / -1:56，一个 0 都没有，而原谱有一堆不带点的音
      final ai = parseAiNotes(aiJson(List.filled(80, 1), v2Octaves: List.filled(20, -1)))!;
      final v = octaveVerdict(ai);
      expect(v.zeroMissing, isTrue, reason: '有 0 的音一个都没有，明显不对');
      expect(v.bad, isTrue);
    });

    test('全是 0（漏看八度点）→ 判为坏', () {
      final ai = parseAiNotes(aiJson(List.filled(80, 0), v2Octaves: List.filled(20, 0)))!;
      expect(octaveVerdict(ai).flatShare, 1.0);
      expect(octaveVerdict(ai).bad, isTrue);
    });

    test('某个声部音域跨了三个八度 → 判为坏', () {
      // 48~84 都出现：八度看错的典型症状
      final octs = <int>[for (var i = 0; i < 40; i++) [-1, 0, 1][i % 3]];
      final ai = parseAiNotes(aiJson(octs, v2Octaves: List.filled(20, -2)))!;
      expect(octaveVerdict(ai).wideSpan, isTrue);
      expect(octaveVerdict(ai).bad, isTrue);
    });

    test('下声部比上声部还高 → 判为坏（八度看反）', () {
      final ai = parseAiNotes(aiJson(List.filled(20, -1), v2Octaves: List.filled(20, 1)))!;
      expect(octaveVerdict(ai).bassInverted, isTrue);
      expect(octaveVerdict(ai).bad, isTrue);
    });

    test('正常的谱子（0 和 ±1 都有、上高下低）→ 不判为坏', () {
      // 上声部：0 与 +1 混合；下声部：-1（低音伴奏）
      final v1 = <int>[for (var i = 0; i < 60; i++) (i % 3 == 0) ? 0 : 1];
      final ai = parseAiNotes(aiJson(v1, v2Octaves: List.filled(30, -1)))!;
      final v = octaveVerdict(ai);
      expect(v.bad, isFalse, reason: '别误伤正常谱子：$v');
    });

    test('音符太少（哼唱/练习曲）不判', () {
      final ai = parseAiNotes(aiJson(List.filled(10, 0)))!;
      expect(octaveVerdict(ai).bad, isFalse);
    });
  });

  group('一键修八度', () {
    test('八度 +1 / -1 只动被点的那个音，且能撤销', () {
      final state = AppState();
      state.setText("1=C 4/4\n1 6 7 5 |]", immediate: true);
      final items0 = state.score!.measures[0].items.whereType<NoteItem>().toList();
      final secondBefore = notePitches(items0[1], state.score!.key).first.midi;
      expect(secondBefore, 69, reason: '6 = A4');

      state.shiftOctave('lipu-0-1-1-0-0', 1); // 把第 2 个音升八度
      final items = state.score!.measures[0].items.whereType<NoteItem>().toList();
      expect(items[0].octave, 0, reason: '别的音不动');
      expect(items[1].octave, 1);
      expect(notePitches(items[1], state.score!.key).first.midi, secondBefore + 12);
      state.shiftOctave('lipu-0-1-1-0-0', -1);
      expect(state.score!.measures[0].items.whereType<NoteItem>().toList()[1].octave, 0);
      state.undo();
      expect(state.score!.measures[0].items.whereType<NoteItem>().toList()[1].octave, 1,
          reason: '撤销要能回退');
    });

    test('改完八度，MusicXML 的 <octave> 跟着变', () {
      final state = AppState();
      state.setText("1=C 4/4\n1 2 3 4 |]", immediate: true);
      final xml0 = toMusicXML(state.score!);
      state.shiftOctave('lipu-0-1-0-0-0', 1);
      final xml1 = toMusicXML(state.score!);
      expect(RegExp(r'<octave>4</octave>').allMatches(xml0).length,
          greaterThan(RegExp(r'<octave>4</octave>').allMatches(xml1).length));
      expect(xml1, contains('<octave>5</octave>'));
    });
  });
}

/// 第一个音的 MIDI
int pitchAt0(AppState state) =>
    notePitches(state.score!.measures[0].items.whereType<NoteItem>().first, state.score!.key)
        .first
        .midi;
