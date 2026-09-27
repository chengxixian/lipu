/// 把扒出来的音符序列量化成乐谱：BPM/拍号/调和弦对齐 -> Score IR -> 简谱文本
///
/// 输出仍然是简谱文本，因此后续的解析、五线谱排版、MusicXML/MIDI 导出全部复用现有实现。
library;

import 'dart:math' as math;

import '../core/model.dart';
import '../core/parse.dart';
import 'melody.dart';

class QuantizeOptions {
  /// 速度（BPM），<=0 表示使用分析结果
  final double bpm;

  /// 拍号
  final int beats;
  final int beatType;

  /// 调号覆盖（如 "G"、"Am"、"F"）；null 表示用分析结果
  final String? keyName;

  /// 量化网格（以四分音符为单位），0.25 = 十六分音符
  final double grid;

  /// 是否保留休止符（保持节奏骨架）
  final bool keepRests;

  /// 小节起点对齐方式：true = 把第一个音对齐到强拍
  final bool alignToFirstNote;

  /// 乐谱标题（一般为输入曲子的名字）；null/空则用默认名
  final String? title;

  const QuantizeOptions({
    this.bpm = 0,
    this.beats = 4,
    this.beatType = 4,
    this.keyName,
    this.grid = 0.25,
    this.keepRests = true,
    this.alignToFirstNote = true,
    this.title,
  });

  QuantizeOptions copyWith({
    double? bpm,
    int? beats,
    int? beatType,
    String? keyName,
    double? grid,
    bool? keepRests,
    bool? alignToFirstNote,
    String? title,
  }) =>
      QuantizeOptions(
        bpm: bpm ?? this.bpm,
        beats: beats ?? this.beats,
        beatType: beatType ?? this.beatType,
        keyName: keyName ?? this.keyName,
        grid: grid ?? this.grid,
        keepRests: keepRests ?? this.keepRests,
        alignToFirstNote: alignToFirstNote ?? this.alignToFirstNote,
        title: title ?? this.title,
      );
}

class QuantizeResult {
  final Score score;
  final String jianpu;
  final double bpm;
  final String keyName;
  final String mode;
  final int beats;
  final int beatType;
  final List<String> warnings;

  const QuantizeResult({
    required this.score,
    required this.jianpu,
    required this.bpm,
    required this.keyName,
    required this.mode,
    required this.beats,
    required this.beatType,
    required this.warnings,
  });
}

/// 乐谱标题：优先用调用方给的（一般是输入曲子的文件名），否则退回默认名
String _titleOf(QuantizeOptions options, MelodyAnalysis analysis, {required bool grand}) {
  final custom = options.title?.trim();
  if (custom != null && custom.isNotEmpty) return custom;
  if (analysis.mixMode) return grand ? '扒谱结果（钢琴谱）' : '扒谱结果';
  return grand ? '哼唱记谱（钢琴谱）' : '哼唱记谱';
}

/// 速度精修：在估计值附近搜索让"起始点最贴合十六分网格"的速度。
///
/// 音乐速度绝大多数是整数，所以整数候选会被优先采用（并列时取更接近整数者）。
double refineTempo(List<DetectedNote> notes, double estimate, {double grid = 0.25}) {
  if (notes.isEmpty || estimate <= 0) return estimate;

  double error(double bpm) {
    final beat = 60.0 / bpm;
    var total = 0.0;
    for (final n in notes) {
      final beats = n.startSec / beat;
      final frac = beats - beats.floorToDouble();
      final snapped = (frac / grid).roundToDouble() * grid;
      final dev = (frac - snapped).abs();
      // 用长度加权：长音的位置更可信
      total += dev * dev * (0.2 + n.durationSec);
    }
    return total;
  }

  final candidates = <double>[];
  for (var b = estimate * 0.94; b <= estimate * 1.06; b += 0.1) {
    candidates.add(b);
  }
  for (var b = (estimate * 0.94).ceilToDouble(); b <= estimate * 1.06; b += 1.0) {
    candidates.add(b);
  }
  if (candidates.isEmpty) return estimate;

  var best = estimate;
  var bestErr = double.infinity;
  for (final b in candidates) {
    final e = error(b);
    // 整数速度给一点点偏好（并列时更"像人定的速度"）
    final isInteger = (b - b.roundToDouble()).abs() < 1e-6;
    final adjusted = isInteger ? e * 0.97 : e;
    if (adjusted < bestErr) {
      bestErr = adjusted;
      best = b;
    }
  }
  return best;
}

