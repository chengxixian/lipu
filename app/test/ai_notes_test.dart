/// AI 识谱的**结构化音符事件**路径：模型给 JSON，我们直接编成乐谱 / MIDI。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/midi.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/omr/ai_notes.dart';

/// 从 MIDI 字节里抠出 (tick, 音高, 是否 note-on)
List<(int, int, bool)> noteEvents(Uint8List bytes) {
  final out = <(int, int, bool)>[];
  var p = 14;
  p += 4; // 跳过 'MTrk'
  final len = (bytes[p] << 24) | (bytes[p + 1] << 16) | (bytes[p + 2] << 8) | bytes[p + 3];
  p += 4;
  final end = p + len;
  var tick = 0;
  int readVlq() {
    var v = 0;
    while (p < end) {
      final b = bytes[p++];
      v = (v << 7) | (b & 0x7F);
      if (b & 0x80 == 0) break;
    }
    return v;
  }

  int? running;
  while (p < end) {
    tick += readVlq();
    if (p >= end) break;
    var status = bytes[p];
    if (status & 0x80 == 0) {
      status = running!;
    } else {
      p++;
    }
    if (status == 0xFF) {
      p++;
      final l = readVlq();
      p += l;
      continue;
    }
    running = status;
    final kind = status & 0xF0;
    if (kind == 0x90 || kind == 0x80) {
      final note = bytes[p++];
      final vel = bytes[p++];
      out.add((tick, note, kind == 0x90 && vel > 0));
    } else if (kind == 0xC0 || kind == 0xD0) {
      p += 1;
    } else {
      p += 2;
    }
  }
  return out;
}

/// 一段"模型会真实返回"的内容：带代码围栏、带前后废话
const String kModelReply = '''
好的，我已经识别完成。

```json
{
  "title": "春风吹",
  "key": "1=C",
  "beats": 4,
  "beatType": 4,
  "tempo": 96,
  "notes": [
    {"staff": 1, "degree": 1, "octave": 0, "start": 0, "dur": 1},
    {"staff": 1, "degree": 1, "octave": 0, "start": 1, "dur": 1},
    {"staff": 1, "degree": 5, "octave": 0, "start": 2, "dur": 2},
    {"staff": 1, "degree": 3, "octave": 0, "start": 4, "dur": 1},
    {"staff": 1, "degree": 4, "octave": 0, "start": 4, "dur": 1},
    {"staff": 1, "degree": 5, "octave": 0, "start": 5, "dur": 2},
    {"staff": 2, "degree": 1, "octave": -2, "start": 0, "dur": 4},
    {"staff": 2, "degree": 5, "octave": -2, "start": 4, "dur": 4}
  ]
}
```

希望有帮助！
''';

