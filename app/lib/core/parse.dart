/// 简谱文本解析器 —— 图片识别结果与人工输入共用同一个入口
///
/// 语法（宽松，兼容多种写法）：
///   调号 / 拍号 / 速度（行首或单独一行）：
///     1=C   1=G   6=A(小调)   1=bB   1=#F      4/4  3/4  6/8
///     ♩=96  Q=96  速度=96  T=96
///   元信息（单独一行）：标题：小星星   词：张三   曲：李四
///   音符： [变音记号][音级][八度][时值][附点][延音][歌词]
///     #4  b7  n1        变音记号
///     1-7               音级，0 = 休止符
///     1'  1''           上八度（^ 亦可），1,  1,, 下八度（v 亦可）
///     1/  1//  1///     减时线：八分 / 十六分 / 三十二分
///     1.  1/.           附点
///     1-  1--           延音：每个 - 延长一个四分音符
///     1[啊]             歌词（方括号里没有空格的单个记号）
///     [1 3 5]           和弦：方括号里是两个以上记号，同时发声（后缀写法 [1 3 5]/ 也支持）
///   结构： |  ||  |]  |:  :|  :||      ( … ) 连音线      ~ 延音线      ; 行内注释
///   声部（大谱表）：行首可写 `高音:` / `低音:`（也认 `上:` `下:` `右手:` `左手:` `RH:` `LH:`），
///     不写则沿用上一行所属声部；高音谱走谱表 1，低音谱走谱表 2。
library;

import 'model.dart';

final RegExp _noteToken = RegExp(r"^([#b♯♭♮]?)([0-7])([\^v',\/\.\-\+]*)(?:\[([^\]]*)\])?$");
final RegExp _headerKey = RegExp(r'^([1-7])\s*=\s*([#b♯♭]?[A-Ga-g](?:\s*(?:大调|小调|maj|min|m))?)', caseSensitive: false);
final RegExp _headerTime = RegExp(r'^(\d{1,2})\s*\/\s*(\d{1,2})$');
final RegExp _headerTempo = RegExp(r'^(?:♩|Q|T|BPM|速度|节拍)\s*[=:：]\s*(\d{1,3})$', caseSensitive: false);
final RegExp _metaLine = RegExp(r'^\s*(标题|曲名|歌名|title)\s*[:：]\s*(.+?)\s*$', caseSensitive: false);
final RegExp _lyricistLine = RegExp(r'^\s*(作词|词|lyricist)\s*[:：]\s*(.+?)\s*$', caseSensitive: false);
final RegExp _composerLine = RegExp(r'^\s*(作曲|曲|composer)\s*[:：]\s*(.+?)\s*$', caseSensitive: false);

/// 行首声部前缀
final RegExp _voicePrefix = RegExp(
  r'^\s*(高音谱?|上声部|上|右手声部|右手|RH|rh|低音谱?|下声部|下|左手声部|左手|LH|lh)\s*[:：]\s*',
);

/// 和弦记号：`[1 3 5]`，允许后面直接跟时值后缀（`[1 3 5]/`）
final RegExp _chordToken = RegExp(r"^\[([^\]]*)\]([\^v',\/\.\-\+]*)$");

final RegExp _tokenSplit = RegExp(
  r"\[[^\]]*\][\^v',\/\.\-\+]*|[#b♯♭♮]?[0-7][\^v',\/\.\-\+]*|\|\:|\:\|\]|\:\|\||\:\||\|\||\|\]|\||\(|\)|~|-|\S+",
);

const List<int> _validBeatTypes = [1, 2, 4, 8, 16];

/// 声部前缀 -> 谱表编号（1 = 高音，2 = 低音）
int _voiceOf(String prefix) {
  if (RegExp(r'^(高音|上|右手|RH|rh)').hasMatch(prefix)) return 1;
  return 2;
}


class ParseOptions {
  final String? keyName;
  final int? beats;
  final int? beatType;
  final int? tempo;
  final String? title;
  const ParseOptions({this.keyName, this.beats, this.beatType, this.tempo, this.title});
}

