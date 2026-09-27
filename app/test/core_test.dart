import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/midi.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/audio/synth.dart';

void main() {
  group('调号与音高', () {
    test('调号解析', () {
      expect(parseKeySpec('C').letter, 'C');
      expect(parseKeySpec('#F').alter, 1);
      expect(parseKeySpec('bB').alter, -1);
      expect(parseKeySpec('♭B').alter, -1);
      expect(parseKeySpec('Am').mode, 'minor');
      expect(parseKeySpec('a小调').mode, 'minor');
      expect(parseKeySpec('C大调').mode, 'major');
    });

    test('调号升降号数量', () {
      expect(keyInfoOf('C').fifths, 0);
      expect(keyInfoOf('G').fifths, 1);
      expect(keyInfoOf('D').fifths, 2);
      expect(keyInfoOf('F').fifths, -1);
      expect(keyInfoOf('bB').fifths, -2);
      expect(keyInfoOf('Am').fifths, 0);
      expect(keyInfoOf('Em').fifths, 1);
    });

    test('音级 -> MIDI', () {
      final c = keyInfoOf('C');
      expect(degreeToMidi(1, 0, '', c), 60);
      expect(degreeToMidi(5, 0, '', c), 67);
      expect(degreeToMidi(1, 1, '', c), 72);
      expect(degreeToMidi(1, -1, '', c), 48);
      expect(degreeToMidi(4, 0, '#', c), 66);
      expect(degreeToMidi(7, 0, 'b', c), 70);
      final g = keyInfoOf('G');
      expect(degreeToMidi(1, 0, '', g), 67);
      expect(degreeToMidi(7, 0, '', g), 78);
    });

    test('拼写保持音级字母', () {
      final g = keyInfoOf('G');
      final p = noteToPitch(NoteItem(degree: 7), g);
      expect([p.letter, p.alter, p.octave, p.vexKey], ['F', 1, 5, 'f#/5']);
      final f = keyInfoOf('F');
      final bb = noteToPitch(NoteItem(degree: 4), f);
      expect([bb.letter, bb.alter, bb.octave], ['B', -1, 4]);
      expect(spellMidi(61, 0).alter, 1);
      expect(spellMidi(70, 6).alter, -1);
      expect(spellMidi(59, 6).octave, 3);
    });
  });

  group('时值拆分', () {
    test('整拍与附点', () {
      expect(notateTicks(4, 0, 1).map((s) => s.type), ['w']);
      expect(notateTicks(3, 0, 1).map((s) => s.type), ['h']);
      expect(notateTicks(3, 0, 1).first.dots, 1);
      expect(notateTicks(1.5, 0, 1).first.dots, 1);
    });

    test('跨强拍需要拆分并用延音线连接', () {
      final seg = notateTicks(3, 1, 1, 2);
      expect(seg.length, 2);
      expect(seg.fold<double>(0, (a, b) => a + b.ticks), closeTo(3, 1e-9));
      expect(seg.first.tieToNext, isTrue);
    });

    test('小节容量', () {
      expect(measureTicksOf(4, 4), 4);
      expect(measureTicksOf(3, 4), 3);
      expect(measureTicksOf(6, 8), 3);
    });
  });

  group('简谱解析', () {
    test('基础谱例', () {
      final score = parseJianpu('标题：小星星\n1=C 4/4 ♩=96\n1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]');
      expect(score.meta.title, '小星星');
      expect(score.meta.keyName, 'C');
      expect(score.meta.beats, 4);
      expect(score.meta.tempo, 96);
      expect(score.measures.length, 4);
      expect(score.measures[0].items.length, 4);
      expect(score.measures[1].items.length, 3);
      expect(score.measures[1].items[2].ticks, 2); // 5 - 合并为一个二分音符
      expect(score.measures.last.isFinal, isTrue);
      expect(score.meta.warnings, isEmpty);
    });

    test('八度 / 减时线 / 附点 / 变音 / 休止', () {
      final score = parseJianpu("1=G 4/4\n1' 7, #4 b7 | 1/ 2// 3/. 0 |]");
      final m0 = score.measures[0];
      expect((m0.items[0] as NoteItem).octave, 1);
      expect((m0.items[1] as NoteItem).octave, -1);
      expect((m0.items[2] as NoteItem).accidental, '#');
      expect((m0.items[3] as NoteItem).accidental, 'b');
      final m1 = score.measures[1];
      expect(m1.items[0].ticks, 0.5);
      expect(m1.items[1].ticks, 0.25);
      expect(m1.items[2].ticks, 0.75);
      expect(m1.items[3], isA<RestItem>());
      expect(noteToPitch(m0.items[0] as NoteItem, keyInfoOf('G')).midi, 79);
    });

    test('连音线与反复记号', () {
      final score = parseJianpu('1=C 4/4\n|: 1 2 (3 3) | 6~ 6 - - :|]');
      final m0 = score.measures[0];
      expect(m0.repeatStart, isTrue);
      expect((m0.items[2] as NoteItem).tieToNext, isTrue);
      expect((m0.items[3] as NoteItem).tieToPrev, isTrue);
      final m1 = score.measures[1];
      expect((m1.items[0] as NoteItem).tieToNext, isTrue);
      expect((m1.items[1] as NoteItem).tieToPrev, isTrue);
      expect(m1.repeatEnd, isTrue);
      expect(score.meta.warnings, isEmpty);
    });

    test('小节超拍会告警并自动新起小节', () {
      final score = parseJianpu('1=C 4/4\n|: 1 2 (3 3) 5 | 6 6 5 - :|]');
      expect(score.meta.warnings.any((w) => w.contains('超出拍号容量')), isTrue);
      // 5 被放到新小节，音符一个都没丢（1 2 3 3 5 6 6 5）
      expect(score.noteCount, 8);
      expect(score.measures.first.repeatStart, isTrue);
    });

    test('拍号不符给出告警但不丢音', () {
      final score = parseJianpu('1=C 4/4\n1 2 3 4 5 | 1 2 3 4 |]');
      expect(score.meta.warnings, isNotEmpty);
      final total = score.measures.fold<int>(0, (a, m) => a + m.items.length);
      expect(total, greaterThanOrEqualTo(9));
    });

    test('识别结果风格的表头（带空格）也能解析', () {
      final score = parseJianpu('1 = G\n4 / 4\n5 5 6 5 | 1\' 7 1\' - |]');
      expect(score.meta.keyName, 'G');
      expect(score.meta.beats, 4);
      expect(score.measures[0].items.length, 4);
    });

    test('文本回写往返一致', () {
      const src = "1=G 4/4 ♩=88\n5 5 6 5 | 1' 7 1' - | 4/ 4/ 3 2 | 1 - - - |]";
      final score = parseJianpu(src);
      final again = parseJianpu(toJianpu(score));
      String flat(Score s) => s.measures
          .map((m) => m.items
              .map((i) => i is NoteItem
                  ? 'n${i.degree}:${i.octave}:${i.accidental}:${i.ticks}'
                  : 'r${i.ticks}')
              .join(','))
          .join('|');
      expect(flat(again), flat(score));
      expect(again.meta.keyName, score.meta.keyName);
    });
  });

  group('MusicXML 导出', () {
    Score build() => parseJianpu("标题：测试曲\n词：甲\n曲：乙\n1=G 4/4 ♩=88\n"
        "|: 5 5 6 5 | 1' 7 1' - | 4/ 4/ #4 3 | 2 0 1 - :|]");

    test('结构正确', () {
      final xml = toMusicXML(build());
      expect(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'), isTrue);
      expect(xml.contains('<divisions>16</divisions>'), isTrue);
      expect(xml.contains('<fifths>1</fifths>'), isTrue);
      expect(xml.contains('<work-title>测试曲</work-title>'), isTrue);
      expect(xml.contains('<creator type="composer">乙</creator>'), isTrue);
      expect(xml.contains('<repeat direction="forward"/>'), isTrue);
      expect(xml.contains('<repeat direction="backward"/>'), isTrue);
      expect(xml.contains('<bar-style>light-heavy</bar-style>'), isTrue);
      // 所有 duration 均为正整数
      final durations = RegExp(r'<duration>(\d+)</duration>').allMatches(xml).map((m) => int.parse(m.group(1)!));
      expect(durations, isNotEmpty);
      for (final d in durations) {
        expect(d, greaterThan(0));
        expect(d % 1, 0);
      }
      // 标签配平
      final opens = RegExp(r'<([a-zA-Z-]+)(\s[^>]*)?>').allMatches(xml).where((m) {
        final t = m.group(0)!;
        return !t.endsWith('/>') && !t.startsWith('<?') && !t.startsWith('<!');
      }).length;
      final closes = RegExp(r'</([a-zA-Z-]+)>').allMatches(xml).length;
      expect(opens, closes);
    });

    test('调号内的音不重复写升降号，调号外的要写', () {
      final xml = toMusicXML(build());
      // G 大调里 F# 不需要写 sharp
      expect(xml.contains('<accidental>sharp</accidental>'), isTrue); // #4 需要
      final measures = xml.split('<measure ');
      final withSharpF = measures.any((m) => m.contains('<step>F</step>') && m.contains('<accidental>sharp</accidental>'));
      expect(withSharpF, isFalse);
    });
  });

  group('MIDI 导出', () {
    test('文件头与结构', () {
      final score = parseJianpu("1=C 4/4 ♩=120\n1 2 3 4 | 5 - 6 - |]");
      final bytes = toMidi(score);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'MThd');
      expect(bytes[8] * 256 + bytes[9], 0); // format 0
      expect(bytes[10] * 256 + bytes[11], 1); // 1 track
      expect(bytes[12] * 256 + bytes[13], 480);
      final tail = bytes.sublist(bytes.length - 3);
      expect(tail, [0xFF, 0x2F, 0x00]);
      // tempo meta 存在
      var foundTempo = false;
      for (var i = 0; i < bytes.length - 3; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0x51) foundTempo = true;
      }
      expect(foundTempo, isTrue);
    });

    test('VLQ 编码', () {
      expect(encodeVlq(0), [0x00]);
      expect(encodeVlq(127), [0x7F]);
      expect(encodeVlq(128), [0x81, 0x00]);
      expect(encodeVlq(8192), [0xC0, 0x00]);
      expect(encodeVlq(0x0FFFFFFF), [0xFF, 0xFF, 0xFF, 0x7F]);
    });

    test('连音线合并为一个音', () {
      final tied = parseJianpu('1=C 4/4\n1~ 1 2 3 |]');
      final plain = parseJianpu('1=C 4/4\n2 2 2 3 |]');
      int noteOns(List<int> b) {
        var c = 0;
        for (var i = 0; i < b.length - 1; i++) {
          if (b[i] >= 0x90 && b[i] <= 0x9F && b[i + 2] > 0) c++;
        }
        return c;
      }

      expect(noteOns(toMidi(tied)), lessThan(noteOns(toMidi(plain))));
    });
  });

  group('音频合成', () {
    test('WAV 头部正确', () {
      final score = parseJianpu('1=C 4/4\n1 2 3 4 |]');
      final wav = synthesizeWav(score, sampleRate: 8000);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
      final bd = ByteData.sublistView(Uint8List.fromList(wav));
      expect(bd.getUint16(20, Endian.little), 1); // PCM
      expect(bd.getUint16(22, Endian.little), 1); // mono
      expect(bd.getUint32(24, Endian.little), 8000);
      expect(bd.getUint16(34, Endian.little), 16);
      expect(wav.length, greaterThan(1000));
    });
  });
}