/// 主入口
QuantizeResult quantizeToScore(MelodyAnalysis analysis, {QuantizeOptions options = const QuantizeOptions()}) {
  final warnings = <String>[];
  final notes = analysis.activeNotes;
  if (notes.isEmpty) {
    final emptyMeasure = Measure()..isFinal = true;
    final score = Score(
      ScoreMeta(title: _titleOf(options, analysis, grand: false), beats: options.beats, beatType: options.beatType),
      [emptyMeasure],
    );
    return QuantizeResult(
      score: score,
      jianpu: '',
      bpm: options.bpm > 0 ? options.bpm : 0,
      keyName: 'C',
      mode: 'major',
      beats: options.beats,
      beatType: options.beatType,
      warnings: ['没有检测到任何音符'],
    );
  }

  // ---- 速度 ----
  var bpm = options.bpm > 0 ? options.bpm : (analysis.bpm > 0 ? analysis.bpm : 90.0);
  bpm = bpm.clamp(40.0, 220.0);
  if (options.bpm <= 0 && analysis.bpm > 0) {
    // 估计值常有 1%~3% 的偏差，累积到十几秒后就会让网格错位，
    // 因此在估计值附近做一次"网格对齐"精修
    bpm = refineTempo(notes, bpm);
  }
  if (analysis.bpm <= 0) warnings.add('未能可靠估计速度，已使用默认 ${bpm.round()} BPM，可在界面上手动调整');

  // ---- 调号 ----
  var keyName = options.keyName ?? analysis.keyName;
  if (keyName.trim().isEmpty) keyName = 'C';
  final ki = keyInfoOf(keyName);

  // ---- 时间 -> 拍 ----
  final secPerBeat = 60.0 / bpm;
  final firstOnset = notes.first.startSec;
  final offset = options.alignToFirstNote ? firstOnset : 0.0;

  int gridUnits(double sec) {
    final beats = (sec - offset) / secPerBeat;
    return (beats / options.grid).round();
  }

  // ---- 组装事件（先按网格单位，再转小节） ----
  final capBeats = options.beats * (4 / options.beatType);
  final events = <_Event>[];
  var cursorUnits = 0;

  for (final note in notes) {
    final startUnits = gridUnits(note.startSec);
    var endUnits = gridUnits(note.endSec);
    if (endUnits <= startUnits) endUnits = startUnits + 1;
    final start = math.max(startUnits, cursorUnits);
    if (start > cursorUnits && options.keepRests) {
      events.add(_Event.rest(start - cursorUnits));
    } else if (start > cursorUnits && !options.keepRests) {
      // 不保留休止符时把前一个音延长过去
      if (events.isNotEmpty && events.last.isRest) events.removeLast();
    }
    final degreeInfo = _midiToDegree(note.midiRound, ki);
    events.add(_Event.note(endUnits - start, degreeInfo.$1, degreeInfo.$2, degreeInfo.$3, note.confidence));
    cursorUnits = endUnits;
  }

  // 音符尾部与下一个音之间只差一点（<=1 个网格）时，直接把前一个音延长过去，
  // 避免谱面上出现一堆零碎休止符（检测出的尾音普遍比真值略短）
  for (var i = 0; i + 1 < events.length; i++) {
    final e = events[i];
    if (e.isRest) continue;
    var nextStart = i + 1;
    while (nextStart < events.length && events[nextStart].isRest) {
      nextStart++;
    }
    if (nextStart >= events.length) continue;
    final gap = _unitsBetween(events, i, nextStart);
    if (gap > 0 && gap <= 1) {
      // 把中间的碎休止符并进当前音
      for (var k = i + 1; k < nextStart; k++) {
        events.removeAt(k);
        nextStart--;
        k--;
      }
      events[i] = _Event.note(e.units + gap, e.degree, e.octave, e.accidental, e.confidence);
    }
  }

  // ---- 事件 -> 小节（跨小节自动拆成连音线） ----
  final measures = <Measure>[];
  var current = Measure();
  var filledBeats = 0.0;

  void newMeasure() {
    measures.add(current);
    current = Measure();
    filledBeats = 0;
  }

  void pushItem(Item item) {
    var remaining = item.ticks;
    var continued = false;
    while (remaining > 1e-9) {
      final room = capBeats - filledBeats;
      if (room <= 1e-9) {
        newMeasure();
        continue;
      }
      final take = math.min(room, remaining);
      final willSplit = take < remaining - 1e-9;
      Item piece;
      if (item is NoteItem) {
        piece = NoteItem(
          degree: item.degree,
          octave: item.octave,
          accidental: item.accidental,
          ticks: take,
          tieToPrev: item.tieToPrev || continued,
          tieToNext: willSplit,
          src: item.src,
        );
      } else {
        piece = RestItem(ticks: take);
      }
      current.items.add(piece);
      filledBeats += take;
      remaining -= take;
      continued = true;
      if (willSplit) newMeasure();
    }
  }

  for (final e in events) {
    if (e.isRest) {
      pushItem(RestItem(ticks: e.units * options.grid));
    } else {
      pushItem(NoteItem(
        degree: e.degree,
        octave: e.octave,
        accidental: e.accidental,
        ticks: e.units * options.grid,
        src: SrcInfo(confidence: e.confidence),
      ));
    }
  }
  if (current.items.isNotEmpty) measures.add(current);
  if (measures.isEmpty) measures.add(Measure());
  measures.last.isFinal = true;

  // ---- 生成乐谱 ----
  final meta = ScoreMeta(
    title: _titleOf(options, analysis, grand: false),
    keyName: keyName,
    mode: ki.mode,
    beats: options.beats,
    beatType: options.beatType,
    tempo: bpm.round(),
  );
  final score = Score(meta, measures);

  final text = toJianpu(score, measuresPerLine: 4);
  return QuantizeResult(
    score: score,
    jianpu: text,
    bpm: bpm,
    keyName: ki.display,
    mode: ki.mode,
    beats: options.beats,
    beatType: options.beatType,
    warnings: warnings,
  );
}