/// 归一化：把识别结果里常见的“带空格表头”收敛成标准写法
/// 例如 `1 = C` -> `1=C`，`4 / 4` -> `4/4`，`♩ = 96` -> `♩=96`
String normalizeJianpuText(String text) {
  var s = text;
  s = s.replaceAllMapped(
    RegExp(r'([1-7])\s*=\s*([#b♯♭]?\s*[A-Ga-g])'),
    (m) => '${m[1]}=${m[2]!.replaceAll(RegExp(r'\s+'), '')}',
  );
  // 减时线是紧贴数字的 `/`，这里只合并两侧都有空格的拍号写法
  s = s.replaceAllMapped(
    RegExp(r'(?<![\d/])(\d{1,2})\s+/\s+(\d{1,2})(?![\d/])'),
    (m) => '${m[1]}/${m[2]}',
  );
  s = s.replaceAllMapped(
    RegExp(r'(♩|Q|T|BPM|速度|节拍)\s*[=:：]\s*(\d{1,3})', caseSensitive: false),
    (m) => '${m[1]}=${m[2]}',
  );
  return s;
}

/// 一个声部的解析状态（高音谱 / 低音谱各一套，最后按小节序号合并）
class _Track {
  final int voice;
  final List<Measure> measures = [];
  Measure cur = Measure();
  double pos = 0;
  _Track(this.voice);

  void finish({bool force = false}) {
    if (cur.items.isEmpty && !cur.repeatStart && !cur.repeatEnd && !force) return;
    measures.add(cur);
    cur = Measure();
    pos = 0;
  }
}

/// 从时值后缀里数出减时线 / 附点 / 延音
({int underlines, int dots, int dashes}) _durMarkers(String s) {
  var u = 0, d = 0, dash = 0;
  for (final ch in s.split('')) {
    if (ch == '/') {
      u++;
    } else if (ch == '.') {
      d++;
    } else if (ch == '-') {
      dash++;
    }
  }
  return (underlines: u, dots: d, dashes: dash);
}

int _octaveOf(String s) {
  var o = 0;
  for (final ch in s.split('')) {
    if (ch == "'" || ch == '^' || ch == '+') {
      o += 1;
    } else if (ch == ',' || ch == 'v') {
      o -= 1;
    }
  }
  return o;
}

double _ticksOf(int underlines, int dots, int dashes) {
  var ticks = 1 / _pow2(underlines);
  if (dots > 0) ticks *= 2 - 1 / _pow2(dots);
  return ticks + dashes;
}

/// 解析和弦记号 `[1 3 5]` / `[b7 2 4]/`。
///
/// 规则：方括号里必须**全是**音符记号且至少两个，否则返回 null（交给"歌词"分支）。
/// 主音取最低音，其余按音高从低到高放进 `chord`。
NoteItem? _parseChordToken(String tk, ScoreMeta meta) {
  final m = _chordToken.firstMatch(tk);
  if (m == null) return null;
  final inner = m.group(1)!.trim();
  final suffix = m.group(2) ?? '';
  if (inner.isEmpty) return null;
  final parts = inner.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return null;

  final ki = keyInfoOf(meta.keyName);
  final tones = <ChordTone>[];
  final seen = <int>{};
  var lastMarkers = '';
  for (final p in parts) {
    final nm = _noteToken.firstMatch(p);
    if (nm == null || nm.group(4) != null) return null;
    final digit = int.parse(nm.group(2)!);
    if (digit == 0) return null; // 和弦里不写休止符
    final tone = ChordTone(
      degree: digit,
      octave: _octaveOf(nm.group(3)!),
      accidental: normalizeAccidental(nm.group(1)!),
    );
    final midi = degreeToMidi(tone.degree, tone.octave, tone.accidental, ki);
    if (seen.add(midi)) tones.add(tone);
    lastMarkers = nm.group(3)!;
  }
  if (tones.length < 2) return null;

  final mk = _durMarkers(lastMarkers + suffix);
  final ticks = _ticksOf(mk.underlines, mk.dots, mk.dashes);

  tones.sort((a, b) => degreeToMidi(a.degree, a.octave, a.accidental, ki)
      .compareTo(degreeToMidi(b.degree, b.octave, b.accidental, ki)));
  final lowest = tones.first;
  final item = NoteItem(
    degree: lowest.degree,
    octave: lowest.octave,
    accidental: lowest.accidental,
    ticks: ticks,
  );
  item.chord.addAll(tones.skip(1).map((t) => t.clone()));
  return item;
}

