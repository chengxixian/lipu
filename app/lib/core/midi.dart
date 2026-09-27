/// 乐谱 -> 标准 MIDI 文件（SMF format 0，单轨）
library;

import 'dart:typed_data';

import 'model.dart';

const int kTicksPerQuarter = 480;

/// 把 tick 时值（四分音符 = 1）换算成 MIDI tick
int toMidiTicks(double ticks) => (ticks * kTicksPerQuarter).round();

/// MIDI 可变长量编码
Uint8List encodeVlq(int value) {
  var v = value < 0 ? 0 : value;
  final bytes = <int>[v & 0x7F];
  v >>= 7;
  while (v > 0) {
    bytes.insert(0, (v & 0x7F) | 0x80);
    v >>= 7;
  }
  return Uint8List.fromList(bytes);
}

class _Event {
  final int tick;
  final int order; // 同 tick 时：0 = note off / meta，1 = note on
  final Uint8List data;
  final int seq;
  _Event(this.tick, this.order, this.data, this.seq);
}

/// 生成 MIDI 文件字节
Uint8List toMidi(Score score, {int program = 0, int velocity = 100, int channel = 0}) {
  final events = <_Event>[];
  final ki = score.key;

  var seq = 0;

  void noteOn(int tick, int midi) =>
      events.add(_Event(tick, 1, Uint8List.fromList([0x90 | channel, midi & 0x7F, velocity & 0x7F]), seq++));
  void noteOff(int atTick, int midi) =>
      events.add(_Event(atTick, 0, Uint8List.fromList([0x80 | channel, midi & 0x7F, 0x40]), seq++));

  /// 走一个声部；大谱表的第二声部与第一声部时间轴相同，各自用自己的游标。
  /// 和弦：一个 NoteItem 上的所有音高同时 note on / note off。
  void walk(List<Item> items) {
    var tick = 0;
    final open = <int>{};
    for (final item in items) {
      final dur = toMidiTicks(item.ticks);
      if (item is NoteItem) {
        final pitches = notePitches(item, ki).map((p) => p.midi).toSet();
        for (final midi in pitches) {
          if (!item.tieToPrev || !open.contains(midi)) noteOn(tick, midi);
          if (item.tieToNext) {
            open.add(midi);
          } else {
            noteOff(tick + dur, midi);
            open.remove(midi);
          }
        }
        // 本音符没包含、却还挂着的音（和弦音数变化）就地收掉
        for (final midi in open.toList()) {
          if (!pitches.contains(midi)) {
            noteOff(tick, midi);
            open.remove(midi);
          }
        }
      } else {
        for (final midi in open.toList()) {
          noteOff(tick, midi);
          open.remove(midi);
        }
      }
      tick += dur;
    }
    for (final midi in open.toList()) {
      noteOff(tick, midi);
    }
  }

  walk(score.measures.expand((m) => m.items).toList());
  if (score.isGrandStaff) {
    walk(score.measures.expand((m) => m.items2).toList());
  }

  events.sort((a, b) {
    final c = a.tick.compareTo(b.tick);
    if (c != 0) return c;
    final o = a.order.compareTo(b.order);
    if (o != 0) return o;
    return a.seq.compareTo(b.seq);
  });

  final builder = BytesBuilder();
  final track = BytesBuilder();
  // 轨道名
  _metaText(track, 0x03, 'Lipu');
  // 速度
  final usPerQuarter = (60000000 / (score.meta.tempo <= 0 ? 96 : score.meta.tempo)).round();
  track.add([0x00, 0xFF, 0x51, 0x03,
    (usPerQuarter >> 16) & 0xFF, (usPerQuarter >> 8) & 0xFF, usPerQuarter & 0xFF]);
  // 拍号
  var beatPow = 0;
  var bt = score.meta.beatType;
  while (bt > 1) {
    bt ~/= 2;
    beatPow++;
  }
  track.add([0x00, 0xFF, 0x58, 0x04, score.meta.beats & 0xFF, beatPow & 0xFF, 24, 8]);
  // 调号
  final fifths = ki.fifths;
  track.add([0x00, 0xFF, 0x59, 0x02, fifths & 0xFF, ki.mode == 'minor' ? 1 : 0]);
  // 音色
  track.add([0x00, 0xC0 | channel, program & 0x7F]);

  var lastTick = 0;
  for (final e in events) {
    final delta = e.tick - lastTick;
    track.add(encodeVlq(delta < 0 ? 0 : delta));
    track.add(e.data);
    lastTick = e.tick;
  }
  track.add([0x00, 0xFF, 0x2F, 0x00]); // end of track

  final trackBytes = track.toBytes();
  // MThd
  builder.add([0x4D, 0x54, 0x68, 0x64]); // MThd
  builder.add(_be32(6));
  builder.add(_be16(0)); // format 0
  builder.add(_be16(1)); // 1 track
  builder.add(_be16(kTicksPerQuarter));
  // MTrk
  builder.add([0x4D, 0x54, 0x72, 0x6B]); // MTrk
  builder.add(_be32(trackBytes.length));
  builder.add(trackBytes);
  return builder.toBytes();
}

void _metaText(BytesBuilder b, int type, String text) {
  final bytes = Uint8List.fromList(text.codeUnits.take(127).toList());
  b.add(encodeVlq(0));
  b.add([0xFF, type, bytes.length]);
  b.add(bytes);
}

Uint8List _be32(int v) => Uint8List.fromList([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
Uint8List _be16(int v) => Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF]);
