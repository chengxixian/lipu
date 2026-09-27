/// AI 识谱的**结构化输出**：让视觉模型直接给"音符事件"，而不是简谱文本。
///
/// 动机：简谱文本要用排版符号（减时线、附点、延音横线）表达节奏，模型很容易写错；
/// 让模型直接给 `{音级, 八度, 起始, 时值}` 这种事件表，节奏就是数字，误差小得多，
/// 而且这份数据**本身就是 MIDI 事件的等价物**——由它直接生成乐谱（MusicXML / 五线谱）
/// 和 MIDI 文件，不再经过"简谱文本"这个中间格式。
///
/// 支持的 JSON（键名宽容，也接受 midi 直接给音高）：
/// ```json
/// {
///   "title": "春风吹", "key": "1=C", "beats": 4, "beatType": 4, "tempo": 96,
///   "notes": [
///     {"staff": 1, "degree": 1, "octave": 0, "accidental": "", "start": 0, "dur": 1},
///     {"staff": 2, "degree": 1, "octave": -2, "start": 0, "dur": 4},
///     {"staff": 1, "midi": 64, "start": 1, "dur": 0.5}
///   ]
/// }
/// ```
/// `start` / `dur` 的单位是**四分音符 = 1**（与内部 IR 一致）；`staff` 省略当作 1。
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/model.dart';

/// 一个 AI 给出的音符事件
class AiNoteEvent {
  final int staff; // 1 = 高音谱, 2 = 低音谱
  final int midi;
  final double start; // 四分音符 = 1
  final double dur; // 四分音符 = 1
  final String? lyric;

  /// 若模型直接给了音级，这里保留原写法（便于回写简谱时保留 b7 之类）
  final int? degree;
  final int? octave;
  final String? accidental;

  const AiNoteEvent({
    required this.staff,
    required this.midi,
    required this.start,
    required this.dur,
    this.lyric,
    this.degree,
    this.octave,
    this.accidental,
  });
}

/// AI 识谱结果
class AiNotesScore {
  final String title;
  final String keyName; // 如 'C' / 'Am'
  final int beats;
  final int beatType;
  final int tempo;
  final List<AiNoteEvent> notes;
  const AiNotesScore({
    this.title = '',
    this.keyName = 'C',
    this.beats = 4,
    this.beatType = 4,
    this.tempo = 96,
    this.notes = const [],
  });