Score parseJianpu(String text, [ParseOptions? opts]) {
  text = normalizeJianpuText(text);
  final meta = ScoreMeta(
    keyName: opts?.keyName ?? 'C',
    beats: opts?.beats ?? 4,
    beatType: opts?.beatType ?? 4,
    tempo: opts?.tempo ?? 96,
    title: opts?.title ?? '',
  );
  if (opts?.keyName != null) meta.mode = keyInfoOf(opts!.keyName).mode;

  // 两个声部各解析一套小节，最后按序号合并成大谱表
  final tracks = <int, _Track>{1: _Track(1), 2: _Track(2)};
  var voice = 1;
  var pendingTieGroup = 0;
  var tieNext = false;
  var groupNotes = <NoteItem>[];

  void warn(String msg, [int? line]) =>
      meta.warnings.add(line == null ? msg : '第$line行: $msg');

  void pushItem(_Track tr, Item item, int lineNo) {
    if (item is NoteItem || item is RestItem) {
      final cap = measureTicksOf(meta.beats, meta.beatType);
      if (tr.pos + item.ticks > cap + kEps) {
        warn('第${tr.measures.length + 1}小节时值超出拍号容量，已自动新起小节', lineNo);
        tr.finish(force: true);
      }
    }
    tr.cur.items.add(item);
    if (item is NoteItem || item is RestItem) tr.pos += item.ticks;
  }

  Item? lastSounding(Measure m) {
    for (var i = m.items.length - 1; i >= 0; i--) {
      final it = m.items[i];
      if (it is NoteItem || it is RestItem) return it;
    }
    return null;
  }

  final rawLines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  for (var li = 0; li < rawLines.length; li++) {
    var line = _stripComment(rawLines[li]);
    if (line.trim().isEmpty) continue;
    final lineNo = li + 1;

    // 声部前缀（高音: / 低音: …）：只影响本行及其后没有前缀的行
    final vp = _voicePrefix.firstMatch(line);
    if (vp != null) {
      voice = _voiceOf(vp.group(1)!);
      line = line.substring(vp.end);
      if (line.trim().isEmpty) continue;
    }
    final tr = tracks[voice]!;

    var m = _metaLine.firstMatch(line);
    if (m != null) {
      meta.title = m.group(2)!;
      continue;
    }
    m = _lyricistLine.firstMatch(line);
    if (m != null) {
      meta.lyricist = m.group(2)!;
      continue;
    }
    m = _composerLine.firstMatch(line);
    if (m != null) {
      meta.composer = m.group(2)!;
      continue;
    }

    // ---- 行首连续的 调号 / 拍号 / 速度 ----
    var restText = line.trim();
    for (var guard = 0; guard < 8; guard++) {
      final t = restText.trim();
      if (t.isEmpty) break;
      final words = t.split(RegExp(r'\s+'));
      final head = words.first;
      final km = _headerKey.firstMatch(head);
      if (km != null) {
        final spec = parseKeySpec(km.group(2));
        var mode = spec.mode;
        if (km.group(1) == '6' && !RegExp(r'小调|min', caseSensitive: false).hasMatch(km.group(2)!)) {
          mode = 'minor';
        }
        meta.keyName = spec.letter +
            (spec.alter > 0 ? '#' * spec.alter : spec.alter < 0 ? 'b' * (-spec.alter) : '') +
            (mode == 'minor' ? 'm' : '');
        meta.mode = mode;
        restText = words.skip(1).join(' ');
        continue;
      }
      final tm = _headerTime.firstMatch(head);
      if (tm != null) {
        final beats = int.parse(tm.group(1)!);
        final beatType = int.parse(tm.group(2)!);
        if (_validBeatTypes.contains(beatType) && beats >= 1 && beats <= 16) {
          meta.beats = beats;
          meta.beatType = beatType;
          restText = words.skip(1).join(' ');
          continue;
        }
      }
      final sm = _headerTempo.firstMatch(head);
      if (sm != null) {
        meta.tempo = int.parse(sm.group(1)!);
        restText = words.skip(1).join(' ');
        continue;
      }
      break;
    }

    // ---- 正文 token ----
    // 简谱里连续数字就是相邻的音符（3333 = 四个 3），但很多输入（含 AI 输出、
    // 手打文本）不加空格，这里先在"数字与数字之间"补空格，避免整段被当成无效记号。
    restText = restText.replaceAllMapped(
      RegExp(r"(?<=[0-7][',\/\.\-\^v]*\]?)(?=[0-7])"),
      (m) => ' ',
    );
    for (final tk in _tokenSplit.allMatches(restText).map((e) => e.group(0)!)) {
      switch (tk) {
        case '|':
        case '||':
          tr.finish();
          continue;
        case '|]':
        case ':||':
          tr.cur.isFinal = true;
          tr.finish();
          continue;
        case ':|]': // 反复结束 + 终止
          tr.cur.repeatEnd = true;
          tr.cur.isFinal = true;
          tr.finish();
          continue;
        case '|:':
          tr.finish();
          tr.cur.repeatStart = true;
          continue;
        case ':|':
          tr.cur.repeatEnd = true;
          tr.finish();
          continue;
        case '(':
          pendingTieGroup++;
          groupNotes = [];
          continue;
        case ')':
          pendingTieGroup = (pendingTieGroup - 1).clamp(0, 99);
          for (var i = 0; i + 1 < groupNotes.length; i++) {
            final a = groupNotes[i], b = groupNotes[i + 1];
            if (a.degree == b.degree && a.octave == b.octave && a.chord.length == b.chord.length) {
              a.tieToNext = true;
              b.tieToPrev = true;
            }
          }
          groupNotes = [];
          continue;
        case '~':
          tieNext = true;
          final prev = lastSounding(tr.cur);
          if (prev is NoteItem) prev.tieToNext = true;
          continue;
        case '-':
          final last = lastSounding(tr.cur);
          if (last != null) {
            last.ticks += 1;
            tr.pos += 1;
          } else {
            warn('延音线 "-" 前面没有音符，已忽略', lineNo);
          }
          continue;
      }

      // 和弦 [1 3 5]
      final chordItem = _parseChordToken(tk, meta);
      if (chordItem != null) {
        if (tieNext) {
          chordItem.tieToPrev = true;
          tieNext = false;
        }
        if (pendingTieGroup > 0) groupNotes.add(chordItem);
        pushItem(tr, chordItem, lineNo);
        continue;
      }

      final nm = _noteToken.firstMatch(tk);
      if (nm == null) {
        if (tk.startsWith('[')) {
          final last = lastSounding(tr.cur);
          if (last is NoteItem) {
            last.lyric = tk.substring(1, tk.indexOf(']') > 0 ? tk.indexOf(']') : tk.length - 1);
          } else {
            warn('歌词 "$tk" 没有对应音符，已忽略', lineNo);
          }
          continue;
        }
        warn('无法识别的记号 "$tk"，已忽略', lineNo);
        continue;
      }

      final accidental = normalizeAccidental(nm.group(1)!);
      final digit = int.parse(nm.group(2)!);
      var octave = 0, underlines = 0, dots = 0, dashes = 0;
      final lyric = nm.group(4);
      for (final ch in nm.group(3)!.split('')) {
        if (ch == "'" || ch == '^' || ch == '+') {
          octave += 1;
        } else if (ch == ',' || ch == 'v') {
          octave -= 1;
        } else if (ch == '/') {
          underlines += 1;
        } else if (ch == '.') {
          dots += 1;
        } else if (ch == '-') {
          dashes += 1;
        }
      }

      var ticks = 1 / _pow2(underlines);
      if (dots > 0) ticks *= 2 - 1 / _pow2(dots);
      ticks += dashes;

      if (digit == 0) {
        pushItem(tr, RestItem(ticks: ticks), lineNo);
      } else {
        final item = NoteItem(degree: digit, octave: octave, accidental: accidental, ticks: ticks, lyric: lyric);
        if (tieNext) {
          item.tieToPrev = true;
          tieNext = false;
        }
        if (pendingTieGroup > 0) groupNotes.add(item);
        pushItem(tr, item, lineNo);
      }
    }
  }

  tracks[1]!.finish();
  tracks[2]!.finish();

  // 两个声部按小节序号合并成大谱表
  final t1 = tracks[1]!.measures;
  final t2 = tracks[2]!.measures;
  final count = t1.length > t2.length ? t1.length : t2.length;
  final measures = <Measure>[];
  for (var i = 0; i < count; i++) {
    final m = Measure();
    if (i < t1.length) {
      m.items.addAll(t1[i].items);
      m.repeatStart = t1[i].repeatStart;
      m.repeatEnd = t1[i].repeatEnd;
      m.isFinal = t1[i].isFinal;
    }
    if (i < t2.length) {
      m.items2.addAll(t2[i].items);
      m.repeatStart = m.repeatStart || t2[i].repeatStart;
      m.repeatEnd = m.repeatEnd || t2[i].repeatEnd;
      m.isFinal = m.isFinal || t2[i].isFinal;
    }
    measures.add(m);
  }
  if (measures.isEmpty) measures.add(Measure());
  measures.last.isFinal = true;

  final score = Score(meta, measures);
  _autoClef(score);
  _validate(score, warn);
  return score;
}

