/// 乐谱 -> MusicXML 4.0（partwise），可被 MuseScore / Finale / Sibelius 直接打开
library;

import 'model.dart';

const int kDivisions = 16; // 每个四分音符 16 个 duration 单位

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 强拍分组长度：谱面上不允许随意跨越的边界
double groupTicksFor(int beats, int beatType) {
  final beat = 4 / beatType;
  if (beats % 3 == 0 && beats > 3) return beat * 3; // 6/8 9/8 12/8
  if (beats >= 4 && beats % 2 == 0) return beat * 2; // 4/4 6/4
  return beat * beats; // 2/4 3/4
}

/// 内部时值代号 -> MusicXML 的 note-type 值。
///
/// 内部沿用 'w'/'h'/'q'/'8'/'16'/'32'/'64' 这种简写，但 MusicXML 的
/// `<type>` 必须是 whole/half/quarter/eighth/16th/32nd/64th —— 之前直接写
/// 简写，MuseScore 能忍，**Verovio 会直接报 "Unsupported note-type-value 'q'"**。
String musicXmlNoteType(String type) {
  switch (type) {
    case 'w':
      return 'whole';
    case 'h':
      return 'half';
    case 'q':
      return 'quarter';
    case '8':
      return 'eighth';
    case '16':
      return '16th';
    case '32':
      return '32nd';
    case '64':
      return '64th';
    default:
      return 'quarter';
  }
}