  bool get isEmpty => notes.isEmpty;
  bool get isGrandStaff => notes.any((n) => n.staff == 2);
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

int? _int(Object? v) {
  final d = _num(v);
  return d == null ? null : d.round();
}

String _str(Object? v) => v == null ? '' : v.toString().trim();

/// 从模型回复里抠出 JSON 对象（容忍 ```json 围栏与前后废话）
Map<String, dynamic>? extractJsonObject(String raw) {
  var s = raw.trim();
  // 去掉 markdown 代码围栏
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false).firstMatch(s);
  if (fence != null) s = fence.group(1)!.trim();
  final start = s.indexOf('{');
  final end = s.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  final body = s.substring(start, end + 1);
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// 解析模型给的结构化结果；不是这种格式就返回 null（调用方退回简谱文本）
///
/// 支持两种写法：
///   紧凑数组（推荐，token 省得多，模型不容易"写累了提前收尾"）：
///     `{"key":"1=C","v1":[[1,0,0,1],[5,0,2,2]],"v2":[[1,-2,0,4]]}`
///     每个音是 `[音级, 八度, 起始拍, 时值, 变音记号?]`
///   对象数组（也支持）：
///     `{"notes":[{"staff":1,"degree":1,"start":0,"dur":1}]}`
/// [keyOverride] 用于**分行识谱**：每一段的小图里看不到调号，模型可能自己猜一个，
/// 所以拼接时要用页眉读到的调号强制重解析一遍，否则音高会整体被带偏。
AiNotesScore? parseAiNotes(String raw, {String? keyOverride}) {
  final map = extractJsonObject(raw);
  if (map == null) return null;

  final keyRaw = (keyOverride != null && keyOverride.trim().isNotEmpty)
      ? keyOverride.trim()
      : _str(map['key'] ?? map['keyName'] ?? map['tonality']);
  final (keyName, laBased) = _keySpecOf(keyRaw);
  final ki = keyInfoOf(keyName);
  final beats = (_int(map['beats'] ?? map['beatsPerMeasure']) ?? 4).clamp(1, 16);
  final beatType = (_int(map['beatType'] ?? map['beatUnit'] ?? map['denominator']) ?? 4);
  final tempo = (_int(map['tempo'] ?? map['bpm']) ?? 96).clamp(20, 300);

  final out = <AiNoteEvent>[];

  /// 统一的"加一个音"入口
  void add({
    required int staff,
    required Object? degreeRaw,
    required Object? midiRaw,
    Object? octaveRaw,
    Object? accidentalRaw,
    Object? startRaw,
    Object? durRaw,
    Object? lyricRaw,
  }) {
    final start = math.max(0.0, _num(startRaw) ?? 0);
    var dur = _num(durRaw) ?? 1;
    if (dur <= 0) dur = 1;
    final lyric = _str(lyricRaw);

    final midiNum = _int(midiRaw);
    int midi;
    int? degree;
    int? octave;
    String? accidental;
    if (midiNum != null && midiNum >= 12 && midiNum <= 120) {
      midi = midiNum;
    } else {
      final deg = _int(degreeRaw);
      if (deg == null || deg < 1 || deg > 7) return; // 休止符之类直接跳过
      final oct = _int(octaveRaw) ?? 0;
      final acc = _str(accidentalRaw);
      final normalized = normalizeAccidental(acc.isEmpty ? '' : acc[0]);
      final mapped = laBased ? remapLaDegree(deg) : deg;
      degree = mapped;
      octave = oct;
      accidental = normalized;
      midi = degreeToMidi(mapped, oct, normalized, ki);
    }
    out.add(AiNoteEvent(
      staff: staff.clamp(1, 2),
      midi: midi,
      start: start,
      dur: dur,
      lyric: lyric.isEmpty ? null : lyric,
      degree: degree,
      octave: octave,
      accidental: accidental,
    ));
  }

  // ---- 紧凑数组写法：v1 / v2 / staff1 / staff2 ----
  var arrayForm = false;
  for (final entry in <String, int>{
    'v1': 1, 'staff1': 1, 'voice1': 1, 'upper': 1, 'right': 1, 'melody': 1,
    'v2': 2, 'staff2': 2, 'voice2': 2, 'lower': 2, 'left': 2, 'bass': 2,
  }.entries) {
    final list = map[entry.key];
    if (list is! List) continue;
    arrayForm = true;
    final staff = entry.value;
    for (final item in list) {
      if (item is Map) {
        final m = item.cast<String, dynamic>();
        add(
          staff: _int(m['staff'] ?? m['voice']) ?? staff,
          degreeRaw: m['degree'] ?? m['d'] ?? m['note'],
          midiRaw: m['midi'] ?? m['pitch'],
          octaveRaw: m['octave'] ?? m['oct'] ?? m['o'],
          accidentalRaw: m['accidental'] ?? m['acc'] ?? m['a'],
          startRaw: m['start'] ?? m['s'] ?? m['onset'],
          durRaw: m['dur'] ?? m['duration'] ?? m['e'] ?? m['len'],
          lyricRaw: m['lyric'],
        );
      } else if (item is List && item.length >= 4) {
        // [音级, 八度, 起始, 时值, 变音记号?]
        add(
          staff: staff,
          degreeRaw: item[0],
          midiRaw: null,
          octaveRaw: item[1],
          startRaw: item[2],
          durRaw: item[3],
          accidentalRaw: item.length > 4 ? item[4] : null,
        );
      }
    }
  }

  // ---- 对象数组写法：notes / noteEvents / events ----
  final list = map['notes'] ?? map['noteEvents'] ?? map['events'];
  if (list is List) {
    for (final item in list) {
      if (item is! Map) continue;
      final m = item.cast<String, dynamic>();
      add(
        staff: _int(m['staff'] ?? m['voice'] ?? m['hand']) ?? 1,
        degreeRaw: m['degree'] ?? m['note'] ?? m['jianpu'] ?? m['digit'] ?? m['d'],
        midiRaw: m['midi'] ?? m['pitch'] ?? m['midiNote'] ?? m['noteNumber'],
        octaveRaw: m['octave'] ?? m['oct'] ?? m['o'],
        accidentalRaw: m['accidental'] ?? m['accident'] ?? m['alter'] ?? m['a'],
        startRaw: m['start'] ?? m['startBeat'] ?? m['onset'] ?? m['time'] ?? m['s'],
        durRaw: m['dur'] ?? m['duration'] ?? m['length'] ?? m['beats'] ?? m['e'],
        lyricRaw: m['lyric'] ?? m['word'],
      );
    }
  }

  if (out.isEmpty) return null;
  if (!arrayForm && list == null) return null;
  out.sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.midi.compareTo(b.midi));
  return AiNotesScore(
    title: _str(map['title'] ?? map['name']),
    keyName: keyName,
    beats: beats,
    beatType: beatTypes.contains(beatType) ? beatType : 4,
    tempo: tempo,
    notes: out,
  );
}