double _pow2(int n) {
  var v = 1.0;
  for (var i = 0; i < n; i++) {
    v *= 2;
  }
  return v;
}

String _stripComment(String line) {
  final t = line.trim();
  if (t.startsWith('//') || t.startsWith(';')) return '';
  final i = line.indexOf(';');
  return i >= 0 ? line.substring(0, i) : line;
}

void _autoClef(Score score) {
  // 有第二声部就是大谱表（高音谱 + 低音谱）
  if (score.measures.any((m) => m.isGrand)) {
    score.meta.clef = 'grand';
    return;
  }
  if (score.meta.clef == 'grand') score.meta.clef = 'auto';
  if (score.meta.clef != 'auto' && score.meta.clef.isNotEmpty) return;
  final ki = score.key;
  var sum = 0, n = 0;
  for (final m in score.measures) {
    for (final it in m.items) {
      if (it is! NoteItem) continue;
      sum += noteToPitch(it, ki).midi;
      n++;
    }
  }
  score.meta.clef = (n > 0 && sum / n < 55) ? 'bass' : 'treble';
}

void _validate(Score score, void Function(String, [int?]) warn) {
  final cap = measureTicksOf(score.meta.beats, score.meta.beatType);
  for (var i = 0; i < score.measures.length; i++) {
    final m = score.measures[i];
    final isLast = i == score.measures.length - 1;
    final voices = <(String, double)>[('', m.filled), if (m.isGrand) ('（低音谱）', m.filled2)];
    for (final (label, filled) in voices) {
      if (filled == 0) continue;
      if (filled > cap + kEps) {
        warn('第${i + 1}小节$label时值超出拍号（${_r(filled)} / $cap）');
      } else if (filled < cap - kEps && !isLast) {
        warn('第${i + 1}小节$label时值不足拍号（${_r(filled)} / $cap）');
      }
    }
  }
}

