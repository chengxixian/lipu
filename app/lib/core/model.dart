/// 统一乐谱模型（Score IR）+ 音高 / 时值工具
///
/// 时值单位约定：四分音符 = 1.0 tick。
///
/// `Score` = `ScoreMeta` + `List<Measure>`
/// `Measure` = `List<Item>` + 反复 / 终止标记
/// `Item` = `NoteItem` | `RestItem`
library;

import 'dart:math' as math;

const List<String> kLetters = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
const List<int> kNaturalPc = [0, 2, 4, 5, 7, 9, 11];
const List<int> kMajorSteps = [0, 2, 4, 5, 7, 9, 11];
const List<int> kMinorSteps = [0, 2, 3, 5, 7, 8, 10];

/// 中音区（简谱不带点）的基准八度：1 = C4 = MIDI 60
const int kMidiBase = 60;
const int kOctave = 12;
const double kEps = 1e-6;

int accidentalOffset(String a) {
  switch (a) {
    case '#':
    case '♯':
      return 1;
    case 'b':
    case '♭':
      return -1;
    default:
      return 0;
  }
}

String normalizeAccidental(String a) {
  switch (a) {
    case '♯':
      return '#';
    case '♭':
      return 'b';
    case '♮':
      return 'n';
    default:
      return a;
  }
}

/* ------------------------------------------------------------------ *
 * 调号
 * ------------------------------------------------------------------ */

class KeySpec {
  final String letter;
  final int alter;
  final String mode; // 'major' | 'minor'
  const KeySpec(this.letter, this.alter, this.mode);

  String get text =>
      letter + (alter > 0 ? '#' * alter : alter < 0 ? 'b' * (-alter) : '') + (mode == 'minor' ? 'm' : '');

  @override
  String toString() => text;
}

/// 解析调号写法：C / #F / F# / bB / Bb / ♯F / ♭B / Am / a小调 / C大调
KeySpec parseKeySpec(String? raw) {
  var s = (raw ?? 'C').trim();
  if (s.isEmpty) s = 'C';
  String? mode;
  if (RegExp(r'小调|minor|min').hasMatch(s)) mode = 'minor';
  if (RegExp(r'大调|major|maj').hasMatch(s)) mode = 'major';
  s = s.replaceAll(RegExp(r'小调|大调|minor|major|maj|min', caseSensitive: false), '').trim();
  // 末尾单独的 m，如 Am
  if (RegExp(r'^[A-Ga-g][#b♯♭]?m$').hasMatch(s)) {
    mode = 'minor';
    s = s.substring(0, s.length - 1);
  }
  s = s.replaceAll(RegExp(r'\s+'), '');
  var alter = 0;
  if (s.startsWith('#')) {
    alter += 1;
    s = s.substring(1);
  }
  if (s.startsWith('♯')) {
    alter += 1;
    s = s.substring(1);
  }
  if (s.startsWith('b') && s.length > 1) {
    alter -= 1;
    s = s.substring(1);
  }
  if (s.startsWith('♭')) {
    alter -= 1;
    s = s.substring(1);
  }
  final m = RegExp(r'^([A-Ga-g])([#b♯♭]?)$').firstMatch(s);
  if (m != null) {
    final letter = m.group(1)!.toUpperCase();
    final acc = m.group(2)!;
    if (acc == '#' || acc == '♯') alter += 1;
    if (acc == 'b' || acc == '♭') alter -= 1;
    return KeySpec(letter, alter, mode ?? 'major');
  }
  // 简谱 1=x / 6=A 形式
  final m2 = RegExp(r'^([1-7])\s*=\s*(.+)$').firstMatch(s);
  if (m2 != null) {
    final inner = parseKeySpec(m2.group(2));
    return KeySpec(inner.letter, inner.alter, m2.group(1) == '6' ? 'minor' : inner.mode);
  }
  return KeySpec('C', 0, mode ?? 'major');
}