/// 把多页的 AI 乐谱按顺序接成一份（多页时只有第一份的调号/拍号/速度/标题生效，
/// 小节依次往后排，与把多页文本拼起来的语义一致）。
///
/// 为什么需要"在乐谱层面"合并：AI 给的时值是**精确数字**（比如三连音 1/3 拍），
/// 而简谱文本只有减时线/附点，表达不了这种时值——先转成文本再解析回来，
/// 三连音就会被抹成四分音符。所以多页识别也要在乐谱层面拼。
Score mergeAiScores(List<Score> parts) {
  final valid = parts.where((s) => s.measures.any((m) => m.items.isNotEmpty || m.items2.isNotEmpty)).toList();
  if (valid.isEmpty) return parts.first;
  if (valid.length == 1) return valid.first;

  final out = <Measure>[];
  for (final s in valid) {
    for (final m in s.measures) {
      final copy = Measure()
        ..items.addAll(m.items)
        ..items2.addAll(m.items2);
      out.add(copy);
    }
  }
  if (out.isNotEmpty) out.last.isFinal = true;
  return Score(valid.first.meta, out);
}

const List<int> beatTypes = [1, 2, 4, 8, 16];

/* ------------------------------------------------------------------ *
 * 节奏（时值）质量判断
 *
 * 实际反馈里出现过"整页音符时值全都一样、节奏完全没识别"的情况：
 * 模型要么没看到数字下面的减时线，要么直接按四分音符默认输出。
 * 这里给一个**确定性判据**，让上层能发现并补救（见 `looksLikeFlatRhythm`）。
 * ------------------------------------------------------------------ */

/// 八度质量：模型是不是没看数字上下的点
class OctaveVerdict {
  /// octave 全是 0 的比例（漏读八度点）
  final double flatShare;

  /// octave 是 0 的比例（一个都没有 = 把"没点"的音也当成有点了）
  final double zeroShare;

  /// 某个声部的音域是不是离谱地宽（八度看错时的典型症状）
  final bool wideSpan;

  /// 下声部是不是反而比上声部高（八度看反了的强信号）
  final bool bassInverted;

  /// 全部都是 ±n、一个 0 都没有（且音够多、有两个声部）
  final bool zeroMissing;
  final int count;
  const OctaveVerdict({
    required this.flatShare,
    required this.zeroShare,
    required this.wideSpan,
    required this.bassInverted,
    required this.zeroMissing,
    required this.count,
  });

