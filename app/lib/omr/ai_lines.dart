/// 分行并发识谱：本地把整页切成"每段一组谱行"，并发发给视觉模型，最后按小节拼接。
///
/// 为什么要这么做（2026-09 实测，春风吹 p1，deepseek-flash）：
///   · 整页一个请求时，模型的输出里 **94% 是"思考"token**（整页 30K、只给三分之一页
///     也还有 20K），耗时 117s；把推理关掉（`reasoning_effort: none`）后同样的页面
///     6~7s，音数与两个声部都不掉。
///   · 再按"组谱行"切开并发：每段任务小得多（一段只有二三十个音），墙面时间 ≈ 最慢
///     的那一段；而且某段读错/失败可以**只重试那一段**，不像整页那样一处错全页重来。
///
/// 拼接规则：每段的 start 都从 0 开始，按"这一段占了多少个完整小节"往后累加偏移。
/// 调号/拍号/速度/曲名由页面顶部标题区单独读一次，然后**强制**套用到每一段
/// （每段图里看不到调号，不覆盖的话模型会自己猜一个，音高就整体错了）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/model.dart' show measureTicksOf;
import 'ai_notes.dart';
import 'cloud_recognizer.dart';
import 'omr.dart' show ScoreLayoutMode;
import 'omr_service.dart';

/// 读页面顶部标题区：输出很短，通常 1 秒内
const String kAiHeaderPrompt = '''只读这张图**最上方**的标题与曲谱信息，只输出一个 JSON：
{"title":"曲名","key":"1=C","beats":4,"beatType":4,"tempo":96}

规则：
- title = 图上印的曲名（可能是书名号《》、艺术字或手写体）。没有印刷标题就写 ""。
  **不要**把"简谱/谱子/图片/未命名"或数字音级当成曲名，也不要写词曲作者。
- key = 调号，照抄谱面（如 "1=C"、"6=A"）；看不到就写 ""。
- beats/beatType = 拍号（4/4 → 4 和 4）；看不到就写 4 和 4。
- tempo = 速度（♩=96 → 96）；看不到就写 0。
- 不要输出任何音符事件，不要解释，不要 Markdown 代码块。''';

/// 让 AI **只看版面**、判断每一组谱行在哪、是单行还是双行（不识别音符）
///
/// 为什么让 AI 判：单行旋律谱（一行数字 + 汉字歌词）和钢琴双行谱（每组上下两行数字）
/// 的排版差异是"语义"上的——本地几何能算出每一行的精确像素边界，但"哪两行属于同一组"
/// 有时会判错（实测：二十二 p1 的相邻谱行只隔 1.4 个字高，纯几何会把 4 组串成一大块）。
/// 所以这里让 AI 出**结构**（每组几行、大致在哪），再把它的归一化坐标**吸附**到本地
/// 算出来的行边界上——AI 定位、本地定像素，两边各干自己擅长的。
const String kAiLayoutPrompt = '''这是一个**简谱**页面的版面分析任务，**不要识别音符**。

简谱有两种排法：
- **单行旋律谱**：每一组只有一行数字，数字下面是歌词汉字。
- **钢琴双行谱**：每一组里上下各有一行数字（上面高音、下面低音）。

请只输出一个 JSON：
{"title":"曲名","key":"1=F","layout":"single","systems":[{"rows":1,"y0":0.05,"y1":0.13},{"rows":1,"y0":0.16,"y1":0.24}]}

说明：
- title：页面最上方印的**曲名**，照抄（可能是艺术字/书名号）；没有印刷标题就写 ""。
  不要把数字音级、也不要把"简谱/未命名"写进来（曲名本身是数字的照写，例如 "22"）。
- key：页面左上角印的**调号**，照抄（如 "1=F"、"6=A"）；看不到就写 ""。
- systems 按**从上到下**排列，**每一组谱行**一个元素（不要把整页合成一个）。
- rows：这一组里有几行数字（1 = 单行旋律；2 = 上下两行，钢琴谱）。可能出现两种混排，
  按实际情况逐组写。
- y0/y1：这一组谱行在整页高度上的位置，用 **0~1 的比例**表示（0 = 页面最上边，
  1 = 页面最下边）；y0 = 这一组最上面一行数字的顶边，y1 = 最下面一行数字的底边。
  **一组只算数字行**，不要把下面的歌词行算进去。
- layout：整页以单行谱为主写 "single"，以双行谱为主写 "grand"，两种混排写 "mixed"。
- 不要输出音符、不要解释、不要 Markdown 代码块。''';