class _Event {
  final int units; // 网格单位数
  final bool isRest;
  final int degree;
  final int octave;
  final String accidental;
  final double confidence;
  const _Event._(this.units, this.isRest, this.degree, this.octave, this.accidental, this.confidence);
  factory _Event.rest(int units) => _Event._(units, true, 0, 0, '', 0);
  factory _Event.note(int units, int degree, int octave, String accidental, double confidence) =>
      _Event._(units, false, degree, octave, accidental, confidence);
}

/* ------------------------------------------------------------------ *
 * 复调（和弦 / 大谱表）
 * ------------------------------------------------------------------ */

/// 一条声部上的一个事件：一个音，或者同一时刻一起响的**和弦**
class _VoiceEvent {
  final int units;
  final bool isRest;

  /// (音级, 八度, 变音记号)，从低到高
  final List<(int, int, String)> tones;
  final double confidence;
  const _VoiceEvent(this.units, this.isRest, this.tones, this.confidence);
  factory _VoiceEvent.rest(int units) => _VoiceEvent(units, true, const [], 0);
  factory _VoiceEvent.chord(int units, List<(int, int, String)> tones, double conf) =>
      _VoiceEvent(units, false, tones, conf);
}

/// 自动决定大谱表的分界音：取音高中位数（夹在 C3~E4 之间）
int suggestSplitMidi(List<DetectedNote> notes) {
  if (notes.isEmpty) return 60;
  final midis = notes.map((n) => n.midiRound).toList()..sort();
  return midis[midis.length ~/ 2].clamp(48, 64);
}