  bool get bad =>
      bassInverted || (flatShare >= 0.98 && count >= 30) || zeroMissing || wideSpan;
}

/// 判断八度是不是读错了。
///
/// 用户反馈：春风吹里"高音没有高、低音没有低"。实测（真 API）模型把**没有点的音
/// 读成了 -1**（整页一个 octave=0 都没有），于是主旋律音域被拉成 48~83（三个八度），
/// 音区关系全乱。所以这里要同时抓**两个方向**的错：
///   · 全 0（漏读上下加点）
///   · 一个 0 都没有（把没点的音也当成有点，最常见的错法）
///   · 单个声部音域过宽（> 20 半音，八度看错的典型症状）
///   · 下声部高于上声部（八度看反）
/// 音符太少（哼唱/练习曲）时不判，避免误伤。
OctaveVerdict octaveVerdict(AiNotesScore ai) {
  final v1 = ai.notes.where((n) => n.staff == 1).toList();
  final v2 = ai.notes.where((n) => n.staff == 2).toList();
  final n = ai.notes.length;
  final flatShare = n == 0 ? 0.0 : ai.notes.where((x) => (x.octave ?? 0) == 0).length / n;
  // 注意：flatShare（全 0）与 zeroShare（有 0 的比例）是同一件事的两种用法，
  // 这里语义分开写清楚：flatShare 高 = 漏读；zeroShare 低 = 多读。
  final zeroShare = flatShare;

  final ki = keyInfoOf(ai.keyName);
  int midiOf(AiNoteEvent x) =>
      degreeToMidi(x.degree ?? 1, x.octave ?? 0, x.accidental ?? '', ki);
  List<int> mids(List<AiNoteEvent> l) => l.map(midiOf).toList()..sort();

  var wide = false;
  for (final l in [v1, v2]) {
    if (l.length < 12) continue;
    final m = mids(l);
    if (m.last - m.first > 20) wide = true; // 超过一个半八度
  }

  var inverted = false;
  if (v1.length >= 8 && v2.length >= 8) {
    final a = mids(v1);
    final b = mids(v2);
    inverted = b[b.length ~/ 2] > a[a.length ~/ 2] + 2;
  }

  return OctaveVerdict(
    flatShare: flatShare,
    zeroShare: zeroShare,
    wideSpan: wide,
    bassInverted: inverted,
    zeroMissing: n >= 60 && v2.length >= 12 && zeroShare < 0.02,
    count: n,
  );
}

/// 时值直方图：`{时值(四分音符=1): 出现次数}`
Map<double, int> durationHistogram(Iterable<AiNoteEvent> notes) {
  final out = <double, int>{};
  for (final n in notes) {
    final d = (n.dur * 1000).round() / 1000;
    out[d] = (out[d] ?? 0) + 1;
  }
  return out;
}

/// 结果：整页时值是不是"太平"（= 节奏基本没识别出来）
///
/// 判据：真实歌曲里四分/八分/十六分/附点/二分/全音符都会出现，
/// 所以只要**超过 90% 的音都是同一个时值**（或只有一种时值），就认为是平的。
/// 音符太少（< [minNotes]）时不判——短小的练习曲本来就可能全是四分音符。
bool looksLikeFlatRhythm(AiNotesScore ai, {int minNotes = 12, double topShare = 0.9}) {
  if (ai.notes.length < minNotes) return false;
  final hist = durationHistogram(ai.notes);
  if (hist.length <= 1) return true;
  final top = hist.values.reduce((a, b) => a > b ? a : b);
  return top / ai.notes.length >= topShare;
}

