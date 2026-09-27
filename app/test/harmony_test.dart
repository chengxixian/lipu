/// 和弦 + 大谱表（高音谱 / 低音谱两行）的模型、解析、MusicXML、MIDI 测试
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/audio/synth.dart';
import 'package:jianpu_app/core/midi.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/transcribe/melody.dart';
import 'package:jianpu_app/transcribe/quantize.dart';
import 'package:jianpu_app/transcribe/wav.dart';

/// 从 MIDI 字节里抠出 (tick, 音高, 是否 note-on) 事件，用来验证真实的并发发声
List<(int, int, bool)> midiNoteEvents(Uint8List bytes) {
  final out = <(int, int, bool)>[];
  var p = 14; // 跳过 MThd
  expect(String.fromCharCodes(bytes.sublist(p, p + 4)), 'MTrk');
  p += 4;
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
      status = running!; // running status
    } else {
      p++;
    }
    if (status == 0xFF) {
      p++; // meta type
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

void main() {
  group('和弦语法', () {
    test('[1 3 5] 解析成一个带两个和弦音的音符', () {
      final s = parseJianpu('1=C 4/4\n[1 3 5] 0 0 0 |]');
      final m = s.measures.first;
      final n = m.items.first as NoteItem;
      expect(n.degree, 1);
      expect(n.chord.length, 2);
      final ki = s.key;
      expect(notePitches(n, ki).map((p) => p.midi).toList(), [60, 64, 67]);
      expect(n.ticks, 1);
    });

    test('连写与后缀写法都能认出和弦', () {
      final a = parseJianpu('1=C 4/4\n[135] 0 0 0 |]').measures.first.items.first as NoteItem;
      expect(a.chord.length, 2);
      // [1 3 5]/ = 八分音符和弦
      final b = parseJianpu('1=C 4/4\n[1 3 5]/ [1 3 5]/ 0 0 0 0 |]').measures.first.items.first as NoteItem;
      expect(b.ticks, 0.5);
      expect(b.chord.length, 2);
    });

    test('和弦音可以各带八度与变音记号，主音自动取最低音', () {
      final s = parseJianpu("1=C 4/4\n[1 3 5'] b7 0 0 |]");
      final n = s.measures.first.items.first as NoteItem;
      final midis = notePitches(n, s.key).map((p) => p.midi).toList();
      expect(midis, [60, 64, 79]); // 1 3 5'（5' = G5 = 79）从低到高
      expect(n.degree, 1, reason: '主音应是最低音');
      expect(n.chord.map((t) => t.degree).toList(), [3, 5]);
    });

    test('叠加写法（主音后面跟 [3 5]）不是和弦，方括号单个记号仍是歌词', () {
      final s = parseJianpu('1=C 4/4\n1[啊] 2 3 4 |]');
      final n = s.measures.first.items.first as NoteItem;
      expect(n.chord, isEmpty);
      expect(n.lyric, '啊');
    });

    test('和弦与单音混排的时值/小节都能自洽', () {
      final s = parseJianpu('1=C 4/4\n[1 3 5] [4 6 1\'] [5 7 2\'] [1 3 5] |]');
      expect(s.measures.length, 1);
      expect(s.measures.first.filled, 4);
      expect(s.noteCount, 4, reason: '4 个和弦事件');
      expect(s.pitchCount, 12, reason: '每个和弦 3 个音');
      expect(s.meta.warnings.where((w) => w.contains('时值')), isEmpty);
    });

    test('和弦能正确回写成简谱并往返一致', () {
      final s = parseJianpu("1=C 4/4 ♩=96\n[1 3 5] [4 6 1']/ [5 7 2'] 0 |]");
      final text = toJianpu(s);
      expect(text, contains('[1 3 5]'));
      expect(text, contains("[4 6 1']/"));
      final again = parseJianpu(text);
      final ki = again.key;
      final first = again.measures.first.items.first as NoteItem;
      expect(notePitches(first, ki).map((p) => p.midi).toList(), [60, 64, 67]);
      expect(again.noteCount, s.noteCount);
    });
  });

  group('大谱表（两个声部）', () {
    const text = '''1=C 4/4 ♩=96
高音: [1 3 5] [4 6 1'] [5 7 2'] [1 3 5] |
低音: 1,, - - - |''';

    test('高音/低音前缀分出两个声部并标记为大谱表', () {
      final s = parseJianpu(text);
      expect(s.isGrandStaff, isTrue);
      expect(s.meta.clef, 'grand');
      expect(s.measures.length, 1);
      expect(s.measures.first.items.length, 4);
      expect(s.measures.first.items2.length, 1);
      expect(s.measures.first.filled2, 4);
      expect(s.meta.warnings.where((w) => w.contains('时值')), isEmpty);
    });

    test('低音声部按小节序号与高音声部对齐', () {
      final s = parseJianpu('''1=C 4/4
高音: 1 2 3 4 | 5 6 7 1' |
低音: 1,, - - - | 5,, - - - |''');
      expect(s.measures.length, 2);
      expect(s.measures[1].items.length, 4);
      expect(s.measures[1].items2.length, 1);
      final ki = s.key;
      expect(notePitches(s.measures[1].items2.first as NoteItem, ki).first.midi, 43); // 5,,
    });

    test('大谱表能回写成两段带前缀的简谱并往返一致', () {
      final s = parseJianpu(text);
      final out = toJianpu(s);
      expect(out, contains('高音:'));
      expect(out, contains('低音:'));
      final again = parseJianpu(out);
      expect(again.isGrandStaff, isTrue);
      expect(again.measures.length, s.measures.length);
      expect(again.measures.first.items.length, 4);
      expect(again.measures.first.items2.length, 1);
    });
  });

  group('MusicXML', () {
    test('单谱表输出不含 <staves>，保持原有结构', () {
      final xml = toMusicXML(parseJianpu('1=C 4/4\n1 2 3 4 |]'));
      expect(xml, isNot(contains('<staves>')));
      expect(xml, isNot(contains('<chord/>')));
      expect(RegExp(r'<measure ').allMatches(xml).length, 1);
    });

    test('和弦写成 <chord/> 的多个 note', () {
      final xml = toMusicXML(parseJianpu('1=C 4/4\n[1 3 5] 0 0 0 |]'));
      expect(RegExp(r'<chord/>').allMatches(xml).length, 2, reason: '三音和弦应有 2 个附加音');
      expect(RegExp(r'<note[ >]').allMatches(xml).length, 6, reason: '3 个和弦音 + 3 个休止');
    });

    test('大谱表写出两行谱表、两个谱号与 backup', () {
      final xml = toMusicXML(parseJianpu('''1=C 4/4
高音: 1 2 3 4 |
低音: 1,, - - - |'''));
      expect(xml, contains('<staves>2</staves>'));
      expect(xml, contains('<clef number="1"><sign>G</sign><line>2</line></clef>'));
      expect(xml, contains('<clef number="2"><sign>F</sign><line>4</line></clef>'));
      expect(xml, contains('<backup>'));
      expect(xml, contains('<staff>2</staff>'));
      expect(RegExp(r'<voice>2</voice>').allMatches(xml).length, 1);
      expect(RegExp(r'<measure ').allMatches(xml).length, 1);
    });
  });

  group('MIDI 与试听', () {
    test('和弦同时发声：三个音在同一 tick note on', () {
      final score = parseJianpu('1=C 4/4\n[1 3 5] 0 0 0 |]');
      final events = midiNoteEvents(toMidi(score));
      final ons = events.where((e) => e.$3).toList();
      expect(ons.length, 3);
      expect(ons.map((e) => e.$2).toList(), [60, 64, 67]);
      expect(ons.map((e) => e.$1).toSet().length, 1, reason: '三个音应在同一 tick 起音');
    });

    test('大谱表两个声部的音都在 MIDI 里', () {
      final score = parseJianpu('''1=C 4/4
高音: 1 2 3 4 |
低音: 1,, - - - |''');
      final ons = midiNoteEvents(toMidi(score)).where((e) => e.$3).map((e) => e.$2).toList();
      expect(ons, contains(60)); // 高音 1
      expect(ons, contains(36)); // 低音 1,,
    });

    test('合成器会为和弦与低音声部一起出声（按频谱验证具体音高）', () {
      // 同样的高音旋律，一份加和弦+低音声部，一份只有单声部
      final rich = parseJianpu('''1=C 4/4 ♩=96
高音: [1 3 5] [4 6 1'] [5 7 2'] [1 3 5] |
低音: 1,, - - - |''');
      final plain = parseJianpu("1=C 4/4 ♩=96\n1 4 5 1' |]");
      final richSamples = toMono(decodeWav(synthesizeWav(rich, sampleRate: 22050)));
      final plainSamples = toMono(decodeWav(synthesizeWav(plain, sampleRate: 22050)));
      expect(richSamples.length, plainSamples.length, reason: '同样的时长');

      // Goertzel：量某个频率上的能量
      double energy(Float64List x, double freq) {
        const sr = 22050;
        final start = (0.05 * sr).round();
        final n = (0.4 * sr).round();
        final w = 2 * math.pi * freq / sr;
        final c = 2 * math.cos(w);
        var s1 = 0.0, s2 = 0.0;
        for (var i = 0; i < n; i++) {
          final s0 = x[start + i] + c * s1 - s2;
          s2 = s1;
          s1 = s0;
        }
        return math.sqrt((s1 * s1 + s2 * s2 - c * s1 * s2).abs()) / n;
      }

      const c2 = 65.41; // 低音 1,,（MIDI 36）
      const e4 = 329.63; // 和弦三音 3（MIDI 64）
      const g4 = 392.00; // 和弦五音 5（MIDI 67）
      // 单声部那份第一个音是 1（C4 261.63），它的泛音里没有 65.41/329.63/392
      for (final f in [c2, e4, g4]) {
        expect(energy(richSamples, f), greaterThan(energy(plainSamples, f) * 3),
            reason: '${f}Hz 上应当只有和弦/低音版本才有能量');
      }
    });
  });

  group('扒谱结果 -> 大谱表', () {
    MelodyAnalysis analysisOf(List<(double, double, int)> notes, {double bpm = 120, String key = 'C'}) {
      final ds = [
        for (final n in notes)
          DetectedNote(startSec: n.$1, endSec: n.$2, midi: n.$3.toDouble(), confidence: 0.8),
      ];
      return MelodyAnalysis(
        notes: ds,
        track: const [],
        sampleRate: 22050,
        durationSec: 8,
        bpm: bpm,
        keyName: key,
        mode: 'major',
        hopSec: 0.02,
        mixMode: true,
      );
    }

    test('按音高拆成右手高音谱 + 左手低音谱，同时发声合成和弦', () {
      final a = analysisOf([
        (0.0, 0.5, 60), (0.0, 0.5, 64), (0.0, 0.5, 67), // 右手：C4 E4 G4 和弦
        (0.5, 1.0, 62), // 右手：D4
        (0.0, 1.0, 48), // 左手：C3 长音
      ]);
      final r = quantizeToGrandStaff(
        a,
        options: const QuantizeOptions(grid: 0.25, keepRests: true),
        splitMidi: 60,
      );
      final score = r.score;
      expect(score.isGrandStaff, isTrue);
      expect(score.meta.clef, 'grand');

      final upper = score.measures.first.items.whereType<NoteItem>().toList();
      expect(upper, isNotEmpty);
      expect(upper.first.chord.length, 2, reason: 'C4 E4 G4 应合成一个三音和弦');
      expect(notePitches(upper.first, score.key).map((p) => p.midi).toList(), [60, 64, 67]);

      final lower = score.measures.first.items2.whereType<NoteItem>().toList();
      expect(lower, isNotEmpty);
      expect(notePitches(lower.first, score.key).first.midi, 48);

      // 简谱文本带两个声部前缀，且能往返
      expect(r.jianpu, contains('高音:'));
      expect(r.jianpu, contains('低音:'));
      final again = parseJianpu(r.jianpu);
      expect(again.isGrandStaff, isTrue);
      expect(again.pitchCount, greaterThanOrEqualTo(5));
      // 和弦也要保留
      final againChord = again.measures.first.items.whereType<NoteItem>().firstWhere((n) => n.isChord);
      expect(notePitches(againChord, again.key).length, 3);
    });

    test('不同时刻起音的音不会并成和弦', () {
      final a = analysisOf([(0.0, 0.25, 60), (0.25, 0.5, 64)]);
      final r = quantizeToGrandStaff(a, options: const QuantizeOptions(grid: 0.25), splitMidi: 55);
      final notes = r.score.measures.first.items.whereType<NoteItem>().toList();
      expect(notes.length, 2);
      expect(notes.every((n) => !n.isChord), isTrue);
    });

    test('自动分界音取音高中位数并夹在 C3~E4', () {
      expect(suggestSplitMidi([for (var m = 40; m < 80; m++) DetectedNote(startSec: 0, endSec: 1, midi: m.toDouble(), confidence: 1)]), 60);
      expect(suggestSplitMidi([for (var m = 30; m < 50; m++) DetectedNote(startSec: 0, endSec: 1, midi: m.toDouble(), confidence: 1)]), 48);
      expect(suggestSplitMidi([for (var m = 70; m < 90; m++) DetectedNote(startSec: 0, endSec: 1, midi: m.toDouble(), confidence: 1)]), 64);
    });

    test('只有单一声部时给出提示', () {
      final a = analysisOf([(0.0, 0.5, 72), (0.5, 1.0, 74)]);
      final r = quantizeToGrandStaff(a, options: const QuantizeOptions(grid: 0.25), splitMidi: 60);
      expect(r.warnings.join(), contains('单谱表'));
    });

    test('曲谱标题跟随输入曲子的名字', () {
      final a = analysisOf([(0.0, 0.5, 60), (0.5, 1.0, 62)]);
      final named = quantizeToGrandStaff(
        a,
        options: const QuantizeOptions(title: '春风吹'),
        splitMidi: 60,
      );
      expect(named.score.meta.title, '春风吹');
      expect(named.jianpu, contains('标题：春风吹'), reason: '简谱文本里也要带上标题');

      // 没给标题时退回默认名
      final fallback = quantizeToGrandStaff(a, options: const QuantizeOptions(), splitMidi: 60);
      expect(fallback.score.meta.title, contains('扒谱'));

      // 单谱表路径同样生效
      final single = quantizeToScore(a, options: const QuantizeOptions(title: '茉莉花'));
      expect(single.score.meta.title, '茉莉花');
    });

    test('大谱表能导出 MusicXML / MIDI', () {
      final a = analysisOf([
        (0.0, 0.5, 60), (0.0, 0.5, 64), (0.0, 0.5, 67),
        (0.5, 1.0, 62),
        (0.0, 1.0, 48),
      ]);
      final score = quantizeToGrandStaff(a, options: const QuantizeOptions(grid: 0.25), splitMidi: 60).score;
      final xml = toMusicXML(score);
      expect(xml, contains('<staves>2</staves>'));
      expect(xml, contains('<chord/>'));
      expect(xml, contains('<backup>'));
      final ons = midiNoteEvents(toMidi(score)).where((e) => e.$3).map((e) => e.$2).toSet();
      expect(ons, containsAll([48, 60, 64, 67]));
    });
  });
}