/// 调号 -> 升降号数量（正 = 升号，负 = 降号）
const Map<int, int> _ksMajor = {
  0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6,
  1: -5, 10: -2, 3: -3, 8: -4, 5: -1,
};
/// 小调调号（按同主音异名的常用写法取整：D#m 记作 Ebm，A#m 记作 Bbm）
const Map<int, int> _ksMinor = {
  9: 0, 4: 1, 11: 2, 6: 3, 1: 4, 8: 5,
  3: -6, 10: -5, 2: -1, 7: -2, 0: -3, 5: -4,
};

class KeyInfo {
  final String letter;
  final int letterIdx;
  final int alter;
  final String mode;
  final int tonicPc;
  final int tonicMidi;
  final List<int> steps;
  final int keySignature;
  final String display;

  const KeyInfo({
    required this.letter,
    required this.letterIdx,
    required this.alter,
    required this.mode,
    required this.tonicPc,
    required this.tonicMidi,
    required this.steps,
    required this.keySignature,
    required this.display,
  });

  /// VexFlow / 通用调号名：C、G、F、Bb、Am …
  String get keyName => display;

  /// MusicXML 的 `<fifths>` 值（正 = 升号数，负 = 降号数）
  int get fifths => keySignature;
}

KeyInfo keyInfoOf(Object? spec) {
  final s = spec is KeySpec ? spec : parseKeySpec(spec is String ? spec : null);
  final letterIdx = math.max(0, kLetters.indexOf(s.letter));
  final tonicPc = ((kNaturalPc[letterIdx] + s.alter) % 12 + 12) % 12;
  final int ks;
  if (s.mode == 'minor') {
    ks = _ksMinor[tonicPc] ?? 0;
  } else {
    ks = _ksMajor[tonicPc] ?? 0;
  }
  final display = s.letter +
      (s.alter > 0 ? '#' * s.alter : s.alter < 0 ? 'b' * (-s.alter) : '') +
      (s.mode == 'minor' ? 'm' : '');
  return KeyInfo(
    letter: s.letter,
    letterIdx: letterIdx,
    alter: s.alter,
    mode: s.mode,
    tonicPc: tonicPc,
    tonicMidi: kMidiBase + tonicPc,
    steps: s.mode == 'minor' ? kMinorSteps : kMajorSteps,
    keySignature: ks,
    display: display,
  );
}

/* ------------------------------------------------------------------ *
 * 音高
 * ------------------------------------------------------------------ */

class Spelling {
  final String letter;
  final int alter;
  final int octave;
  final int midi;
  const Spelling(this.letter, this.alter, this.octave, this.midi);

  String get vexKey {
    final acc = alter > 0 ? '#' * alter : alter < 0 ? 'b' * (-alter) : '';
    return '${letter.toLowerCase()}$acc/$octave';
  }

  String get name => '$letter${alter > 0 ? '#' * alter : alter < 0 ? 'b' * (-alter) : ''}$octave';
}

/// 简谱音级 -> MIDI（degree 1..7，octave 为上/下加点个数，accidental 为 #/b/n）
int degreeToMidi(int degree, int octave, String accidental, KeyInfo ki) {
  final d = degree.clamp(1, 7);
  final off = ki.steps[d - 1] + accidentalOffset(accidental);
  return ki.tonicMidi + off + kOctave * octave;
}

/// MIDI -> 字母音名拼写（保持给定音级的字母，使调号内音符写法自然）
Spelling spellMidi(int midi, int letterIdx) {
  final idx = ((letterIdx % 7) + 7) % 7;
  final pc = kNaturalPc[idx];
  final octave = ((midi - pc - kOctave) / kOctave).round();
  final natural = kOctave * (octave + 1) + pc;
  return Spelling(kLetters[idx], midi - natural, octave, midi);
}

Spelling noteToPitch(NoteItem item, KeyInfo ki) {
  final letterIdx = ki.letterIdx + (item.degree - 1);
  final midi = degreeToMidi(item.degree, item.octave, item.accidental, ki);
  return spellMidi(midi, letterIdx);
}