String _r(double x) => (x * 1000).roundToDouble() / 1000 == x.roundToDouble() ? '${x.round()}' : x.toStringAsFixed(3);

/* ------------------------------------------------------------------ *
 * 乐谱 -> 简谱文本（编辑框回写）
 * ------------------------------------------------------------------ */

String toJianpu(Score score, {int measuresPerLine = 4}) {
  final lines = <String>[];
  final meta = score.meta;
  if (meta.title.isNotEmpty) lines.add('标题：${meta.title}');
  if (meta.lyricist.isNotEmpty) lines.add('词：${meta.lyricist}');
  if (meta.composer.isNotEmpty) lines.add('曲：${meta.composer}');
  final header = <String>[
    // 小调按简谱惯例写成 6=A（这样往返解析也仍然是自然小调）
    '${keyInfoOf(meta.keyName).mode == 'minor' ? '6' : '1'}=${_keyHeaderText(meta.keyName)}',
    '${meta.beats}/${meta.beatType}',
  ];
  if (meta.tempo > 0) header.add('♩=${meta.tempo}');
  lines.add(header.join(' '));

  if (!score.isGrandStaff) {
    for (var i = 0; i < score.measures.length; i++) {
      final m = score.measures[i];
      final parts = <String>[];
      if (m.repeatStart) parts.add('|:');
      for (final it in m.items) {
        parts.add(itemToJianpu(it));
      }
      parts.add(m.repeatEnd ? ':|' : (m.isFinal ? '|]' : '|'));
      lines.add(parts.where((p) => p.isNotEmpty).join(' '));
      if ((i + 1) % measuresPerLine == 0 && i != score.measures.length - 1) lines.add('');
    }
    return lines.join('\n');
  }

  // 大谱表：先写高音谱一块，再写低音谱一块（首行带声部前缀）
  final cap = measureTicksOf(meta.beats, meta.beatType);
  for (final second in [false, true]) {
    if (second && lines.isNotEmpty) lines.add('');
    var prefixed = false;
    for (var i = 0; i < score.measures.length; i++) {
      final m = score.measures[i];
      final items = second ? m.items2 : m.items;
      final parts = <String>[];
      if (!second && m.repeatStart) parts.add('|:');
      for (final it in items) {
        parts.add(itemToJianpu(it));
      }
      // 空声部补整小节休止，保证两个声部的小节数一一对应
      if (items.isEmpty && second) parts.add('0${_durationSuffix(cap)}');
      parts.add(!second && m.repeatEnd ? ':|' : (!second && m.isFinal ? '|]' : '|'));
      var text = parts.where((p) => p.isNotEmpty).join(' ');
      if (!prefixed && items.isNotEmpty) {
        text = '${second ? '低音' : '高音'}: $text';
        prefixed = true;
      }
      lines.add(text);
      if ((i + 1) % measuresPerLine == 0 && i != score.measures.length - 1) lines.add('');
    }
  }
  return lines.join('\n');
}