/// 整页最常见的那个时值（补救提示词里要报给模型看）
double dominantDuration(AiNotesScore ai) {
  final hist = durationHistogram(ai.notes);
  var best = 1.0;
  var bestCount = -1;
  hist.forEach((dur, count) {
    if (count > bestCount) {
      bestCount = count;
      best = dur;
    }
  });
  return best;
}

/// `1=C` / `6=A` / `C` / `Am` 都收敛成内部调号写法
///
/// 返回 (调号, 是否 la 记法)。`6=A` 是简谱里小调的常见写法，意思是"6 音唱作 A"，
/// 也就是 **la 记法**：谱面上的 6 才是主音。而本项目的内部约定是 do 记法
/// （调号字母 = 1 的音），所以 la 记法要把音级整体平移（见 [remapLaDegree]）。
(String, bool) _keySpecOf(String raw) {
  if (raw.isEmpty) return ('C', false);
  final m = RegExp(r'^([1-7])\s*=\s*(.+)$').firstMatch(raw);
  final laBased = m != null && m.group(1) == '6';
  final spec = parseKeySpec(m != null ? m.group(2) : raw);
  final minor = laBased || spec.mode == 'minor';
  final text = spec.letter +
      (spec.alter > 0 ? '#' * spec.alter : spec.alter < 0 ? 'b' * (-spec.alter) : '') +
      (minor ? 'm' : '');
  return (text, laBased);
}

/// la 记法（6=A）的音级 -> do 记法（1=A）的音级。
///
/// 谱面 la 记法里 6 是主音，内部 do 记法里 1 是主音：
/// 6→1、7→2、1→3、2→4、3→5、4→6、5→7。
int remapLaDegree(int degree) => ((degree + 1) % 7) + 1;

/// 简谱文本的声部分配（模型没按结构化格式返回时的兜底）。
///
/// 钢琴简谱的上下两行就是**两个声部**。如果直接按"只取第一条旋律线"处理，
/// 低音谱会被整条丢掉——用户看到的就是"只有一行谱子、没有双手谱"。
/// 这里做一次判断：正文恰好两条旋律线、且小节数相同 → 标成 `高音:` / `低音:`；
/// 否则（行数不同，说明是同一旋律换行）保持原样。
String assignVoicesToText(String text) {
  final lines = text.split('\n');
  final hasPrefix = RegExp(r'^(高音|低音|上声部|下声部|上|下|右手|左手|RH|LH)\s*[:：]');
  final meta = RegExp(r'^(标题|曲名|歌名|作词|作曲|词|曲|title|composer|lyricist)\s*[:：]', caseSensitive: false);
  final keyLine = RegExp(r'^\s*[1-7]\s*=');

  final musicIdx = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (t.isEmpty) continue;
    if (hasPrefix.hasMatch(t)) return text; // 已经有声部标记，不重复加
    if (meta.hasMatch(t)) continue;
    if (keyLine.hasMatch(t) && !t.contains('|')) continue; // 调号行
    musicIdx.add(i);
  }
  if (musicIdx.length != 2) return text;

  int bars(String s) => RegExp(r'\|').allMatches(s).length;
  final b0 = bars(lines[musicIdx[0]]);
  final b1 = bars(lines[musicIdx[1]]);
  if (b0 < 2 || b0 != b1) return text; // 小节数不同 -> 是接续的同一旋律

  lines[musicIdx[0]] = '高音: ${lines[musicIdx[0]].trim()}';
  lines[musicIdx[1]] = '低音: ${lines[musicIdx[1]].trim()}';
  return lines.join('\n');
}

/* ------------------------------------------------------------------ *
 * 音符事件 -> Score（同时也就是 MIDI 事件表）
 * ------------------------------------------------------------------ */

class _Group {
  final double start;
  final double dur;
  final List<AiNoteEvent> notes;
  _Group(this.start, this.dur, this.notes);
}