/// 一个音符（含和弦音）的**全部音高**，按 MIDI 从低到高排序。
/// 单音时就是长度为 1 的列表。
List<Spelling> notePitches(NoteItem item, KeyInfo ki) {
  final out = <Spelling>[
    noteToPitch(item, ki),
    for (final t in item.chord)
      spellMidi(degreeToMidi(t.degree, t.octave, t.accidental, ki), ki.letterIdx + (t.degree - 1)),
  ];
  out.sort((a, b) => a.midi != b.midi ? a.midi.compareTo(b.midi) : a.alter.compareTo(b.alter));
  return out;
}

/// MIDI 音高 -> 简谱 (音级, 八度, 变音记号)
///
/// 在七个音级里挑"最接近"的那个：残余音数为 0 就不写变音记号，
/// 同代价时优先升号写法（#4 而不是 b5）。
(int, int, String) midiToDegree(int midi, KeyInfo ki) {
  int? bestDegree;
  int? bestOctave;
  var bestAccidental = '';
  var bestCost = 1 << 30;

  for (var d = 1; d <= 7; d++) {
    final base = ki.tonicMidi + ki.steps[d - 1];
    final octave = ((midi - base) / 12).round();
    final residual = midi - (base + 12 * octave);
    final cost = residual.abs();
    if (cost < bestCost) {
      bestCost = cost;
      bestDegree = d;
      bestOctave = octave;
      bestAccidental = residual == 0 ? '' : (residual > 0 ? '#' : 'b');
    } else if (cost == bestCost && residual > 0 && bestAccidental == 'b') {
      bestDegree = d;
      bestOctave = octave;
      bestAccidental = '#';
    }
  }
  return (bestDegree ?? 1, bestOctave ?? 0, bestAccidental);
}

/// NoteItem 的全部音（主音 + 和弦音），按音高从低到高排。
///
/// 界面上给每个符头的 id 里那个"音序号"就是这个排序里的下标，
/// 所以读/写单个符头都必须走这里，别自己去碰 [NoteItem.degree]——
/// 对和弦来说 degree 永远只是**最低**的那个音。
List<ChordTone> sortedTones(NoteItem item, KeyInfo ki) {
  final tones = <ChordTone>[
    ChordTone(degree: item.degree, octave: item.octave, accidental: item.accidental),
    ...item.chord.map((t) => t.clone()),
  ];
  tones.sort((a, b) => degreeToMidi(a.degree, a.octave, a.accidental, ki)
      .compareTo(degreeToMidi(b.degree, b.octave, b.accidental, ki)));
  return tones;
}

/// 取"从低到高第 [index] 个音"，越界返回 null
ChordTone? toneAt(NoteItem item, int index, KeyInfo ki) {
  final tones = sortedTones(item, ki);
  if (index < 0 || index >= tones.length) return null;
  return tones[index];
}

/// 把 NoteItem 里"从低到高第 [index] 个音"换成新的 (音级, 八度, 变音记号)。
///
/// 用于界面上直接拖某个符头改音高：和弦里的其它音不动，主音仍取最低音。
void replaceNoteTone(NoteItem item, int index, int degree, int octave, String accidental, KeyInfo ki) {
  final tones = sortedTones(item, ki);
  if (index < 0 || index >= tones.length) return;
  tones[index] = ChordTone(degree: degree, octave: octave, accidental: accidental);
  final lowest = tones.first;
  item.degree = lowest.degree;
  item.octave = lowest.octave;
  item.accidental = lowest.accidental;
  item.chord
    ..clear()
    ..addAll(tones.skip(1));
}

/// 把一组音高整理成 NoteItem 的"主音 + 和弦音"形式（主音取最低音）
void applyPitchesToNote(NoteItem item, List<ChordTone> tones, KeyInfo ki) {
  final all = <ChordTone>[
    ChordTone(degree: item.degree, octave: item.octave, accidental: item.accidental),
    ...tones.map((t) => t.clone()),
  ]..sort((a, b) => degreeToMidi(a.degree, a.octave, a.accidental, ki)
      .compareTo(degreeToMidi(b.degree, b.octave, b.accidental, ki)));
  final lowest = all.first;
  item.degree = lowest.degree;
  item.octave = lowest.octave;
  item.accidental = lowest.accidental;
  item.chord
    ..clear()
    ..addAll(all.skip(1));
}