void main() {
  group('解析模型返回的结构化结果', () {
    test('带围栏与废话也能抠出 JSON', () {
      final json = extractJsonObject(kModelReply);
      expect(json, isNotNull);
      expect(json!['title'], '春风吹');
    });

    test('解析出音符事件并能编成乐谱', () {
      final ai = parseAiNotes(kModelReply);
      expect(ai, isNotNull);
      expect(ai!.title, '春风吹');
      expect(ai.keyName, 'C');
      expect(ai.beats, 4);
      expect(ai.tempo, 96);
      expect(ai.notes.length, 8);
      expect(ai.isGrandStaff, isTrue, reason: '有 staff=2 就是大谱表');

      final score = scoreFromAiNotes(ai);
      expect(score.meta.title, '春风吹');
      expect(score.isGrandStaff, isTrue);
      expect(score.measures.length, 2);
      // 第 1 小节：三个音（1、1、5 两拍）
      expect(score.measures[0].items.length, 3);
      expect(score.measures[0].filled, 4);
      // 第 2 小节：3 与 4 同时起同时值 → 一个和弦，然后 5 两拍
      final m2 = score.measures[1].items.whereType<NoteItem>().toList();
      expect(m2.length, 2);
      expect(m2.first.isChord, isTrue, reason: '同时发声应当合成和弦');
      expect(notePitches(m2.first, score.key).map((p) => p.midi).toList(), [64, 65]); // 3=64, 4=65
      // 低音谱：两个全音符
      expect(score.measures[0].items2.length, 1);
      expect(score.measures[0].filled2, 4);
      final bass = score.measures[0].items2.first as NoteItem;
      expect(notePitches(bass, score.key).first.midi, 36); // 1,, = C2
    });

    test('简谱文本往返后音高与节奏都还在', () {
      final score = scoreFromAiNotes(parseAiNotes(kModelReply)!);
      final text = toJianpu(score);
      expect(text, contains('标题：春风吹'));
      expect(text, contains('高音:'));
      expect(text, contains('低音:'));

      final again = parseJianpu(text);
      expect(again.isGrandStaff, isTrue);
      expect(again.measures.length, score.measures.length);
      expect(again.pitchCount, score.pitchCount);
      // 和弦也要保住
      final chord = again.measures[1].items.whereType<NoteItem>().firstWhere((n) => n.isChord);
      expect(notePitches(chord, again.key).length, 2);
      // 每小节时值仍然自洽
      expect(again.meta.warnings.where((w) => w.contains('时值超出')), isEmpty);
    });

    test('音符直接给 midi 也行', () {
      final ai = parseAiNotes(jsonEncode({
        'key': '1=C',
        'notes': [
          {'midi': 60, 'start': 0, 'dur': 1},
          {'midi': 64, 'start': 1, 'dur': 1},
        ],
      }));
      expect(ai, isNotNull);
      final score = scoreFromAiNotes(ai!);
      final notes = score.measures[0].items.whereType<NoteItem>().toList();
      expect(notePitches(notes[0], score.key).first.midi, 60);
      expect(notePitches(notes[1], score.key).first.midi, 64);
    });

    test('小调 6=A（la 记法）会把音级平移到内部 do 记法', () {
      final ai = parseAiNotes(jsonEncode({
        'key': '6=A',
        'notes': [
          {'degree': 6, 'octave': 0, 'start': 0, 'dur': 1}, // 谱面 6 = 主音 A4
          {'degree': 1, 'octave': 0, 'start': 1, 'dur': 1}, // 谱面 1 = C5
        ],
      }));
      expect(ai, isNotNull);
      expect(ai!.keyName, 'Am');
      final score = scoreFromAiNotes(ai);
      expect(score.key.mode, 'minor');
      final notes = score.measures[0].items.whereType<NoteItem>().toList();
      expect(notePitches(notes[0], score.key).first.midi, 69, reason: '6=A 的 6 必须是 A4');
      expect(notePitches(notes[1], score.key).first.midi, 72, reason: '6=A 的 1 必须是 C5');
      // 内部记法仍然是 do 记法（1 = 主音），所以返回的 degree 已被平移
      expect(notes[0].degree, 1);
      expect(notes[1].degree, 3);
    });

    test('1=Am（do 记法）不受影响', () {
      final ai = parseAiNotes(jsonEncode({
        'key': '1=Am',
        'notes': [
          {'degree': 1, 'octave': 0, 'start': 0, 'dur': 1},
        ],
      }));
      final score = scoreFromAiNotes(ai!);
      expect(notePitches(score.measures[0].items.first as NoteItem, score.key).first.midi, 69,
          reason: '1=Am 的 1 就是 A4');
    });

    test('不是结构化格式就返回 null（调用方退回简谱文本）', () {
      expect(parseAiNotes('1=C 4/4\n1 1 5 5 |]'), isNull);
      expect(parseAiNotes(''), isNull);
      expect(parseAiNotes('{"title":"x"}'), isNull, reason: '没有 notes 不算结构化结果');
      expect(parseAiNotes('```json\n{"notes":[]}\n```'), isNull);
      expect(parseAiNotes('{"notes":[{"degree":9}]}'), isNull, reason: '音级越界应被丢掉');
    });

    test('文本兜底：上下两行小节数相同就分成两个声部（钢琴谱）', () {
      final text = '''
标题：春风吹
1=C 4/4
3 3 3 3 | 2 2 2 2 | 1 1 1 1 | 6, 7, 1 2 |
1,, - - - | 5,, - - - | 4,, - - - | 1,, - - - |''';
      final voiced = assignVoicesToText(text);
      expect(voiced, contains('高音: 3 3 3 3'));
      expect(voiced, contains('低音: 1,, - - -'));
      // 真的能解析成大谱表
      final score = parseJianpu(voiced);
      expect(score.isGrandStaff, isTrue);
      expect(score.measures.first.items2, isNotEmpty);
    });

    test('文本兜底：行数不同的两行是接续旋律，不拆分', () {
      final text = '''
1=C 4/4
1 1 5 5 |
6 6 5 - | 4 4 3 3 |''';
      final out = assignVoicesToText(text);
      expect(out.contains('高音:'), isFalse);
      expect(out.contains('低音:'), isFalse);
    });

    test('已经带声部前缀的文本不再重复加', () {
      const text = '1=C 4/4\n高音: 1 2 3 4 |\n低音: 1,, - - - |';
      expect(assignVoicesToText(text), text);
    });

    test('跨小节的长音会拆成连音线', () {
      final ai = parseAiNotes(jsonEncode({
        'key': '1=C',
        'beats': 4,
        'beatType': 4,
        'notes': [
          {'degree': 1, 'start': 2, 'dur': 4}, // 从第 3 拍起持续 4 拍 → 跨小节
        ],
      }));
      final score = scoreFromAiNotes(ai!);
      expect(score.measures.length, 2);
      final a = score.measures[0].items.whereType<NoteItem>().last;
      final b = score.measures[1].items.whereType<NoteItem>().first;
      expect(a.tieToNext, isTrue);
      expect(b.tieToPrev, isTrue);
      expect(score.measures[0].filled, 4);
    });

    test('空档会补休止符', () {
      final ai = parseAiNotes(jsonEncode({
        'key': '1=C',
        'beats': 4,
        'beatType': 4,
        'notes': [
          {'degree': 1, 'start': 0, 'dur': 1},
          {'degree': 5, 'start': 3, 'dur': 1},
        ],
      }));
      final score = scoreFromAiNotes(ai!);
      final items = score.measures[0].items;
      expect(items.length, 3);
      expect(items[1], isA<RestItem>());
      expect(score.measures[0].filled, 4);
    });
  });

  group('结构化结果 -> MIDI', () {
    test('和弦在 MIDI 里同时发声，低音声部也在', () {
      final score = scoreFromAiNotes(parseAiNotes(kModelReply)!);
      final events = noteEvents(toMidi(score));
      final ons = events.where((e) => e.$3).toList();
      final pitches = ons.map((e) => e.$2).toSet();
      expect(pitches, containsAll([60, 64, 65, 67, 36, 43]));
      // 3 与 4 应当在同一 tick 起音
      final atChord = ons.where((e) => e.$2 == 64 || e.$2 == 65).toList();
      expect(atChord.length, 2);
      expect(atChord[0].$1, atChord[1].$1);
    });
  });
}