/// 把一段（可能复调的）声部量化成小节序列：同一网格位置上一起起音的音合成和弦。
///
/// 与单声部量化的区别：允许同时发声，所以按"起音位置"分组，
/// 每组从最低音到最高音构成一个和弦，时值取到下一个起音（不越过）。
List<Measure> _voiceToMeasures({
  required List<DetectedNote> notes,
  required double offset,
  required double secPerBeat,
  required double grid,
  required double capBeats,
  required KeyInfo ki,
  required bool keepRests,
}) {
  if (notes.isEmpty) return [];
  final sorted = List<DetectedNote>.from(notes)..sort((a, b) => a.startSec.compareTo(b.startSec));
  int units(double sec) => ((sec - offset) / secPerBeat / grid).round();

  final groups = <int, List<DetectedNote>>{};
  for (final n in sorted) {
    var s = units(n.startSec);
    if (s < 0) s = 0;
    groups.putIfAbsent(s, () => []).add(n);
  }
  final onsets = groups.keys.toList()..sort();

  final events = <_VoiceEvent>[];
  var cursor = 0;
  for (var i = 0; i < onsets.length; i++) {
    final start = onsets[i];
    if (start > cursor) {
      if (keepRests) {
        events.add(_VoiceEvent.rest(start - cursor));
      } else if (events.isNotEmpty && events.last.isRest) {
        events.removeLast();
      }
    }
    final group = groups[start]!;
    var soundingEnd = start;
    for (final n in group) {
      var e = units(n.endSec);
      if (e <= start) e = start + 1;
      if (e > soundingEnd) soundingEnd = e;
    }
    final nextOnset = i + 1 < onsets.length ? onsets[i + 1] : soundingEnd;
    var end = math.min(soundingEnd, nextOnset);
    if (end <= start) end = start + 1;

    final tones = <(int, int, String)>[];
    final seen = <int>{};
    for (final n in group) {
      final d = _midiToDegree(n.midiRound, ki);
      final midi = degreeToMidi(d.$1, d.$2, d.$3, ki);
      if (seen.add(midi)) tones.add(d);
    }
    tones.sort((a, b) => degreeToMidi(a.$1, a.$2, a.$3, ki).compareTo(degreeToMidi(b.$1, b.$2, b.$3, ki)));
    final conf = group.map((n) => n.confidence).reduce(math.max);
    events.add(_VoiceEvent.chord(end - start, tones, conf));
    cursor = end;
  }

  final measures = <Measure>[];
  var current = Measure();
  var filled = 0.0;
  void newMeasure() {
    measures.add(current);
    current = Measure();
    filled = 0;
  }

  void push(_VoiceEvent e) {
    var remaining = e.units * grid;
    var continued = false;
    while (remaining > 1e-9) {
      final room = capBeats - filled;
      if (room <= 1e-9) {
        newMeasure();
        continue;
      }
      final take = math.min(room, remaining);
      final willSplit = take < remaining - 1e-9;
      if (e.isRest) {
        current.items.add(RestItem(ticks: take));
      } else {
        final lowest = e.tones.first;
        final item = NoteItem(
          degree: lowest.$1,
          octave: lowest.$2,
          accidental: lowest.$3,
          ticks: take,
          tieToPrev: continued,
          tieToNext: willSplit,
          src: SrcInfo(confidence: e.confidence),
        );
        for (final t in e.tones.skip(1)) {
          item.chord.add(ChordTone(degree: t.$1, octave: t.$2, accidental: t.$3));
        }
        current.items.add(item);
      }
      filled += take;
      remaining -= take;
      continued = true;
      if (willSplit) newMeasure();
    }
  }

  for (final e in events) {
    push(e);
  }
  if (current.items.isNotEmpty) measures.add(current);
  return measures;
}