String _keyHeaderText(String keyName) {
  final ki = keyInfoOf(keyName);
  return ki.letter + (ki.alter > 0 ? '#' * ki.alter : ki.alter < 0 ? 'b' * (-ki.alter) : '');
}

String _accPrefix(String a) => a == '#' ? '#' : a == 'b' ? 'b' : a == 'n' ? 'n' : '';

String _octSuffix(int octave) => octave > 0 ? "'" * octave : octave < 0 ? ',' * (-octave) : '';

String itemToJianpu(Item it) {
  if (it is RestItem) return '0${_durationSuffix(it.ticks)}';
  final n = it as NoteItem;
  if (n.isChord) {
    final tokens = <String>[
      '${_accPrefix(n.accidental)}${n.degree}${_octSuffix(n.octave)}',
      for (final t in n.chord) '${_accPrefix(t.accidental)}${t.degree}${_octSuffix(t.octave)}',
    ];
    final lyric = (n.lyric != null && n.lyric!.isNotEmpty) ? '[${n.lyric}]' : '';
    return '[${tokens.join(' ')}]${_durationSuffix(n.ticks)}$lyric';
  }
  final lyric = (n.lyric != null && n.lyric!.isNotEmpty) ? '[${n.lyric}]' : '';
  return '${_accPrefix(n.accidental)}${n.degree}${_octSuffix(n.octave)}${_durationSuffix(n.ticks)}$lyric';
}

String _durationSuffix(double ticks) {
  if (ticks >= 1 - kEps && (ticks - ticks.roundToDouble()).abs() < kEps) {
    final whole = ticks.round();
    return whole > 1 ? ' ${List.filled(whole - 1, '-').join(' ')}' : '';
  }
  final rep = ticksToType(ticks);
  if (rep != null) {
    const slashes = {'q': '', '8': '/', '16': '//', '32': '///', '64': '////'};
    final s = slashes[rep.type];
    if (s != null) return s + '.' * rep.dots;
  }
  final whole = ticks.floor();
  final frac = ticks - whole;
  final repF = ticksToType(frac);
  var slashPart = '';
  if (repF != null) {
    const slashes = {'q': '', '8': '/', '16': '//', '32': '///', '64': '////'};
    slashPart = (slashes[repF.type] ?? '') + '.' * repF.dots;
  }
  return slashPart + (whole > 0 ? ' ${List.filled(whole, '-').join(' ')}' : '');
}