/* ------------------------------------------------------------------ *
 * 时值
 * ------------------------------------------------------------------ */

class DurType {
  final double ticks;
  final String type;
  final int dots;
  const DurType(this.ticks, this.type, this.dots);
}

const List<DurType> kDurTable = [
  DurType(4, 'w', 0),
  DurType(3, 'h', 1),
  DurType(2, 'h', 0),
  DurType(1.5, 'q', 1),
  DurType(1, 'q', 0),
  DurType(0.75, '8', 1),
  DurType(0.5, '8', 0),
  DurType(0.375, '16', 1),
  DurType(0.25, '16', 0),
  DurType(0.1875, '32', 1),
  DurType(0.125, '32', 0),
  DurType(0.0625, '64', 0),
];

DurType? ticksToType(double ticks) {
  for (final d in kDurTable) {
    if ((d.ticks - ticks).abs() < kEps) return d;
  }
  return null;
}

DurType _largestFitting(double ticks) {
  for (final d in kDurTable) {
    if (d.ticks <= ticks + kEps) return d;
  }
  return kDurTable.last;
}

class NoteSegment {
  final double ticks;
  final String type;
  final int dots;
  final bool tieToNext;
  const NoteSegment(this.ticks, this.type, this.dots, this.tieToNext);
}

/// 把一段时间拆成规范可记谱的片段（必要时用延音线连接）
///
/// [startOffset] 为小节内起始位置，[beatTicks] 为一拍时值，
/// [groupTicks] 为“不可跨越的强拍分组”长度（4/4 为两拍，3/4 为整小节）。
List<NoteSegment> notateTicks(double ticks, double startOffset, double beatTicks, [double? groupTicks]) {
  final group = groupTicks ?? beatTicks * 2;
  final out = <NoteSegment>[];
  var remaining = ticks;
  var pos = startOffset;
  var guard = 0;
  while (remaining > kEps && guard++ < 64) {
    final groupStart = (pos / group).floor() * group;
    final groupEnd = groupStart + group;
    final startsAtZero = pos.abs() < kEps;
    final fitsGroup = pos + remaining <= groupEnd + kEps;
    final exact = ticksToType(remaining);
    var chunk = remaining;
    if (exact == null || !(startsAtZero || fitsGroup)) {
      final toGroupEnd = groupEnd - pos;
      if (toGroupEnd > kEps && toGroupEnd < remaining - kEps) {
        chunk = toGroupEnd;
      } else {
        chunk = _largestFitting(remaining).ticks;
      }
      // 若切出来的长度不可记谱，退到不超过它的最大可记谱值
      if (ticksToType(chunk) == null) chunk = _largestFitting(chunk).ticks;
    }
    final rep = ticksToType(chunk) ?? _largestFitting(chunk);
    out.add(NoteSegment(chunk, rep.type, rep.dots, remaining - chunk > kEps));
    pos += chunk;
    remaining -= chunk;
  }
  return out;
}

/// 小节容量（ticks）
double measureTicksOf(int beats, int beatType) => beats * (4 / beatType);

/* ------------------------------------------------------------------ *
 * 数据结构
 * ------------------------------------------------------------------ */

/// 识别来源信息（图片识别时携带，便于界面回显与人工校对）
class SrcInfo {
  final double confidence;
  final int x, y, w, h;
  final String? raw;
  const SrcInfo({this.confidence = 1.0, this.x = 0, this.y = 0, this.w = 0, this.h = 0, this.raw});
}

abstract class Item {
  double ticks;
  SrcInfo? src;
  Item(this.ticks, [this.src]);
}

/// 和弦里的附加音（与 [NoteItem] 的主音同时发声）
///
/// 约定：一个和弦的**主音是最低的那个音**（存在 [NoteItem] 自身），
/// 其余音按音高从低到高放在 [NoteItem.chord] 里。
class ChordTone {
  int degree; // 1..7
  int octave; // 上/下加点个数
  String accidental; // '' | '#' | 'b' | 'n'
  ChordTone({required this.degree, this.octave = 0, this.accidental = ''});