/// 时值/起始拍吸附用的细网格：1/48 拍。
///
/// 为什么是 48：常见的时值都能整除它——二分 24、四分 12、八分 6、
/// 十六分 3、三十二分 1.5、附点八分 9、附点四分 18，**三连音 16**。
/// 模型给的三连音常写成 0.333/0.334，加起来是 0.999 或 1.001，
/// 不吸附的话会在小节里冒出一个 `休止(0.001 拍)` 这种垃圾休止符，
/// 五线谱上就多出一个莫名其妙的休止记号。
const double kFineGrid = 1 / 48;

/// 把时值/起点吸附到细网格（只吸附"差一点点"的值，差得多就原样保留）
double snapToFineGrid(double v) {
  final g = (v / kFineGrid).round() * kFineGrid;
  return (v - g).abs() < kFineGrid * 0.35 ? g : v;
}

/// 用另一个调号重新算一遍音高。
///
/// 用处：多页乐谱里**只有第一页印了调号**，第 2 页模型只能猜（实测它会猜成 1=C）。
/// 这时候用第 1 页读到的调号把后面几页重算一遍，整首才不会差一个调。
AiNotesScore rekeyAiScore(AiNotesScore ai, String keyRaw) {
  final (keyName, _) = _keySpecOf(keyRaw);
  final ki = keyInfoOf(keyName);
  final notes = <AiNoteEvent>[];
  for (final n in ai.notes) {
    final deg = n.degree;
    if (deg == null) {
      notes.add(n); // 没有音级信息（模型直接给了 MIDI）就原样保留
      continue;
    }
    notes.add(AiNoteEvent(
      staff: n.staff,
      midi: degreeToMidi(deg, n.octave ?? 0, n.accidental ?? '', ki),
      start: n.start,
      dur: n.dur,
      lyric: n.lyric,
      degree: n.degree,
      octave: n.octave,
      accidental: n.accidental,
    ));
  }
  return AiNotesScore(
    title: ai.title,
    keyName: keyName,
    beats: ai.beats,
    beatType: ai.beatType,
    tempo: ai.tempo,
    notes: notes,
  );
}

