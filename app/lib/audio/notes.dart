/// 从乐谱收集"绝对时间"的音符列表（延音线合并、和弦展开），
/// 供各种发声方式（采样播放 / 合成器）共用。
library;

import '../core/model.dart';

/// 一个已经确定起止时间的音（单位：拍）
class TimedNote {
  final double start;
  final double duration;
  final int midi;

  const TimedNote(this.start, this.duration, this.midi);
}

/// 收集所有要发声的音（大谱表两个声部一起），时间单位是"拍"。
///
/// 说明：
///   - 延音线（tieToNext）会把两个音合并成一个长音；
///   - 和弦的每个音分别发声；
///   - 休止符只推进时间，不发声。
List<TimedNote> collectNotes(Score score) {
  final ki = score.key;
  final out = <TimedNote>[];
  final voices = <List<Item>>[
    score.measures.expand((m) => m.items).toList(),
    if (score.isGrandStaff) score.measures.expand((m) => m.items2).toList(),
  ];
  for (final items in voices) {
    var tick = 0.0;
    // 同一时刻可能有多条延音链（和弦），按音高分别跟踪
    final openStart = <int, double>{};
    for (final item in items) {
      if (item is NoteItem) {
        final pitches = notePitches(item, ki).map((p) => p.midi).toSet();
        for (final midi in pitches) {
          if (!item.tieToPrev || !openStart.containsKey(midi)) {
            if (openStart.containsKey(midi)) {
              out.add(TimedNote(openStart[midi]!, tick - openStart[midi]!, midi));
            }
            openStart[midi] = tick;
          }
          if (!item.tieToNext) {
            out.add(TimedNote(openStart[midi]!, tick + item.ticks - openStart[midi]!, midi));
            openStart.remove(midi);
          }
        }
        // 和弦音数变化时收掉没续上的音
        for (final midi in openStart.keys.toList()) {
          if (!pitches.contains(midi)) {
            out.add(TimedNote(openStart[midi]!, tick - openStart[midi]!, midi));
            openStart.remove(midi);
          }
        }
      } else {
        for (final midi in openStart.keys.toList()) {
          out.add(TimedNote(openStart[midi]!, tick - openStart[midi]!, midi));
          openStart.remove(midi);
        }
      }
      tick += item.ticks;
    }
    for (final midi in openStart.keys.toList()) {
      out.add(TimedNote(openStart[midi]!, tick - openStart[midi]!, midi));
    }
  }
  return out;
}

/// 一个音在乐谱时间轴上的起止（秒）
class TimedNoteSeconds {
  final double start;
  final double duration;
  final int midi;

  const TimedNoteSeconds(this.start, this.duration, this.midi);
}

/// 把拍换算成秒（速度来自乐谱元数据）
double secondsPerTick(Score score) => 60.0 / (score.meta.tempo <= 0 ? 96 : score.meta.tempo);

/// 收集以"秒"为单位的音符（已按开始时间排序）
List<TimedNoteSeconds> collectNotesSeconds(Score score) {
  final spt = secondsPerTick(score);
  final list = collectNotes(score)
      .map((n) => TimedNoteSeconds(n.start * spt, n.duration * spt, n.midi))
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  return list;
}