/// 复调扒谱结果 -> **大谱表**（右手高音谱 + 左手低音谱），和弦保留。
///
/// [splitMidi] 为分界音高（>= 它走高音谱），默认按音高中位数自动决定。
QuantizeResult quantizeToGrandStaff(
  MelodyAnalysis analysis, {
  QuantizeOptions options = const QuantizeOptions(),
  int? splitMidi,
}) {
  final warnings = <String>[];
  final all = List<DetectedNote>.from(analysis.activeNotes)
    ..sort((a, b) => a.startSec.compareTo(b.startSec));
  if (all.isEmpty) return quantizeToScore(analysis, options: options);

  var bpm = options.bpm > 0 ? options.bpm : (analysis.bpm > 0 ? analysis.bpm : 90.0);
  bpm = bpm.clamp(40.0, 220.0);
  if (options.bpm <= 0 && analysis.bpm > 0) bpm = refineTempo(all, bpm);
  if (analysis.bpm <= 0) warnings.add('未能可靠估计速度，已使用默认 ${bpm.round()} BPM，可在界面上手动调整');

  var keyName = options.keyName ?? analysis.keyName;
  if (keyName.trim().isEmpty) keyName = 'C';
  final ki = keyInfoOf(keyName);

  // 先去掉泛音鬼影，再按音高分左右手：>= 分界音走右手（高音谱），其余走左手（低音谱）。
  // 分界音默认取音高中位数（夹在 C3~E4），让旋律自然落在高音谱上。
  final deduped = dropHarmonicGhosts(all);
  final crop = splitMidi ?? suggestSplitMidi(deduped);
  final upper = <DetectedNote>[];
  final lower = <DetectedNote>[];
  for (final n in deduped) {
    if (n.midiRound >= crop) {
      upper.add(n);
    } else {
      lower.add(n);
    }
  }
  if (lower.isEmpty || upper.isEmpty) {
    warnings.add('只检测到单一声部，已按单谱表输出（想要钢琴谱请换带伴奏的音频）');
  }

  final secPerBeat = 60.0 / bpm;
  final firstOnset = all.first.startSec;
  final offset = options.alignToFirstNote ? firstOnset : 0.0;
  final capBeats = options.beats * (4 / options.beatType);

  final measures1 = _voiceToMeasures(
    notes: upper,
    offset: offset,
    secPerBeat: secPerBeat,
    grid: options.grid,
    capBeats: capBeats,
    ki: ki,
    keepRests: options.keepRests,
  );
  final measures2 = _voiceToMeasures(
    notes: lower,
    offset: offset,
    secPerBeat: secPerBeat,
    grid: options.grid,
    capBeats: capBeats,
    ki: ki,
    keepRests: options.keepRests,
  );

  final count = math.max(measures1.length, measures2.length);
  final measures = <Measure>[];
  for (var i = 0; i < count; i++) {
    final m = Measure();
    if (i < measures1.length) m.items.addAll(measures1[i].items);
    if (i < measures2.length) m.items2.addAll(measures2[i].items);
    measures.add(m);
  }
  if (measures.isEmpty) measures.add(Measure());
  measures.last.isFinal = true;

  final meta = ScoreMeta(
    title: _titleOf(options, analysis, grand: true),
    keyName: keyName,
    mode: ki.mode,
    beats: options.beats,
    beatType: options.beatType,
    tempo: bpm.round(),
    clef: 'grand',
  );
  final score = Score(meta, measures);
  final chordCount = measures
      .expand((m) => [...m.items, ...m.items2])
      .whereType<NoteItem>()
      .where((n) => n.isChord)
      .length;
  if (chordCount > 0) warnings.add('识别出 $chordCount 个和弦（已按同时发声合并）');

  return QuantizeResult(
    score: score,
    jianpu: toJianpu(score, measuresPerLine: 4),
    bpm: bpm,
    keyName: ki.display,
    mode: ki.mode,
    beats: options.beats,
    beatType: options.beatType,
    warnings: warnings,
  );
}

/// 事件 i（音符）到事件 j 之间的网格间隔（不含 j 自身）
int _unitsBetween(List<_Event> events, int i, int j) {
  var sum = 0;
  for (var k = i + 1; k < j; k++) {
    sum += events[k].units;
  }
  return sum;
}

/// MIDI 音高 -> 简谱 (音级, 八度, 变音记号)
///
/// 实现已统一到 `model.dart` 的 [midiToDegree]（AI 识谱的结构化结果也要用同一套）。
(int, int, String) _midiToDegree(int midi, KeyInfo ki) => midiToDegree(midi, ki);

/// 给界面用的一句摘要
String describeQuantize(QuantizeResult r) =>
    '${r.beats}/${r.beatType} · ${r.bpm.round()} BPM · 1=${r.keyName} · ${r.score.measures.length} 小节 · ${r.score.noteCount} 个音';