/// AI 判出来的版面结构
class AiPageStructure {
  /// 每一组谱行：几行数字 + 归一化的 y 范围
  final List<({int rows, double y0, double y1})> systems;

  /// 'single' | 'grand' | 'mixed'（AI 的判断，可能为空）
  final String layout;

  /// 整页看到的曲名/调号（比只裁顶部一条更可靠，用来兜底页眉那一路）
  final String title;
  final String keyRaw;

  const AiPageStructure({
    this.systems = const [],
    this.layout = '',
    this.title = '',
    this.keyRaw = '',
  });

  bool get isEmpty => systems.isEmpty;

  /// 主要谱式（mixed 时看多数）
  ScoreLayoutMode get dominantMode {
    if (layout == 'grand') return ScoreLayoutMode.grandStaff;
    if (layout == 'single') return ScoreLayoutMode.singleLine;
    final two = systems.where((s) => s.rows >= 2).length;
    return (systems.isNotEmpty && two * 2 > systems.length)
        ? ScoreLayoutMode.grandStaff
        : ScoreLayoutMode.singleLine;
  }

  static AiPageStructure fromRaw(String raw) {
    final map = extractJsonObject(raw);
    if (map == null) return const AiPageStructure();
    final layout = (map['layout'] ?? map['mode'] ?? '').toString().trim().toLowerCase();
    final list = map['systems'] ?? map['groups'] ?? map['staves'];
    final out = <({int rows, double y0, double y1})>[];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final rows = _intOf(item['rows'] ?? item['staves'] ?? item['lines'] ?? item['count']) ?? 1;
        var y0 = _doubleOf(item['y0'] ?? item['top'] ?? item['start']);
        var y1 = _doubleOf(item['y1'] ?? item['bottom'] ?? item['end']);
        if (y0 == null || y1 == null) continue;
        // 模型偶尔给成 0~100
        if (y0 > 1.5 || y1 > 1.5) {
          y0 = y0 / 100;
          y1 = y1 / 100;
        }
        if (y1 <= y0) continue;
        out.add((rows: rows.clamp(1, 3), y0: y0.clamp(0.0, 1.0), y1: y1.clamp(0.0, 1.0)));
      }
    }
    out.sort((a, b) => a.y0.compareTo(b.y0));
    final title = (map['title'] ?? map['name'] ?? '').toString();
    final key = (map['key'] ?? map['keyName'] ?? map['tonality'] ?? '').toString();
    return AiPageStructure(
      systems: out,
      layout: layout,
      title: AiPageHeader.cleanTitle(title),
      keyRaw: key.trim(),
    );
  }
}