String toMusicXML(Score score, {String software = '离谱', bool padIncompleteMeasures = false, bool includeLyrics = true}) {
  final meta = score.meta;
  final ki = score.key;
  final beatTicks = 4 / meta.beatType;
  final groupTicks = groupTicksFor(meta.beats, meta.beatType);
  final cap = measureTicksOf(meta.beats, meta.beatType);

  final sb = StringBuffer();
  sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  sb.writeln('<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">');
  sb.writeln('<score-partwise version="4.0">');
  if (meta.title.isNotEmpty) {
    sb.writeln('  <work><work-title>${_esc(meta.title)}</work-title></work>');
  }
  sb.writeln('  <identification>');
  if (meta.composer.isNotEmpty) sb.writeln('    <creator type="composer">${_esc(meta.composer)}</creator>');
  if (meta.lyricist.isNotEmpty) sb.writeln('    <creator type="lyricist">${_esc(meta.lyricist)}</creator>');
  sb.writeln('    <encoding><software>$software</software><encoding-date>${DateTime.now().toIso8601String().split('T').first}</encoding-date></encoding>');
  sb.writeln('  </identification>');
  sb.writeln('  <part-list>');
  // 大谱表按钢琴谱命名，单行就是一条旋律线
  final partName = score.isGrandStaff ? '钢琴' : '旋律';
  sb.writeln('    <score-part id="P1"><part-name>$partName</part-name><score-instrument id="P1-I1"><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id="P1-I1"><midi-channel>1</midi-channel><midi-program>1</midi-program></midi-instrument></score-part>');
  sb.writeln('  </part-list>');
  sb.writeln('  <part id="P1">');

  for (var mi = 0; mi < score.measures.length; mi++) {
    final measure = score.measures[mi];
    final isFirst = mi == 0;
    final grand = score.isGrandStaff;
    final implicitPickup = isFirst && measure.filled > 0 && measure.filled < cap - kEps;
    sb.writeln('    <measure number="${mi + 1}"${implicitPickup ? ' implicit="yes"' : ''}>');

    if (measure.repeatStart) {
      sb.writeln('      <barline location="left"><bar-style>heavy-light</bar-style><repeat direction="forward"/></barline>');
    }

    if (isFirst) {
      sb.writeln('      <attributes>');
      sb.writeln('        <divisions>$kDivisions</divisions>');
      sb.writeln('        <key><fifths>${ki.fifths}</fifths><mode>${meta.mode}</mode></key>');
      sb.writeln('        <time><beats>${meta.beats}</beats><beat-type>${meta.beatType}</beat-type></time>');
      if (grand) {
        // 大谱表：高音谱 + 低音谱两行
        sb.writeln('        <staves>2</staves>');
        sb.writeln('        <clef number="1"><sign>G</sign><line>2</line></clef>');
        sb.writeln('        <clef number="2"><sign>F</sign><line>4</line></clef>');
      } else {
        sb.writeln('        <clef><sign>${meta.clef == 'bass' ? 'F' : 'G'}</sign><line>${meta.clef == 'bass' ? 4 : 2}</line></clef>');
      }
      sb.writeln('      </attributes>');
      sb.writeln('      <direction placement="above"><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>${meta.tempo}</per-minute></metronome></direction-type><sound tempo="${meta.tempo}"/></direction>');
    }

    /// 写出一个声部，返回写出的总时值（ticks）
    ///
    /// 每个 `<note>` 都带上我们自己的 `id`（`lipu-小节-声部-条目-音-片段`）：
    /// Verovio 会把它原样放到 SVG 的 `<g id="...">` 上，界面上拖音符时就能
    /// 直接把 SVG 元素映射回乐谱模型（见 `verovio_view.dart` 的交互脚本）。
    double emitVoice(List<Item> items, int voice, int staff) {
      var offset = 0.0;
      for (var itemIdx = 0; itemIdx < items.length; itemIdx++) {
        final item = items[itemIdx];
        final segments = notateTicks(item.ticks, offset, beatTicks, groupTicks);
        for (var si = 0; si < segments.length; si++) {
          final seg = segments[si];
          final isLastSeg = si == segments.length - 1;
          if (item is NoteItem) {
            // 和弦：最低音先写，其余音带 <chord/> 跟在同一时值上
            final pitches = notePitches(item, ki);
            for (var pi = 0; pi < pitches.length; pi++) {
              final pitch = pitches[pi];
              // 连音线有两个来源：① 时值被切成多段（必须连起来唱）；
              // ② 用户手动加的"连音"（item.tieToNext）。两个都要写进 MusicXML，
              // 否则手动连音在谱面上根本画不出来。
              final tieStart = seg.tieToNext || (isLastSeg && item.tieToNext);
              final tieStop = si > 0 || item.tieToPrev;
              // 圆滑线：音高不同/不相邻时用它（连音线在那种情况下排不出来）
              final slurStart = isLastSeg && item.slurToNext;
              final slurStop = si == 0 && item.slurToPrev;
              final nid = 'lipu-$mi-$voice-$itemIdx-$pi-$si';
              sb.writeln('      <note id="$nid">');
              if (pi > 0) sb.writeln('        <chord/>');
              if (tieStop) sb.writeln('        <tie type="stop"/>');
              if (tieStart) sb.writeln('        <tie type="start"/>');
              sb.writeln('        <pitch><step>${pitch.letter}</step><alter>${pitch.alter}</alter><octave>${pitch.octave}</octave></pitch>');
              sb.writeln('        <duration>${(seg.ticks * kDivisions).round()}</duration>');
              if (si == 0 && !item.tieToPrev) {
                final acc = _accidentalToDisplay(pitch.letter, pitch.alter, ki);
                if (acc != null) sb.writeln('        <accidental>$acc</accidental>');
              }
              sb.writeln('        <voice>$voice</voice>');
              sb.writeln('        <type>${musicXmlNoteType(seg.type)}</type>');
              for (var d = 0; d < seg.dots; d++) {
                sb.writeln('        <dot/>');
              }
              if (grand) sb.writeln('        <staff>$staff</staff>');
              if (tieStart || tieStop || slurStart || slurStop) {
                sb.writeln('        <notations>');
                if (tieStop) sb.writeln('          <tied type="stop"/>');
                if (tieStart) sb.writeln('          <tied type="start"/>');
                if (slurStop) sb.writeln('          <slur type="stop" number="1"/>');
                if (slurStart) sb.writeln('          <slur type="start" number="1"/>');
                sb.writeln('        </notations>');
              }
              if (includeLyrics && pi == 0 && isLastSeg && item.lyric != null && item.lyric!.isNotEmpty) {
                sb.writeln('        <lyric number="1"><syllable><text>${_esc(item.lyric!)}</text></syllable></lyric>');
              }
              sb.writeln('      </note>');
            }
          } else {
            sb.writeln('      <note>');
            sb.writeln('        <rest/>');
            sb.writeln('        <duration>${(seg.ticks * kDivisions).round()}</duration>');
            sb.writeln('        <voice>$voice</voice>');
            sb.writeln('        <type>${musicXmlNoteType(seg.type)}</type>');
            for (var d = 0; d < seg.dots; d++) {
              sb.writeln('        <dot/>');
            }
            if (grand) sb.writeln('        <staff>$staff</staff>');
            sb.writeln('      </note>');
          }
        }
        offset += item.ticks;
      }
      return offset;
    }

    void padTo(double from, int voice, int staff) {
      if (!padIncompleteMeasures || from >= cap - kEps) return;
      final need = cap - from;
      final seg = ticksToType(need);
      if (seg == null) return;
      sb.writeln('      <note><rest/><duration>${(need * kDivisions).round()}</duration>'
          '<voice>$voice</voice><type>${musicXmlNoteType(seg.type)}</type><staff>$staff</staff></note>');
    }

    final emitted1 = emitVoice(measure.items, 1, 1);
    if (padIncompleteMeasures) {
      padTo(emitted1, 1, 1);
    }
    if (grand) {
      // 回到本小节开头再写第二行谱表
      final back = padIncompleteMeasures ? cap : emitted1;
      sb.writeln('      <backup><duration>${(back * kDivisions).round()}</duration></backup>');
      final emitted2 = emitVoice(measure.items2, 2, 2);
      if (padIncompleteMeasures) {
        padTo(emitted2, 2, 2);
      }
    }

    if (measure.repeatEnd || measure.isFinal) {
      sb.writeln('      <barline location="right"><bar-style>light-heavy</bar-style>${measure.repeatEnd ? '<repeat direction="backward"/>' : ''}</barline>');
    }
    sb.writeln('    </measure>');
  }

  sb.writeln('  </part>');
  sb.writeln('</score-partwise>');
  return sb.toString();
}

/// 调号已经隐含的升降号不再重复书写
String? _accidentalToDisplay(String letter, int alter, KeyInfo ki) {
  final implied = _impliedAlter(letter, ki);
  if (alter == implied) return null;
  if (alter > 0) return 'sharp';
  if (alter < 0) return 'flat';
  return 'natural';
}

int _impliedAlter(String letter, KeyInfo ki) {
  const sharpOrder = ['F', 'C', 'G', 'D', 'A', 'E', 'B'];
  const flatOrder = ['B', 'E', 'A', 'D', 'G', 'C', 'F'];
  final n = ki.fifths;
  if (n > 0 && sharpOrder.take(n).contains(letter)) return 1;
  if (n < 0 && flatOrder.take(-n).contains(letter)) return -1;
  return 0;
}