/// 把 AI 的音符事件编成乐谱：按 staff 分两个声部，同时起音同时值的合成和弦，
/// 跨小节自动拆连音线，空隙补休止符。
///
/// [singleLineLayout] 是**版面判断**的结果（true = 单行旋律谱，false = 钢琴双行谱，
/// null = 没判出来）：单行谱基本都是高音谱，这时用**中位音**决定谱号——只要有一个音
/// 被模型读低了一个八度，按"最低+最高取中"的老算法就会把整页翻成低音谱。
Score scoreFromAiNotes(AiNotesScore ai, {bool? singleLineLayout}) {
  final ki = keyInfoOf(ai.keyName);
  final cap = measureTicksOf(ai.beats, ai.beatType);

  List<Measure> voice(List<AiNoteEvent> events) {
    if (events.isEmpty) return [];
    // 同一 staff 上"起始+时值"完全相同的音合成和弦。
    // 先吸附到细网格：模型写三连音时常给 0.333/0.334，不吸附就会凭空多出
    // `休止(0.001 拍)` 这种垃圾休止符。
    final map = <String, List<AiNoteEvent>>{};
    for (final e in events) {
      final s = snapToFineGrid(e.start);
      final d = snapToFineGrid(e.dur);
      map.putIfAbsent('${s.toStringAsFixed(6)}|${d.toStringAsFixed(6)}', () => []).add(e);
    }
    final groups = map.values
        .map((list) => _Group(
              snapToFineGrid(list.first.start),
              snapToFineGrid(list.first.dur),
              list,
            ))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    final measures = <Measure>[];
    var current = Measure();
    var filled = 0.0;

    void newMeasure() {
      measures.add(current);
      current = Measure();
      filled = 0;
    }

    void pushRest(double ticks) {
      // 比细网格还小的"空隙"是浮点误差，不该变成一个休止符
      if (ticks < kFineGrid - kEps) return;
      var remaining = ticks;
      while (remaining > kEps) {
        final room = cap - filled;
        if (room <= kEps) {
          newMeasure();
          continue;
        }
        final take = math.min(room, remaining);
        current.items.add(RestItem(ticks: take));
        filled += take;
        remaining -= take;
        if (remaining > kEps) newMeasure();
      }
    }

    for (final g in groups) {
      // 起点落在小节内的位置；一直排到填满小节
      var gap = g.start - (measures.length * cap + filled);
      if (gap > kEps) pushRest(gap);
      var remaining = g.dur;
      var continued = false;
      while (remaining > kEps) {
        final room = cap - filled;
        if (room <= kEps) {
          newMeasure();
          continue;
        }
        final take = math.min(room, remaining);
        final willSplit = take < remaining - kEps;
        final tones = <ChordTone>[];
        for (final e in g.notes) {
          final d = e.degree != null
              ? (e.degree!, e.octave ?? 0, e.accidental ?? '')
              : midiToDegree(e.midi, ki);
          tones.add(ChordTone(degree: d.$1, octave: d.$2, accidental: d.$3));
        }
        tones.sort((a, b) => degreeToMidi(a.degree, a.octave, a.accidental, ki)
            .compareTo(degreeToMidi(b.degree, b.octave, b.accidental, ki)));
        final lowest = tones.first;
        final item = NoteItem(
          degree: lowest.degree,
          octave: lowest.octave,
          accidental: lowest.accidental,
          ticks: take,
          tieToPrev: continued,
          tieToNext: willSplit,
          lyric: g.notes.first.lyric,
        );
        for (final t in tones.skip(1)) {
          item.chord.add(t);
        }
        current.items.add(item);
        filled += take;
        remaining -= take;
        continued = true;
        if (willSplit) newMeasure();
      }
    }
    if (current.items.isNotEmpty) measures.add(current);
    return measures;
  }

  final staff1 = voice(ai.notes.where((n) => n.staff == 1).toList());
  final staff2 = voice(ai.notes.where((n) => n.staff == 2).toList());
  final count = math.max(staff1.length, staff2.length);
  final measures = <Measure>[];
  for (var i = 0; i < count; i++) {
    final m = Measure();
    if (i < staff1.length) m.items.addAll(staff1[i].items);
    if (i < staff2.length) m.items2.addAll(staff2[i].items);
    measures.add(m);
  }
  if (measures.isEmpty) measures.add(Measure());
  measures.last.isFinal = true;

  final meta = ScoreMeta(
    title: ai.title,
    keyName: ai.keyName,
    mode: ki.mode,
    beats: ai.beats,
    beatType: ai.beatType,
    tempo: ai.tempo,
    clef: (ai.isGrandStaff || singleLineLayout == false) ? 'grand' : 'auto',
  );
  final score = Score(meta, measures);
  // 单谱表时按音域自动选谱号
  if (!ai.isGrandStaff && singleLineLayout != false) {
    if (singleLineLayout == true) {
      // 版面确认是单行旋律谱：看**中位音**（一个跑偏的低音不会把整页翻成低音谱）
      meta.clef = _medianMidi(score) < 52 ? 'bass' : 'treble';
    } else {
      final (lo, hi) = score.midiRange();
      if (lo <= hi) meta.clef = (lo + hi) / 2 < 55 ? 'bass' : 'treble';
    }
  }
  return score;
}

/// 全谱音符的中位 MIDI（用来判"这条旋律该用高音谱还是低音谱"）
int _medianMidi(Score score) {
  final mids = <int>[];
  final ki = score.key;
  for (final m in score.measures) {
    for (final it in <Item>[...m.items, ...m.items2]) {
      if (it is NoteItem) {
        for (final p in notePitches(it, ki)) {
          mids.add(p.midi);
        }
      }
    }
  }
  if (mids.isEmpty) return 72;
  mids.sort();
  return mids[mids.length ~/ 2];
}