int? _intOf(Object? v) {
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _doubleOf(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// 把 AI 给的归一化 y 范围**吸附**到本地算出来的行边界上。
///
/// 规则：行中心落在 [y0,y1]（按页高换算成像素，上下各放宽一点）里的行，都算这一组。
/// 这样即使 AI 的坐标有点偏，也不会把一行裁成两半。
List<List<AiStripImage>> snapStructureToRows(
  AiPageStructure structure,
  AiPageSplit split,
) {
  final rows = split.rows;
  if (rows.isEmpty) return const [];
  final pageHeight = split.bands.isEmpty
      ? 1.0
      : split.bands.map((b) => b.$2).reduce(math.max).toDouble();
  double distTo(int i, double y0, double y1) {
    final center = (rows[i].y0 + rows[i].y1) / 2;
    if (center < y0) return y0 - center;
    if (center > y1) return center - y1;
    return 0;
  }

  final out = <List<AiStripImage>>[];
  final used = <int>{};
  for (final s in structure.systems) {
    final y0 = s.y0 * pageHeight;
    final y1 = s.y1 * pageHeight;
    final inside = <int>[];
    for (var i = 0; i < rows.length; i++) {
      if (used.contains(i)) continue;
      final center = (rows[i].y0 + rows[i].y1) / 2;
      if (center >= y0 - 4 && center <= y1 + 4) inside.add(i);
    }
    if (inside.isEmpty) continue;
    // AI 说这一组有几行就取几行（离中心最近的优先，避免把邻居行吸进来）
    final limit = s.rows.clamp(1, 3);
    final chosen = inside.length <= limit
        ? inside
        : (inside..sort((a, b) => distTo(a, y0, y1).compareTo(distTo(b, y0, y1)))).sublist(0, limit);
    chosen.sort();
    for (final i in chosen) {
      used.add(i);
    }
    out.add([for (final i in chosen) rows[i]]);
  }
  // 没有任何一组认领的行不能丢：单独成段
  for (var i = 0; i < rows.length; i++) {
    if (!used.contains(i)) out.add([rows[i]]);
  }
  return out;
}

/// 每一段用同一份通用提示词，只在前面加"这是第几段 + 这一页是哪种谱式"的上下文。
///
/// 谱式必须说清楚：单行旋律谱下面的**汉字歌词不是音符**，用双行谱的口径去问，
/// 模型很容易凭空编一个低音声部；反过来把双行谱当单行读，左手整条就丢了。
String aiLinePrompt({
  required int index,
  required int total,
  required ScoreLayoutMode layout,
  bool singleStaffOfGrand = false,
  String? knownTitle,
  String? knownKey,
  int? beats,
  int? beatType,
  int? tempo,
}) {
  final b = StringBuffer()
    ..writeln('这张图是**整页简谱里的第 ${index + 1} 段（共 $total 段）**，从上到下排列。')
    ..writeln('只识别这一段里看得见的内容，**不要**把段外（上一段/下一段）的内容写进来。')
    ..writeln('这一段的第一个音就是 start = 0，往后按谱面小节线累加。');
  if (layout == ScoreLayoutMode.singleLine) {
    b
      ..writeln('这一页是**单行旋律谱**：只有一行数字，数字**下面**那一行是歌词汉字。')
      ..writeln('所以**只输出 v1，绝对不要输出 v2**；歌词汉字不是音符，不要当成数字读，'
          '也不要因为它另起一行就以为还有第二个声部。');
  } else if (singleStaffOfGrand) {
    b
      ..writeln('这一页是**钢琴双行谱**（每一组上下两行），但这一段只截到了其中**一行**。')
      ..writeln('请先判断这一行是**高音行**还是**低音行**（低音行整行音区偏低、八度点朝下），'
          '高音行的音符写 v1、低音行的音符写 v2。')
      ..writeln('歌词汉字不是音符，不要读成音符。');
  } else {
    b
      ..writeln('这一页是**钢琴双行谱**：每一组里上下各有一行数字，'
          '上面的（高音）写 v1、下面的（低音）写 v2。')
      ..writeln('歌词汉字不是音符，不要读成音符，也不要当成第三行声部。');
  }
  final known = <String>[
    if (knownTitle != null && knownTitle.isNotEmpty) '曲名=$knownTitle',
    if (knownKey != null && knownKey.isNotEmpty) '调号=$knownKey',
    if (beats != null && beats > 0) '拍号=$beats/${beatType ?? 4}',
    if (tempo != null && tempo > 0) '速度=$tempo',
  ];
  if (known.isNotEmpty) {
    b.writeln('本曲已知信息（**原样照抄进 JSON，不要自己改**）：${known.join('，')}。');
  }
  b
    ..writeln()
    ..write(kDefaultCloudPrompt);
  return b.toString();
}

/// 单段时值"全是一个值"时的补救提示（整页版的补救提示太长，这里只要点要害）
const String kLineRhythmRetrySuffix = '''

════════ 重问一次 ════════
你刚才那一遍**时值几乎全是同一个数**，说明减时线/附点/延音线没看清。请重新逐个数一遍：
- 数字下面**一条**横线 = 0.5 拍，两条 = 0.25 拍，三条 = 0.125 拍；
- 数字**右边**一个点 = 时值 ×1.5（写在数字上下的是八度，不是附点）；
- 数字后面每一条 `-` 再加 1 拍（长音一定会有）；
- 每个小节的时值之和必须**正好等于拍号**，对不上就是漏看了。
重新输出这一段的**完整** JSON（音符一个都不能少）。''';

/// 单段没按 JSON 返回时的补救提示
const String kLineFormatRetrySuffix = '''

════════ 重问一次 ════════
你刚才没有返回要求的 JSON。请**只输出一个 JSON 对象**：
{"title":"","key":"1=C","beats":4,"beatType":4,"tempo":96,"v1":[[音级,八度,起始拍,时值],…]}
不要解释、不要 Markdown 代码块、不要输出简谱文本。''';

/// 页面顶部读到的信息
class AiPageHeader {
  final String title;
  final String keyRaw; // '1=C' / '6=A' / ''
  final int beats;
  final int beatType;
  final int tempo;

  const AiPageHeader({
    this.title = '',
    this.keyRaw = '',
    this.beats = 4,
    this.beatType = 4,
    this.tempo = 0,
  });

  static AiPageHeader fromRaw(String raw) {
    final map = extractJsonObject(raw);
    if (map == null) return const AiPageHeader();
    String str(Object? v) => v is String ? v.trim() : (v == null ? '' : '$v'.trim());
    int num_(Object? v, int dflt) {
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v.trim()) ?? dflt;
      return dflt;
    }

    final title = str(map['title'] ?? map['name'] ?? map['song']);
    final key = str(map['key'] ?? map['keyName'] ?? map['tonality']);
    final beats = num_(map['beats'] ?? map['beatsPerMeasure'], 4).clamp(1, 16);
    final beatType = num_(map['beatType'] ?? map['beatUnit'], 4).clamp(1, 32);
    final tempo = num_(map['tempo'] ?? map['bpm'], 0).clamp(0, 300);
    return AiPageHeader(
      title: cleanTitle(title),
      keyRaw: key,
      beats: beats,
      beatType: beatType,
      tempo: tempo,
    );
  }

  /// 曲名清洗：模型偶尔会写"简谱/未命名"或把数字音级抄进来。
  ///
  /// 注意**不能**把"纯数字"一律丢掉：这次的谱子曲名就叫《二十二》，
  /// 模型很可能写成 "22" —— 那是合法曲名。只有"一眼像简谱音级序列"的才丢：
  /// 带空格/逗号分隔的、或者 5 位以上的纯数字。
  static String cleanTitle(String s) {
    var t = s.trim();
    t = t.replaceAll(RegExp(r'^[《<【\[]|[》>】\]]$'), '').trim();
    if (t.isEmpty) return '';
    if (RegExp(r'^(简谱|谱子|图片|未命名|无|none|n/?a)$', caseSensitive: false).hasMatch(t)) return '';
    if (RegExp(r'[0-7][\s,.\-]+[0-7]').hasMatch(t)) return ''; // "1 2 3 4" 这种是音级，不是曲名
    if (RegExp(r'^[0-7]{5,}$').hasMatch(t)) return ''; // 5 位以上纯数字：更像是音级串
    return t;
  }
}

/// 分行识谱的完整结果
class SplitPageResult {
  final AiNotesScore score;
  final int systems;
  final int okSystems;
  final int retries;
  final AiPageHeader? header;

  /// 这一页的谱式（单行旋律谱 / 钢琴双行谱）——转换时用它决定谱号与声部
  final ScoreLayoutMode layout;

  /// 最终用来解析音高的调号（'1=F' 这种）；空表示模型也没读出调号、只能猜
  final String keyRaw;

  /// 每一段占了多少小节（诊断用）
  final List<int> measuresPerSystem;
  final List<String> diag;

  const SplitPageResult({
    required this.score,
    required this.systems,
    required this.okSystems,
    required this.retries,
    required this.header,
    required this.measuresPerSystem,
    required this.diag,
    this.layout = ScoreLayoutMode.singleLine,
    this.keyRaw = '',
  });
}

/// 分行并发识谱。
///
/// 返回 `null` 表示这一页不适合分行（切不出多段、或某段重试后仍然失败），
/// 调用方应当退回"整页一个请求"的老路径。
Future<SplitPageResult?> recognizePageByLines({
  required Uint8List imageBytes,
  required CloudRecognizer recognizer,
  int concurrency = 6,
  int maxDimension = 1800,
  int retries = 1,
  String? fallbackTitle,
  void Function(String stage, double progress)? onStage,
}) async {
  onStage?.call('正在切行…', 0.04);
  final split = await splitPageForAi(imageBytes, maxDimension: maxDimension);
  final rows = split.rows;
  if (rows.length < 2) {
    debugPrint('[ai_lines] 只切出 ${rows.length} 行谱，退回整页识别：${split.diag.join(" | ")}');
    return null; // 单行谱/切不出来：交给整页路径
  }

  final diag = <String>[...split.diag];
  // 页眉（曲名/调号/拍号）与版面结构（哪几行是一组、单行还是双行）同时发出去：
  // 两者互不依赖，串行发会白白多等一次往返。
  final headerFuture = _readHeader(split, recognizer);
  final probeFuture = _probeLayout(imageBytes, recognizer);

  // 先等版面结构：分段要按它来分
  final structure = await probeFuture;
  final segments = <List<AiStripImage>>[];
  var pageLayout = split.mode;
  if (structure != null && !structure.isEmpty) {
    pageLayout = structure.dominantMode;
    final snapped = snapStructureToRows(structure, split);
    final claimed = snapped.fold<int>(0, (a, seg) => a + seg.length);
    // AI 分组只认领了一部分行时，说明它的坐标/分组跟本地行对不上，
    // 这时宁可用本地几何分组（两页实测：本地分组已经正确）。
    if (snapped.isNotEmpty && claimed * 10 >= rows.length * 7) {
      segments.addAll(snapped);
      diag.add('AI 判版面：layout=${structure.layout.isEmpty ? "?" : structure.layout}，'
          '${structure.systems.length} 组（rows=${structure.systems.map((s) => s.rows).join("/")}），'
          '认领 $claimed/${rows.length} 行 → ${segments.length} 段');
    } else {
      diag.add('AI 判版面只认领 $claimed/${rows.length} 行，改用本地几何分组');
    }
  }
  if (segments.isEmpty) {
    segments.addAll(split.localSegments);
    diag.add('用本地几何分组：${segments.length} 段（'
        '${pageLayout == ScoreLayoutMode.grandStaff ? "钢琴双行谱" : "单行旋律谱"}）');
  }
  // 每一段自己带"几行谱"（混排页面也能分别处理）；整页谱式另算（用于最后的声部取舍）
  final segIsGrand = <bool>[
    for (final seg in segments) seg.length >= 2,
  ];
  final grandSegments = segIsGrand.where((g) => g).length;
  if (grandSegments * 2 > segments.length) pageLayout = ScoreLayoutMode.grandStaff;
  diag.add('整页谱式：${pageLayout == ScoreLayoutMode.grandStaff ? "钢琴双行谱" : "单行旋律谱"}'
      '（${grandSegments}/${segments.length} 段是两行谱）');

  var done = 0;
  var retried = 0;
  var failed = 0;
  var empty = 0;
  final composed = <Uint8List>[];
  for (final seg in segments) {
    composed.add(await composeRowStrips(seg));
  }

  final parts = await mapConcurrent<int, _LinePart>(
    List<int>.generate(segments.length, (i) => i),
    concurrency,
    (index, _) async {
      final part = await _recognizeLine(
        png: composed[index],
        index: index,
        total: segments.length,
        layout: pageLayout,
        singleStaffOfGrand: pageLayout == ScoreLayoutMode.grandStaff && !segIsGrand[index],
        recognizer: recognizer,
        retries: retries,
      );
      done++;
      if (part.retried) retried++;
      if (part.score == null) {
        failed++;
      } else if (part.score!.notes.isEmpty) {
        empty++;
      }
      onStage?.call('已识别 $done/${segments.length} 段', 0.1 + 0.75 * done / segments.length);
      return part;
    },
  );

  final header = await headerFuture;
  // 页眉那一路只裁了页面顶部一条，调号/速度行有时压在裁切线下面；版面判断那一路
  // 看的是整页，正好用来兜底（曲名、调号都对不上时以页眉为准，它是放大过的）。
  final titleFromProbe = structure?.title ?? '';
  final keyFromProbe = structure?.keyRaw ?? '';
  if (header != null) {
    diag.add('页眉：曲名「${header.title}」调号 ${header.keyRaw.isEmpty ? "?" : header.keyRaw} '
        '${header.beats}/${header.beatType}${header.tempo > 0 ? " ♩=${header.tempo}" : ""}');
  }
  if (structure != null && (titleFromProbe.isNotEmpty || keyFromProbe.isNotEmpty)) {
    diag.add('整页判断：曲名「$titleFromProbe」调号 ${keyFromProbe.isEmpty ? "?" : keyFromProbe}');
  }
  if (failed > 0) {
    diag.add('$failed 段识别失败，已退回整页识别');
    debugPrint('[ai_lines] $failed/${segments.length} 段失败，退回整页识别：'
        '${parts.map((p) => p.error ?? (p.score == null ? "无音符" : "ok(${p.score!.notes.length})")).join(" ")}');
    return null;
  }
  // 空段本身不算错（版面里可能混进页码/信息行），但**半页以上都是空**就说明切错了
  if (empty * 2 > segments.length) {
    diag.add('$empty/${segments.length} 段没有音符，疑似切错行，已退回整页识别');
    debugPrint('[ai_lines] $empty/${segments.length} 段为空，退回整页识别');
    return null;
  }

  // 每段单独解析时模型看不到调号，必须用**统一调号**重新解析一遍，
  // 否则各段自己猜的调号会把音高整体带偏（差一个调号就是差几个半音）。
  // 优先用页眉读到的调号，其次用整页版面判断读到的，最后才取各段的"多数票"——
  // 实测：各段都看不到调号时会**集体默认成 1=C**，多数票反而会把 1=F 投掉。
  var keyRaw = header != null && header.keyRaw.isNotEmpty
      ? header.keyRaw
      : (keyFromProbe.isNotEmpty ? keyFromProbe : null);
  if (keyRaw == null) {
    final votes = <String, int>{};
    for (final p in parts) {
      final spec = _keySpecOfRaw(p.raw);
      if (spec != null && spec.isNotEmpty) votes[spec] = (votes[spec] ?? 0) + 1;
    }
    if (votes.isNotEmpty) {
      final sorted = votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      keyRaw = sorted.first.key;
      diag.add('页眉没给调号，各段按多数票取 $keyRaw'
          '（${sorted.map((e) => "${e.key}×${e.value}").join(" ")}）');
    }
  }
  final fixed = <AiNotesScore>[];
  for (final p in parts) {
    final text = p.raw;
    final rescored = (text == null || text.isEmpty)
        ? p.score
        : (parseAiNotes(text, keyOverride: keyRaw) ?? p.score);
    if (rescored != null) fixed.add(rescored);
  }
  if (fixed.isEmpty) {
    diag.add('所有段都没有解析出音符，已退回整页识别');
    return null;
  }

  final first = fixed.first;
  final beats = header?.beats ?? first.beats;
  final beatType = header?.beatType ?? first.beatType;
  final tempo = (header != null && header.tempo > 0) ? header.tempo : first.tempo;
  // 曲名：页眉（放大过）> 整页判断 > 文件名兜底 > 某一段自己写的
  final title = (header != null && header.title.isNotEmpty)
      ? header.title
      : (titleFromProbe.isNotEmpty ? titleFromProbe : (fallbackTitle ?? first.title));

  final assembled = assembleLineParts(
    parts: fixed,
    title: title,
    keyName: first.keyName,
    beats: beats,
    beatType: beatType,
    tempo: tempo,
  );
  if (assembled.score.notes.isEmpty) {
    diag.add('拼接后没有任何音符，已退回整页识别');
    return null;
  }

  // 单行旋律谱：如果模型还是编出一个"低音声部"（往往是把歌词行当成了数字行），
  // 只要它少得可怜就丢掉——单行谱本来就只有一个声部。
  // 注意判断依据是**整页谱式**，不是"这一段几行"：钢琴谱里某段只切到一行时，
  // 用段的行数判断会把整条低音声部误丢（实测踩过）。
  var score = assembled.score;
  if (pageLayout == ScoreLayoutMode.singleLine) {
    final v1 = score.notes.where((n) => n.staff == 1).length;
    final v2 = score.notes.where((n) => n.staff == 2).length;
    if (v2 > 0 && v2 * 3 < v1) {
      score = AiNotesScore(
        title: score.title,
        keyName: score.keyName,
        beats: score.beats,
        beatType: score.beatType,
        tempo: score.tempo,
        notes: score.notes.where((n) => n.staff == 1).toList(),
      );
      diag.add('单行旋律谱：丢弃可疑的第二声部 $v2 个音（占 v1 的 ${(v2 * 100 / (v1 == 0 ? 1 : v1)).round()}%）');
    }
  }

  diag.add('分行并发：${segments.length} 段（'
      '${pageLayout == ScoreLayoutMode.grandStaff ? "钢琴双行谱" : "单行旋律谱"}），'
      '共 ${score.notes.length} 个音，每段小节数 ${assembled.measuresPerSystem.join("/")}');

  return SplitPageResult(
    score: score,
    systems: segments.length,
    okSystems: fixed.length,
    retries: retried,
    header: header,
    measuresPerSystem: assembled.measuresPerSystem,
    diag: diag,
    layout: pageLayout,
    keyRaw: keyRaw ?? '',
  );
}

/// 拼接结果
class LineAssembly {
  final AiNotesScore score;

  /// 每一段占了多少小节
  final List<int> measuresPerSystem;

  const LineAssembly(this.score, this.measuresPerSystem);
}

/// 把各段按小节顺接成一份乐谱
///
/// 每一段的时长按"最近的完整小节数"折算，再作为下一段的起点偏移。
/// 简谱排版基本都在小节线处换行，所以这个折算几乎总是精确的。
LineAssembly assembleLineParts({
  required List<AiNotesScore> parts,
  required String title,
  required String keyName,
  required int beats,
  required int beatType,
  required int tempo,
}) {
  final cap = measureTicksOf(beats, beatType);
  final notes = <AiNoteEvent>[];
  final measures = <int>[];
  var offset = 0.0;
  for (final p in parts) {
    if (p.notes.isEmpty) {
      measures.add(0);
      continue;
    }
    var end = 0.0;
    for (final n in p.notes) {
      end = math.max(end, n.start + n.dur);
    }
    final count = math.max(1, (end / cap).round());
    for (final n in p.notes) {
      notes.add(AiNoteEvent(
        staff: n.staff,
        midi: n.midi,
        start: n.start + offset,
        dur: n.dur,
        lyric: n.lyric,
        degree: n.degree,
        octave: n.octave,
        accidental: n.accidental,
      ));
    }
    measures.add(count);
    offset += count * cap;
  }
  return LineAssembly(
    AiNotesScore(
      title: title,
      keyName: keyName,
      beats: beats,
      beatType: beatType,
      tempo: tempo,
      notes: notes,
    ),
    measures,
  );
}

class _LinePart {
  final AiNotesScore? score;
  final String? raw;
  final bool retried;

  /// 失败原因（网络异常 / 没解析出 JSON），诊断用
  final String? error;

  const _LinePart(this.score, this.raw, {this.retried = false, this.error});
}

Future<AiPageHeader?> _readHeader(AiPageSplit split, CloudRecognizer recognizer) async {
  final header = split.header;
  if (header == null) return null;
  try {
    final r = await recognizer.recognize(header.png, mimeType: 'image/png', promptOverride: kAiHeaderPrompt);
    final text = (r.raw != null && r.raw!.isNotEmpty) ? r.raw! : r.jianpuText;
    return AiPageHeader.fromRaw(text);
  } catch (_) {
    return null; // 页眉读不到不影响正文，调号会退回用第一段自己的判断
  }
}

/// 让 AI 判版面结构（不识别音符）。失败返回 null，调用方退回本地几何分组。
///
/// 看的是**整页原图**：只有看全页才能判断"哪几行属于一组、是单行还是双行"。
Future<AiPageStructure?> _probeLayout(Uint8List pageBytes, CloudRecognizer recognizer) async {
  try {
    final r = await recognizer.recognize(pageBytes,
        mimeType: _sniffMime(pageBytes), promptOverride: kAiLayoutPrompt);
    final text = (r.raw != null && r.raw!.isNotEmpty) ? r.raw! : r.jianpuText;
    final st = AiPageStructure.fromRaw(text);
    return st.isEmpty ? null : st;
  } catch (_) {
    return null; // 版面判断失败不影响主流程（会退回本地几何分组）
  }
}

/// 按文件头猜 MIME（整页原图可能是 JPEG 也可能是 PNG）
String _sniffMime(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

Future<_LinePart> _recognizeLine({
  required Uint8List png,
  required int index,
  required int total,
  required ScoreLayoutMode layout,
  bool singleStaffOfGrand = false,
  required CloudRecognizer recognizer,
  required int retries,
}) async {
  var attempt = 0;
  var retried = false;
  var rhythmRetry = false;
  while (true) {
    final suffix = rhythmRetry ? kLineRhythmRetrySuffix : (retried ? kLineFormatRetrySuffix : '');
    final prompt = aiLinePrompt(
          index: index,
          total: total,
          layout: layout,
          singleStaffOfGrand: singleStaffOfGrand,
        ) +
        suffix;
    try {
      final r = await recognizer.recognize(png, mimeType: 'image/png', promptOverride: prompt);
      final text = (r.raw != null && r.raw!.isNotEmpty) ? r.raw! : r.jianpuText;
      final score = parseAiNotes(text);
      if (score == null) {
        // "这一行没有音符"是合法结果（版面里混进了副标题/页码/信息行）：
        // 只有"连 JSON 都不是"才算失败，否则整页会白退回一次。
        if (_isJsonWithoutNotes(text)) {
          return _LinePart(const AiNotesScore(), text, retried: retried);
        }
        if (attempt >= retries) {
          return _LinePart(null, text, error: '没解析出 JSON：${text.length > 80 ? text.substring(0, 80) : text}');
        }
        attempt++;
        retried = true;
        continue;
      }
      // 时值全是一个值 = 减时线没看清，单独把这一段重问一次
      if (!retried && attempt < retries && _looksFlat(score)) {
        attempt++;
        retried = true;
        rhythmRetry = true;
        continue;
      }
      return _LinePart(score, text, retried: retried);
    } catch (e) {
      if (attempt >= retries) return _LinePart(null, null, error: '$e');
      attempt++;
      retried = true;
      await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
    }
  }
}

/// 从一段的原始返回里取出模型自己写的调号（'1=C' / '6=A'）
String? _keySpecOfRaw(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final map = extractJsonObject(raw);
  if (map == null) return null;
  final v = map['key'] ?? map['keyName'] ?? map['tonality'];
  if (v is! String) return null;
  final s = v.trim();
  return s.isEmpty ? null : s;
}

/// 这一段是不是"返回了合法 JSON、但里面确实没有音符"
bool _isJsonWithoutNotes(String text) {
  final map = extractJsonObject(text);
  if (map == null) return false;
  for (final k in ['v1', 'v2', 'staff1', 'staff2', 'notes', 'noteEvents', 'events']) {
    final v = map[k];
    if (v is List && v.isNotEmpty) return false;
  }
  return true;
}

/// 这一段是不是"时值全一样"（音符够多、但时值种类只有 1 种）
bool _looksFlat(AiNotesScore score) {
  final notes = score.notes.where((n) => n.dur > 0).toList();
  if (notes.length < 6) return false;
  final hist = durationHistogram(notes);
  return hist.length <= 1;
}

/// 简单的"限量并发 map"：保持输入顺序，最多同时跑 [limit] 个任务
Future<List<T>> mapConcurrent<I, T>(
  List<I> items,
  int limit,
  Future<T> Function(I item, int index) task,
) async {
  final out = List<T?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      out[i] = await task(items[i], i);
    }
  }

  final n = math.max(1, math.min(limit, items.length));
  await Future.wait(List.generate(n, (_) => worker()));
  return out.cast<T>();
}