  ChordTone clone() => ChordTone(degree: degree, octave: octave, accidental: accidental);
}

class NoteItem extends Item {
  int degree;
  int octave;
  String accidental; // '' | '#' | 'b' | 'n'
  String? lyric;
  bool tieToPrev;
  bool tieToNext;

  /// 圆滑线（slur）：连两个**音高不同**（或不相邻）的音。
  ///
  /// 连音线（tie）只能连"同一个音高、且紧挨着"的两个音；音高不同时必须用
  /// 圆滑线，否则 MusicXML 里的 tie 是无效的，排版引擎**根本不会画**
  /// （用户反馈的"有的音符连音之后没有连音号"就是这个）。
  bool slurToPrev;
  bool slurToNext;

  /// 同时发声的其它音（从低到高，均高于主音）。为空即单音。
  final List<ChordTone> chord = [];

  NoteItem({
    required this.degree,
    this.octave = 0,
    this.accidental = '',
    double ticks = 1,
    this.lyric,
    this.tieToPrev = false,
    this.tieToNext = false,
    this.slurToPrev = false,
    this.slurToNext = false,
    SrcInfo? src,
  }) : super(ticks, src);

  bool get isChord => chord.isNotEmpty;
}

class RestItem extends Item {
  RestItem({double ticks = 1, SrcInfo? src}) : super(ticks, src);
}

class Measure {
  final List<Item> items = [];

  /// 第二声部（大谱表的下行 / 左手）。为空表示单谱表。
  final List<Item> items2 = [];
  bool repeatStart = false;
  bool repeatEnd = false;
  bool isFinal = false;

  double get filled => items.fold(0.0, (a, it) => a + it.ticks);
  double get filled2 => items2.fold(0.0, (a, it) => a + it.ticks);

  /// 本小节是否需要两行谱表
  bool get isGrand => items2.isNotEmpty;
}

class ScoreMeta {
  String title;
  String composer;
  String lyricist;
  String keyName;
  String mode;
  int beats;
  int beatType;
  int tempo;
  String clef; // 'treble' | 'bass' | 'auto'
  final List<String> warnings = [];

  ScoreMeta({
    this.title = '',
    this.composer = '',
    this.lyricist = '',
    this.keyName = 'C',
    this.mode = 'major',
    this.beats = 4,
    this.beatType = 4,
    this.tempo = 96,
    this.clef = 'auto',
  });
}

class Score {
  final ScoreMeta meta;
  final List<Measure> measures;
  Score(this.meta, this.measures);

  KeyInfo get key => keyInfoOf(meta.keyName);

  int get noteCount => measures.fold(
      0,
      (a, m) =>
          a +
          m.items.whereType<NoteItem>().length +
          m.items2.whereType<NoteItem>().length);

  /// 实际发声的音数（和弦按每个音算一次）
  int get pitchCount {
    final ki = key;
    var n = 0;
    for (final m in measures) {
      for (final it in [...m.items, ...m.items2]) {
        if (it is NoteItem) n += notePitches(it, ki).length;
      }
    }
    return n;
  }

  /// 是否大谱表（高音谱 + 低音谱两行）
  bool get isGrandStaff => meta.clef == 'grand' || measures.any((m) => m.isGrand);

  /// 出现在谱面上的最低 / 最高音（用于自动决定谱号）
  (int, int) midiRange() {
    final ki = key;
    var lo = 127, hi = 0;
    for (final m in measures) {
      for (final it in [...m.items, ...m.items2]) {
        if (it is! NoteItem) continue;
        for (final p in notePitches(it, ki)) {
          if (p.midi < lo) lo = p.midi;
          if (p.midi > hi) hi = p.midi;
        }
      }
    }
    return (lo, hi);
  }

  int get lowConfidenceCount => measures
      .expand((m) => [...m.items, ...m.items2])
      .where((it) => it.src != null && it.src!.confidence < 0.75)
      .length;
}
