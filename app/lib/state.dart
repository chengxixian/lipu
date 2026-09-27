/// 全局状态（ChangeNotifier，无需额外状态管理依赖）
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'core/model.dart';
import 'core/parse.dart';
import 'omr/ai_lines.dart';
import 'omr/ai_notes.dart';
import 'omr/cloud_recognizer.dart';
import 'omr/omr.dart';
import 'omr/octave_hint.dart';
import 'omr/omr_service.dart';

const String kSampleJianpu = '''标题：小星星
词：佚名
1=C 4/4 ♩=96
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |
5 5 4 4 | 3 3 2 - | 5 5 4 4 | 3 3 2 - |
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]''';

const String kSampleJianpu2 = '''标题：茉莉花（片段）
1=D 4/4 ♩=72
3 3 5 6 | 1' 6 5 6 | 5 5 3 5 | 6 - - - |
3 3 5 6 | 1' 6 5 6 | 5 5 3 5 | 6 - - - |]''';

/// 待识别的图片（多选时一次传进来若干张）
class RecognizeInput {
  final String name;
  final Uint8List bytes;
  const RecognizeInput(this.name, this.bytes);
}

/// 一张图的识别产物（并发识别时用它把结果带回来，不写共享字段）
class _PageOutcome {
  final OmrPage? page;

  /// 结构化路径出来的乐谱（时值是精确数字）；走文本兜底时为 null
  final Score? aiScore;

  /// 结构化的音符事件（多页统一调号时要拿它重算一遍音高）
  final AiNotesScore? aiNotes;

  /// 解析这一页时用的调号；空 = 模型没读到调号
  final String? keyRaw;

  /// 这一页是不是单行旋律谱（重算乐谱时要用同一个谱号判断）
  final bool singleLine;

  final String? octaveNote;
  final String? splitNote;
  final String? error;

  const _PageOutcome({
    this.page,
    this.aiScore,
    this.aiNotes,
    this.keyRaw,
    this.singleLine = true,
    this.octaveNote,
    this.splitNote,
    this.error,
  });

  factory _PageOutcome.error(String message) => _PageOutcome(error: message);

  /// 统一调号后重建这一页（乐谱与简谱文本都要跟着变）
  _PageOutcome withScore(Score score, String key) => _PageOutcome(
        page: page == null
            ? null
            : OmrPage(
                page!.name,
                page!.bytes,
                OmrOutcome(omrResultFromText(toJianpu(score), source: 'AI 识谱（统一调号）', selectAll: true),
                    null, null, 0, 0),
              ),
        aiScore: score,
        aiNotes: aiNotes == null ? null : rekeyAiScore(aiNotes!, key),
        keyRaw: key,
        singleLine: singleLine,
        octaveNote: octaveNote,
        splitNote: splitNote,
        error: error,
      );
}

/// 一次识别结果的节奏质量（用来决定要不要补救重问、以及报告给用户）
class RhythmVerdict {
  final int count;
  final int distinct;
  final double dominant;
  final bool flat;
  const RhythmVerdict({
    required this.count,
    required this.distinct,
    required this.dominant,
    required this.flat,
  });
}

/// 一张谱子图片的识别结果
class OmrPage {
  final String name;
  final Uint8List bytes;
  final OmrOutcome outcome;
  const OmrPage(this.name, this.bytes, this.outcome);
}

class AppState extends ChangeNotifier {
  AppState() {
    setText(kSampleJianpu);
  }

  String _text = kSampleJianpu;
  Score? _score;
  Uint8List? _imageBytes;
  OmrOutcome? _omr;
  bool _busy = false;
  String? _status;
  bool _showLyrics = true;
  bool _showTitle = true;
  double _zoom = 1.0;
  double _playbackTempo = 1.0;
  CloudConfig _cloud = const CloudConfig();

  final String _lastSource = '';

  /// 一次可以选多张谱子：每张图一"页"，识别结果按页合并成一份简谱
  final List<OmrPage> _pages = [];
  final List<String> _pageErrors = [];

  /// 测试用：注入假的识谱后端，避免真实网络请求
  @visibleForTesting
  Future<String> Function(RecognizeInput input)? debugRecognizeHook;

  /// 识别进度（0..1）与当前阶段说明，用于界面上的确定性进度条
  double _omrProgress = 0;
  String _omrStage = '';
  int _omrImageIndex = 0;
  int _omrImageTotal = 0;

  Timer? _debounce;

  /// AI 识谱时用来估算进度的计时器（HTTP 请求拿不到真实进度）
  Timer? _progressTimer;
  DateTime? _requestStart;

  String get text => _text;
  Score? get score => _score;
  Uint8List? get imageBytes => _imageBytes;
  OmrOutcome? get omr => _omr;
  List<OmrPage> get pages => List.unmodifiable(_pages);
  List<String> get pageErrors => List.unmodifiable(_pageErrors);

  /// 识别进度（0..1）
  double get omrProgress => _omrProgress;

  /// 进度说明，如"识别第 2/3 行"
  String get omrStage => _omrStage;

  /// 多张图时的"第几张"
  int get omrImageIndex => _omrImageIndex;
  int get omrImageTotal => _omrImageTotal;

  /// 上一次识别用的引擎说明（界面上显示"本次：AI 识谱"）
  String get lastSource => _lastSource;

  /// 上一次 AI 识谱的结构化结果（模型直接给音符事件时非空）
  Score? _lastAiScore;
  Score? get lastAiScore => _lastAiScore;

  /// 结构化识谱得到的音数（界面显示用）
  int get lastAiNoteCount => _lastAiScore?.pitchCount ?? 0;

  bool get busy => _busy;
  String? get status => _status;
  bool get showLyrics => _showLyrics;
  bool get showTitle => _showTitle;
  double get zoom => _zoom;
  double get playbackTempo => _playbackTempo;
  CloudConfig get cloud => _cloud;
  List<String> get warnings => _score?.meta.warnings ?? const [];

  void setZoom(double v) {
    _zoom = v.clamp(0.4, 3.0);
    notifyListeners();
  }

  void setPlaybackTempo(double v) {
    _playbackTempo = v.clamp(0.4, 2.0);
    notifyListeners();
  }

  void toggleLyrics(bool v) {
    _showLyrics = v;
    notifyListeners();
  }

  void toggleTitle(bool v) {
    _showTitle = v;
    notifyListeners();
  }

  /// 文本变化：防抖后重新解析
  void setText(String value, {bool immediate = false}) {
    _text = value;
    _debounce?.cancel();
    if (immediate) {
      _parseNow();
    } else {
      _debounce = Timer(const Duration(milliseconds: 350), _parseNow);
    }
    notifyListeners();
  }

  void _parseNow() {
    try {
      _score = parseJianpu(_text);
      _status = null;
    } catch (e) {
      _status = '解析失败：$e';
    }
    notifyListeners();
  }

  /* ------------------------------------------------------------------ *
   * 谱面直接编辑（拖音符改音高/位置/时值）+ 撤销
   * ------------------------------------------------------------------ */

  final List<String> _undoStack = [];
  bool get canUndo => _undoStack.isNotEmpty;

  void _pushUndo() {
    _undoStack.add(_text);
    if (_undoStack.length > 60) _undoStack.removeAt(0);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _text = _undoStack.removeLast();
    try {
      _score = parseJianpu(_text);
      _status = null;
    } catch (e) {
      _status = '撤销后解析失败：$e';
    }
    notifyListeners();
  }

  /// 外部（测试）或界面改完乐谱后统一回写：文本与模型保持一致
  void _applyScore(Score score) {
    _score = score;
    _text = toJianpu(score);
    notifyListeners();
  }

  /// 解析界面传来的音符 id：`lipu-小节-声部-条目-音-片段`
  static ({int measure, int voice, int item, int tone})? parseNoteId(String id) {
    final parts = id.split('-');
    if (parts.length < 6 || parts[0] != 'lipu') return null;
    final m = int.tryParse(parts[1]);
    final v = int.tryParse(parts[2]);
    final it = int.tryParse(parts[3]);
    final tone = int.tryParse(parts[4]);
    if (m == null || v == null || it == null || tone == null) return null;
    return (measure: m, voice: v, item: it, tone: tone);
  }

  /// 把 id 里的"第几个条目"换掉（其它段原样保留），用于改完之后重新定位音符
  static String withItem(String noteId, int item) {
    final parts = noteId.split('-');
    if (parts.length < 6) return noteId;
    parts[3] = '$item';
    return parts.join('-');
  }

  /// 谱面上拖动一个音符：一次调用同时处理音高（[stepDelta] 级）和位置（[gridDelta] 格）。
  ///
  /// 拖动只应该算**一步**撤销，所以不能简单地先后调 [moveNotePitch] 与
  /// [moveNoteStart]（那样会压两次撤销栈，撤销一次只回去一半）。
  ///
  /// 返回改完之后这个音符的**新 id**（挪位置会改变条目序号，id 跟着变），
  /// 拿不到就返回 null。
  String? nudgeNote(String noteId, {int stepDelta = 0, int gridDelta = 0, double grid = 0.25}) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null) return null;
    if (stepDelta == 0 && gridDelta == 0) return null;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return null;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return null;
    final note = items[ref.item];
    if (note is! NoteItem) return null;
    // 拖的是"从低到高第 tone 个符头"，不能拿 note.degree 当它——
    // 和弦里 note.degree 永远是最低音，读错了就会把别的音改掉。
    final cur = toneAt(note, ref.tone, score.key);
    if (cur == null) return null;

    _pushUndo();
    if (stepDelta != 0) {
      // 音级就是"一条线/一个间"的距离：+1 相当于简谱 1→2；7 再往上要进八度，1 往下要退八度
      var d = cur.degree + stepDelta;
      var oct = cur.octave;
      while (d > 7) {
        d -= 7;
        oct += 1;
      }
      while (d < 1) {
        d += 7;
        oct -= 1;
      }
      // 拖飞了（比如拖动刻度没量准）也别把音扔到听不见的地方
      oct = oct.clamp(-4, 4);
      replaceNoteTone(note, ref.tone, d, oct, cur.accidental, score.key);
    }
    var item = ref.item;
    if (gridDelta != 0) {
      // 改位置必须放在改音高之后：_reflowVoice 可能重排/删除条目，
      // 而 replaceNoteTone 只动音高，不会让 ref.item 失效。
      final start = _startOf(items, item);
      _reflowVoice(items, item, start + gridDelta * grid);
      final moved = items.indexOf(note);
      if (moved >= 0) item = moved;
    }
    _applyScore(score);
    return item == ref.item ? noteId : withItem(noteId, item);
  }

  /// 「连音」：把这个音和**后一个音**连起来（连音线），再点一次取消。
  /// 返回改完之后这个音的 id。
  String? toggleTie(String noteId) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null) return null;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return null;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return null;
    final note = items[ref.item];
    if (note is! NoteItem) return null;

    _pushUndo();
    final on = !note.tieToNext;
    note.tieToNext = on;
    // 下一个音符要相应地标上"从前面连过来"，记谱才对
    if (ref.item + 1 < items.length && items[ref.item + 1] is NoteItem) {
      (items[ref.item + 1] as NoteItem).tieToPrev = on;
    }
    _applyScore(score);
    return noteId;
  }

  /// 「插入」：在这个音**后面**插一个同样时值的内容（音符或休止符）。
  /// 后面的内容整体后移，超出小节的部分被截断，小节总长不变。
  /// 返回插入进来那个新条目的 id。
  String? insertAfter(String noteId, {bool asRest = false}) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null) return null;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return null;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return null;
    final src = items[ref.item];
    if (src is! NoteItem) return null;

    final len = src.ticks;
    final before = _voiceLength(items);
    // 插入的语义：**放得下就变长，放不下就挤掉末尾**（小节长度不超过容量）
    final cap = measureTicksOf(score.meta.beats, score.meta.beatType);
    final target = math.min(cap, before + len);
    final at = _startOf(items, ref.item) + len;
    _pushUndo();
    final Item nu = asRest
        ? RestItem(ticks: len)
        : (NoteItem(
            degree: src.degree,
            octave: src.octave,
            accidental: src.accidental,
            ticks: len,
          )..chord.addAll(src.chord.map((t) => t.clone())));
    items.insert(ref.item + 1, nu);
    // 复用时间轴重建：把新条目放到 at，后面的顺延，超出的截断到目标长度
    _reflowVoice(items, ref.item + 1, at, forceTotal: target);
    _applyScore(score);
    final at2 = items.indexOf(nu);
    if (at2 < 0) return null;
    return withItem(noteId, at2);
  }

  /// 「升降调」：给被点的那个符头加/改变音记号（'' | '#' | 'b' | 'n'）
  String? setToneAccidental(String noteId, String accidental) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null) return null;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return null;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return null;
    final note = items[ref.item];
    if (note is! NoteItem) return null;
    final cur = toneAt(note, ref.tone, score.key);
    if (cur == null) return null;
    if (cur.accidental == accidental) return noteId;

    _pushUndo();
    replaceNoteTone(note, ref.tone, cur.degree, cur.octave, accidental, score.key);
    _applyScore(score);
    return noteId;
  }

  /// 「连音」选第二个音：把 [fromId] 和 [toId] 连起来。
  ///
  /// **按音高自动选记号**：
  ///   · 两个音**音高相同、而且在时间上紧挨着** → 连音线（tie）
  ///   · 音高不同、或中间夹着别的音 → 圆滑线（slur）
  /// 这两种都叫"连音线"，但只有 tie 有"必须同音高且相邻"的硬性要求；
  /// 音高不同却硬写成 tie，MusicXML 是无效的，排版引擎**不会画**
  /// （用户反馈"有的音符连音之后没有连音号"）。
  String? tieBetween(String fromId, String toId) {
    final a = parseNoteId(fromId);
    final b = parseNoteId(toId);
    final score = _score;
    if (a == null || b == null || score == null) return null;
    if (a.measure < 0 || a.measure >= score.measures.length) return null;
    if (b.measure < 0 || b.measure >= score.measures.length) return null;
    final ia = a.voice == 2 ? score.measures[a.measure].items2 : score.measures[a.measure].items;
    final ib = b.voice == 2 ? score.measures[b.measure].items2 : score.measures[b.measure].items;
    if (a.item < 0 || a.item >= ia.length) return null;
    if (b.item < 0 || b.item >= ib.length) return null;
    final na = ia[a.item];
    final nb = ib[b.item];
    if (na is! NoteItem || nb is! NoteItem) return null;

    // 时间上是否紧挨着（同一小节的下一个条目，或下一小节的第一个条目）
    var adjacent = a.voice == b.voice &&
        ((a.measure == b.measure && b.item == a.item + 1) ||
            (b.measure == a.measure + 1 && b.item == 0 && a.item == ia.length - 1));
    final samePitch = notePitches(na, score.key).first.midi ==
        notePitches(nb, score.key).first.midi;
    final asTie = adjacent && samePitch;

    _pushUndo();
    // 先清掉两头可能存在的旧记号，避免同时挂着 tie 和 slur
    na.tieToNext = false;
    nb.tieToPrev = false;
    na.slurToNext = false;
    nb.slurToPrev = false;
    if (asTie) {
      na.tieToNext = true;
      nb.tieToPrev = true;
    } else {
      na.slurToNext = true;
      nb.slurToPrev = true;
    }
    _applyScore(score);
    return toId; // 选中连音线的终点，用户能马上接着改它
  }

  /// 「和弦」：在这个音上再叠一个音（三度叠置：往上加一级+2），
  /// 反复点就能叠出 1–3–5 这样的和弦。返回这个音（和弦）的 id。
  String? addChordTone(String noteId) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null) return null;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return null;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return null;
    final note = items[ref.item];
    if (note is! NoteItem) return null;

    final tones = sortedTones(note, score.key);
    // 以当前**最高**的音为基准往上加三度（1→3、3→5、5→7…），8 度以上自动进位
    final top = tones.last;
    var d = top.degree + 2;
    var oct = top.octave;
    while (d > 7) {
      d -= 7;
      oct += 1;
    }
    if (tones.any((t) => t.degree == d && t.octave == oct && t.accidental == '')) {
      return noteId; // 已经有了，别叠重复音
    }
    _pushUndo();
    // 注意 applyPitchesToNote 的语义：它只吃"附加音"，主音自己会带上，
    // 所以这里传"已有的和弦音 + 新加的那个"，不能把主音也算进去（会重复）。
    applyPitchesToNote(
      note,
      [...tones.skip(1).map((t) => t.clone()), ChordTone(degree: d, octave: oct)],
      score.key,
    );
    _applyScore(score);
    return noteId;
  }

  /// 「删除」：把音符去掉，位置留成休止符（小节长度不变）。
  String? deleteNote(String noteId) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null) return null;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return null;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return null;
    final note = items[ref.item];
    if (note is! NoteItem) return null;

    _pushUndo();
    final ticks = note.ticks;
    // 用同时值的休止符顶上，小节总长不变
    items[ref.item] = RestItem(ticks: ticks);
    // 删掉的是连音的一端时，另一端也跟着摘掉，免得留下半截连音线
    if (ref.item + 1 < items.length && items[ref.item + 1] is NoteItem) {
      (items[ref.item + 1] as NoteItem).tieToPrev = false;
    }
    _applyScore(score);
    return null; // 音符没了，不再选中
  }

  /// 「八度 ±」：把被点的那个符头整体升降一个八度。
  ///
  /// 为什么需要它：八度点是简谱里最小的记号（扫描件里常常只有 1~2 像素），
  /// 视觉模型读它并不稳定（实测同一张图两次跑出相反的错）。与其反复调提示词，
  /// 不如给用户一个**一键修**的入口：点一下音符 → 气泡里按「八度− / 八度+」。
  String? shiftOctave(String noteId, int delta) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null || delta == 0) return null;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return null;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return null;
    final note = items[ref.item];
    if (note is! NoteItem) return null;
    final cur = toneAt(note, ref.tone, score.key);
    if (cur == null) return null;

    _pushUndo();
    replaceNoteTone(note, ref.tone, cur.degree, (cur.octave + delta).clamp(-4, 4),
        cur.accidental, score.key);
    _applyScore(score);
    return noteId;
  }

  /// 拖动改音高：把第 [tone] 个音换成新的音级/八度/变音记号
  void moveNotePitch(String noteId, int degree, int octave, String accidental) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null) return;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return;
    final measure = score.measures[ref.measure];
    final items = ref.voice == 2 ? measure.items2 : measure.items;
    if (ref.item < 0 || ref.item >= items.length) return;
    final item = items[ref.item];
    if (item is! NoteItem) return;
    _pushUndo();
    replaceNoteTone(item, ref.tone, degree, octave, accidental, score.key);
    _applyScore(score);
  }

  /// 拖动改位置：在小节里前后挪（[deltaUnits] 是十六分网格数，正数往后）
  void moveNoteStart(String noteId, int deltaUnits, {double grid = 0.25}) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null || deltaUnits == 0) return;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return;
    if (items[ref.item] is! NoteItem) return;

    final start = _startOf(items, ref.item);
    _pushUndo();
    _reflowVoice(items, ref.item, start + deltaUnits * grid);
    _applyScore(score);
  }

  /// 时长模式：把某个音的时值改成 [ticks]（四分音符 = 1）。
  /// 变长会吃掉后面的内容、变短会补休止符，**小节总时值不变**。
  ///
  /// 返回改完之后这个音符的 id（通常不变），改不动就返回 null。
  String? setNoteDuration(String noteId, double ticks) {
    final ref = parseNoteId(noteId);
    final score = _score;
    if (ref == null || score == null || ticks <= 0) return null;
    if (ref.measure < 0 || ref.measure >= score.measures.length) return null;
    final items = ref.voice == 2 ? score.measures[ref.measure].items2 : score.measures[ref.measure].items;
    if (ref.item < 0 || ref.item >= items.length) return null;
    final note = items[ref.item];
    if (note is! NoteItem) return null;

    final start = _startOf(items, ref.item);
    final total = _voiceLength(items);
    var wanted = ticks;
    if (start + wanted > total) wanted = total - start;
    if (wanted <= kEps || (wanted - note.ticks).abs() < kEps) return null;

    _pushUndo();
    // 注意：新时值是交给 _reflowVoice 去改的——它必须先按"改动前"的状态
    // 算好各条目起点与总长，否则改完再算就全乱了。
    _reflowVoice(items, ref.item, start, newLength: wanted);
    _applyScore(score);
    final at = items.indexOf(note);
    return at < 0 || at == ref.item ? noteId : withItem(noteId, at);
  }

  /// 声部里第 [index] 个条目在小节里的起点
  double _startOf(List<Item> items, int index) {
    var t = 0.0;
    for (var i = 0; i < index && i < items.length; i++) {
      t += items[i].ticks;
    }
    return t;
  }

  double _voiceLength(List<Item> items) => items.fold(0.0, (a, it) => a + it.ticks);

  /// 把第 [index] 个条目挪到 [newStart]（时间轴重建）：
  /// 空出来的时间补休止符，落点上重叠的内容被截断或吃掉。声部总长保持不变。
  ///
  /// [newLength] 不为空时同时改这个条目的时值（改时值走这里，才能拿到改动前的
  /// 起点与总长）。
  /// [forceTotal] 不为空时用这个总长（"插入"要先往列表里塞一个条目，
  /// 这时列表总长已经变长，但小节长度必须保持原样）。
  void _reflowVoice(List<Item> items, int index, double newStart,
      {double? newLength, double? forceTotal}) {
    // 先按"改动前"的状态快照
    final starts = <double>[];
    var t = 0.0;
    for (final it in items) {
      starts.add(t);
      t += it.ticks;
    }
    final total = forceTotal ?? t;
    final moved = items[index];
    if (newLength != null) moved.ticks = newLength;
    final len = moved.ticks;
    final target = newStart.clamp(0.0, math.max(0.0, total - len)).toDouble();
    if (moved is NoteItem) {
      moved.tieToPrev = false;
      moved.tieToNext = false;
    }

    // 注意：**不能**因为起点没变就提前返回 —— 改时值（变长/变短）时起点不变，
    // 但后面的内容必须按新长度重新截断/补休止符。
    // 其它条目先按原位置摆好
    final kept = <(double, Item)>[];
    for (var i = 0; i < items.length; i++) {
      if (i == index) continue;
      kept.add((starts[i], items[i]));
    }
    // 与移动后的音重叠：能截就截，整个被盖住就丢掉
    final surviving = <(double, Item)>[];
    for (final (s, it) in kept) {
      final e = s + it.ticks;
      if (e <= target + kEps || s >= target + len - kEps) {
        surviving.add((s, it));
        continue;
      }
      if (s < target - kEps) {
        it.ticks = target - s;
        surviving.add((s, it));
      } else if (e > target + len + kEps) {
        final newLen = e - (target + len);
        it.ticks = newLen;
        surviving.add((target + len, it));
      }
      // 否则完全被覆盖 -> 丢弃
    }
    surviving.add((target, moved));
    surviving.sort((a, b) => a.$1.compareTo(b.$1));

    items.clear();
    var cursor = 0.0;
    for (final (s, it) in surviving) {
      // 超出小节长度（total）的内容：能截就截，整条都在外面就丢掉。
      // 平时 total 就是列表原长，这里不会丢东西；"插入"时 total 是插入前的长度，
      // 靠这一步把小节末尾挤出去。
      if (s >= total - kEps) continue;
      if (s + it.ticks > total + kEps) it.ticks = total - s;
      if (it.ticks <= kEps) continue;
      if (s > cursor + kEps) items.add(RestItem(ticks: s - cursor));
      items.add(it);
      cursor = s + it.ticks;
    }
    if (cursor < total - kEps) items.add(RestItem(ticks: total - cursor));
  }

  void loadSample(int index) {
    setText(index == 0 ? kSampleJianpu : kSampleJianpu2, immediate: true);
    _omr = null;
    _imageBytes = null;
    _pages.clear();
    _pageErrors.clear();
  }

  /// 切换某张图里某个识别行是否参与转换
  void toggleBand(int pageIndex, int bandIndex, bool selected) {
    if (pageIndex < 0 || pageIndex >= _pages.length) return;
    final page = _pages[pageIndex];
    for (final b in page.outcome.result.bands) {
      if (b.index == bandIndex) b.selected = selected;
    }
    _mergePages();
    _parseNow();
    notifyListeners();
  }

  /// 把所有页的选中行拼成一份简谱文本
  void _mergePages() {    final buf = StringBuffer();
    var keptHeader = false;
    for (final page in _pages) {
      final text = buildJianpuText(page.outcome.result.bands);
      if (text.trim().isEmpty) continue;
      for (final line in text.split('\n')) {
        // 表头（调号/拍号）只保留第一条，后续页沿用，避免每页都插一行
        final isHeader = RegExp(r'^\s*[1-7]\s*=\s*').hasMatch(line.trim());
        if (isHeader) {
          if (keptHeader) continue;
          keptHeader = true;
        }
        buf.writeln(line);
      }
    }
    final merged = buf.toString().trimRight();
    if (merged.isNotEmpty) _text = merged;
  }

  /// 文件名像不像"曲名"。
  ///
  /// 手机拍的照片常叫 `7281.jpg`、`IMG_20240924_210806.jpg`、`Screenshot_...`、
  /// `mmexport1699...` —— 这些当标题比"没有标题"更糟（用户看到的就是 `7281`）。
  bool looksLikeSongName(String name) {
    final n = name.trim();
    if (n.isEmpty) return false;
    if (RegExp(r'^\d+$').hasMatch(n)) return false; // 7281
    if (RegExp(r'^\d{6,}').hasMatch(n)) return false; // 时间戳
    if (RegExp(
      r'^(img|dsc|pxl|photo|image|screenshot|screen[_-]?shot|wx[_-]?camera|mmexport|vid|video|scan)[-_ ]?[\d_\-]*$',
      caseSensitive: false,
    ).hasMatch(n)) {
      return false;
    }
    return true;
  }

  /// 曲谱名字自动跟随输入：模型没给出标题时，用第一张图片的文件名当标题
  void _applyFileNameAsTitle() {
    if (_text.trim().isEmpty) return;
    final hasTitle = _text
        .split('\n')
        .any((l) => RegExp(r'^\s*(标题|曲名|歌名)\s*[:：]').hasMatch(l.trim()));
    if (hasTitle) return;
    final first = _pages.isEmpty ? null : _pages.first.name;
    if (first == null) return;
    var name = first;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    // 拍照文件名（7281 / IMG_xxx / Screenshot_xxx）不要拿来当曲名
    if (!looksLikeSongName(name)) return;
    name = name.trim();
    if (name.isEmpty) return;
    _text = '标题：$name\n$_text';
  }

  /// 识别一张图，并**盯着节奏**：如果模型把整页时值写成了一个值
  /// （说明它没看数字下面的减时线、右边的附点、后面的延音横线），
  /// 就带上"你上一次错了"的提示词再问一次。
  ///
  /// 这是用户实际反馈过的坑：识谱结果里所有音符时长都一样、节奏全丢。
  /// 光在提示词里写清规则不够（模型会一路错到底），所以加一道**确定性判据 +
  /// 一次补救重问**；重问只在结果确实更丰富时才采用。
  ///
  /// [request] 的参数是 promptOverride（null = 用默认提示词）。
  /// 抽成静态方法是为了单元测试能注入假的 request，不必联网。
  static Future<String> recognizeWithRhythmCheck(
    Future<String> Function(String? promptOverride, {String? effort}) request, {
    void Function(String stage)? onStage,
    int maxRepair = 1,
  }) async {
    var raw = await request(null);

    // 第一关：格式。模型写成简谱文本时，音数和节奏都会明显缩水
    // （实测同一页：结构化 201 个音 vs 文本兜底 32 个音），所以再要一次 JSON。
    if (parseAiNotes(raw) == null) {
      onStage?.call('模型没按结构化格式返回（写成了简谱文本），正在要求重新输出…');
      try {
        final retry = await request(kFormatRepairPrompt);
        if (parseAiNotes(retry) != null) raw = retry;
      } catch (_) {
        // 补救失败就继续，后面还有文本兜底路径能用
      }
    }

    // 第二关：八度。用户反馈"原本的高音没有高、低音没有低"——
    // 实测模型会把**没有点的音也当成有点**（整页一个 octave=0 都没有），
    // 于是主旋律音域被拉成三个八度、音区关系全乱。
    for (var attempt = 0; attempt < maxRepair; attempt++) {
      final ai = parseAiNotes(raw);
      if (ai == null) break;
      final v = octaveVerdict(ai);
      if (!v.bad) break;
      onStage?.call(v.bassInverted
          ? '八度可能看反了（低音声部比高音还高），正在重新识别…'
          : v.zeroMissing
              ? '八度点可能读多了（整页没有一个不带点的音），正在重新识别…'
              : '八度可能没读对（音域过宽或整页同一八度），正在重新识别…');
      final String retry;
      try {
        retry = await request(
          octaveRepairPrompt(
            noteCount: ai.notes.length,
            flatShare: v.flatShare,
            zeroShare: v.zeroShare,
            bassInverted: v.bassInverted,
            wideSpan: v.wideSpan,
          ),
          effort: 'medium',
        );
      } catch (_) {
        break; // 补救失败就保留上一次的结果
      }
      final retryAi = parseAiNotes(retry);
      if (retryAi == null) break;
      final nv = octaveVerdict(retryAi);
      // 采纳条件：新结果"没那么糟"就采用（倒挂消失 / 不再是全 0 / 有了 0 / 音域收窄）
      final improved = (!nv.bassInverted && v.bassInverted) ||
          (nv.flatShare < v.flatShare - 0.05) ||
          (nv.zeroShare > 0.05 && v.zeroShare <= 0.02) ||
          (v.wideSpan && !nv.wideSpan);
      if (improved) raw = retry;
      if (!nv.bad) break;
    }

    // 第三关：节奏。整页时值都一个值 = 没看减时线
    for (var attempt = 0; attempt < maxRepair; attempt++) {
      final before = rhythmOf(raw);
      // 解析不出来（既不是结构化 JSON 也不是合法简谱）时不在这里补救
      if (before == null || !before.flat) break;
      onStage?.call('节奏信息缺失（整页都是 ${_fmtBeats(before.dominant)} 拍），正在重新识别节奏…');
      final String retry;
      try {
        // 补救这一遍提高推理强度，并明确告诉它上次错在哪
        retry = await request(
          rhythmRepairPrompt(noteCount: before.count, flatDur: before.dominant),
          effort: 'medium',
        );
      } catch (_) {
        break; // 补救失败就保留上一次的结果，别把整次识别搞崩
      }
      final after = rhythmOf(retry);
      if (after == null) break;
      if (after.distinct > before.distinct) raw = retry;
      if (!after.flat) break;
    }
    return raw;
  }

  /// 判断一份识别结果（结构化 JSON 或简谱文本）的节奏质量
  static RhythmVerdict? rhythmOf(String raw) {
    final ai = parseAiNotes(raw);
    if (ai != null) {
      final hist = durationHistogram(ai.notes);
      return RhythmVerdict(
        count: ai.notes.length,
        distinct: hist.length,
        dominant: dominantDuration(ai),
        flat: looksLikeFlatRhythm(ai),
      );
    }
    // 文本兜底路径也要判：模型没按结构化格式返回时，同样可能把时值全写成一个值
    try {
      final score = parseJianpu(assignVoicesToText(raw));
      final verdict = rhythmOfScore(score);
      return verdict.count < 12 ? null : verdict;
    } catch (_) {
      return null;
    }
  }

  static String _fmtBeats(double d) =>
      d == d.roundToDouble() ? '${d.toInt()}' : d.toStringAsFixed(2);

  /// 一份乐谱的时值分布（给状态文字和补救判据用）
  static RhythmVerdict rhythmOfScore(Score score) {
    final durs = <double>[];
    for (final m in score.measures) {
      for (final it in [...m.items, ...m.items2]) {
        if (it is NoteItem) durs.add((it.ticks * 1000).round() / 1000);
      }
    }
    final hist = <double, int>{};
    for (final d in durs) {
      hist[d] = (hist[d] ?? 0) + 1;
    }
    var dominant = 1.0;
    var bestCount = -1;
    hist.forEach((d, c) {
      if (c > bestCount) {
        bestCount = c;
        dominant = d;
      }
    });
    final top = hist.isEmpty ? 0 : hist.values.reduce((a, b) => a > b ? a : b);
    return RhythmVerdict(
      count: durs.length,
      distinct: hist.length,
      dominant: dominant,
      flat: durs.length >= 12 && (hist.length <= 1 || top / durs.length >= 0.9),
    );
  }

  /// 批量识别多张谱子（一次可以选好几页）
  ///
  /// 只走 **AI 识谱**（云端视觉大模型）。本地的模板匹配引擎实测对真实谱页
  /// （双声部、小字号扫描件）准确率不达标，已从产品中移除。
  /// 未配置接口时不再自动回退，而是提示去设置里填 Key。
  Future<void> recognizeImages(List<RecognizeInput> inputs) async {
    if (inputs.isEmpty) return;
    final hook = debugRecognizeHook;
    if (hook == null && !_cloud.isConfigured) {
      _status = 'AI 识谱尚未配置：点右上角设置图标，填入接口地址与 API Key 后即可识谱';
      notifyListeners();
      return;
    }

    _busy = true;
    _pages.clear();
    _pageErrors.clear();
    _imageBytes = inputs.first.bytes;
    _omrImageTotal = inputs.length;
    _omrImageIndex = 0;
    _omrProgress = 0;
    _omrStage = '准备中';
    _status = null;
    _lastSplitNote = null;
    notifyListeners();

    final recognizer = hook == null ? OpenAiCompatibleRecognizer(_cloud) : null;
    final results = List<_PageOutcome?>.filled(inputs.length, null);
    var completed = 0;
    final started = DateTime.now();

    Future<void> processPage(int i) async {
      final input = inputs[i];
      try {
        results[i] = await _recognizeOnePage(
          input,
          hook: hook,
          recognizer: recognizer,
          onStage: (s) {
            _omrStage = inputs.length == 1 ? s : '第 ${i + 1}/${inputs.length} 张 · $s';
            notifyListeners();
          },
        );
      } catch (e) {
        results[i] = _PageOutcome.error('${input.name}：$e');
      } finally {
        completed++;
        _omrImageIndex = completed;
        _omrProgress = completed / inputs.length;
        if (inputs.length > 1) {
          _omrStage = '已完成 $completed/${inputs.length} 张';
        }
        notifyListeners();
      }
    }

    // 多张图并发：一张一张串行时，扫描了 3 页就要等 3 倍时间。
    // 并发数默认 2（每页内部还会再并发分段），并发的进度用"已完成 k/N 张"报。
    final pageLimit = inputs.length > 1 ? _cloud.pageConcurrency.clamp(1, 4) : 1;
    if (pageLimit > 1) {
      await mapConcurrent<int, void>(
        List<int>.generate(inputs.length, (i) => i),
        pageLimit,
        (i, _) => processPage(i),
      );
    } else {
      for (var i = 0; i < inputs.length; i++) {
        await processPage(i);
      }
    }

    final aiScores = <Score>[];
    var pagesWithText = 0;
    var pagesFromAi = 0;

    // 多页统一调号：一首歌通常只在第一页印调号，第 2 页模型只能猜（实测它会猜 1=C）。
    // 用读到的调号（多数票）把没读到调号的页重算一遍，整首才不会差一个调。
    if (inputs.length > 1) {
      final votes = <String, int>{};
      for (final r in results) {
        final k = r?.keyRaw;
        if (k != null && k.isNotEmpty) votes[k] = (votes[k] ?? 0) + 1;
      }
      if (votes.isNotEmpty) {
        final best = (votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
        var fixedPages = 0;
        for (var i = 0; i < results.length; i++) {
          final r = results[i];
          if (r == null || r.error != null || r.aiNotes == null) continue;
          if ((r.keyRaw ?? '').isNotEmpty && r.keyRaw != best) {
            // 这一页自己也读到了调号，但和多数不一致：以多数为准（第一页通常有调号）
            fixedPages++;
          } else if ((r.keyRaw ?? '').isEmpty) {
            fixedPages++;
          } else {
            continue;
          }
          results[i] = r.withScore(
            scoreFromAiNotes(rekeyAiScore(r.aiNotes!, best), singleLineLayout: r.singleLine),
            best,
          );
        }
        if (fixedPages > 0) {
          _lastKeyNote = '多页统一调号：$best（修正 $fixedPages 页）';
        }
      }
    }

    for (final r in results) {
      if (r == null) continue;
      if (r.error != null) {
        _pageErrors.add(r.error!);
        continue;
      }
      _pages.add(r.page!);
      if (r.octaveNote != null) _octaveCheckNote = r.octaveNote;
      if (r.splitNote != null) _lastSplitNote = r.splitNote;
      if (r.aiScore != null) {
        aiScores.add(r.aiScore!);
        pagesFromAi++;
      }
      pagesWithText++;
    }
    _lastAiScore = aiScores.isEmpty ? null : aiScores.last;

    _omrProgress = 1;
    _omrStage = '完成';
    _omr = _pages.isEmpty ? null : _pages.first.outcome;
    _mergePages();
    _applyFileNameAsTitle();

    // 所有可用页都走的是**结构化**路径时，直接用 AI 给的乐谱，不再从文本解析一遍：
    // 简谱文本只有减时线/附点，像三连音（1/3 拍）这种时值写不出来，
    // 往返一次就会被抹成四分音符——用户看到的就是"所有音符时长都一样"。
    if (pagesFromAi > 0 && pagesFromAi == pagesWithText) {
      final exact = aiScores.length == 1 ? aiScores.first : mergeAiScores(aiScores);
      if (exact.meta.title.trim().isEmpty) {
        // 模型没给标题时，才按"用文件名当标题"的规则补；拍照文件名就算了
        final name = _pages.isEmpty ? null : _pages.first.name;
        if (name != null) {
          final dot = name.lastIndexOf('.');
          final base = dot > 0 ? name.substring(0, dot) : name;
          if (looksLikeSongName(base)) exact.meta.title = base;
        }
      }
      _score = exact;
      _text = toJianpu(exact); // 文本只作为展示与手动编辑的入口
      _status = null;
    } else {
      _parseNow();
    }

    final totalBands = _pages.fold<int>(0, (a, p) => a + p.outcome.result.bands.where((b) => b.selected).length);
    final okPages = _pages.where((p) => p.outcome.result.jianpuText.trim().isNotEmpty).length;
    // 把"节奏到底读到没有""走的是哪条路径"直接说出来：
    // 用户一眼能看出是节奏没识别、还是模型偷懒只写了一行（音数会明显偏少）
    final verdict = _score == null ? null : rhythmOfScore(_score!);
    final octNote = _octaveCheckNote == null ? '' : ' · $_octaveCheckNote';
    final pathNote = pagesFromAi > 0 && pagesFromAi == pagesWithText
        ? ' · 结构化 ${_lastAiScore?.pitchCount ?? 0} 个音'
        : ' · ⚠ 模型没按结构化格式返回（简谱文本兜底，音数通常偏少，可重新识别）';
    final rhythmNote = verdict == null
        ? ''
        : verdict.flat
            ? ' · ⚠ 时值只有 ${verdict.distinct} 种（${_fmtBeats(verdict.dominant)} 拍占多数），节奏可能没识别对'
            : ' · 时值 ${verdict.distinct} 种';
    final splitNote = _lastSplitNote == null ? '' : ' · $_lastSplitNote';
    final keyNote = _lastKeyNote == null ? '' : ' · $_lastKeyNote';
    final secs = (DateTime.now().difference(started).inMilliseconds / 1000).toStringAsFixed(1);
    _status = _pages.isEmpty
        ? '识别失败，请换一张更清晰的图片，或在下方手动输入'
            '${_pageErrors.isEmpty ? '' : '（${_pageErrors.first}）'}'
        : '识别完成：$okPages/${inputs.length} 张可用，共 $totalBands 行$pathNote$splitNote$keyNote$octNote$rhythmNote'
            ' · 用时 ${secs}s'
            '${_pageErrors.isEmpty ? '' : '；${_pageErrors.length} 张失败：${_pageErrors.first}'}';

    _busy = false;
    notifyListeners();
  }

  /// 识别**一张**图（不碰共享状态，方便多张图并发调用）
  Future<_PageOutcome> _recognizeOnePage(
    RecognizeInput input, {
    required Future<String> Function(RecognizeInput)? hook,
    required OpenAiCompatibleRecognizer? recognizer,
    required void Function(String stage) onStage,
  }) async {
    var raw = '';
    String? splitNote;
    if (hook != null) {
      raw = await hook(input);
    } else if (_cloud.splitLines) {
      // 分行并发：先试着按"组谱行"切开并发识别，切不动/失败就退回整页
      try {
        onStage('正在切行…');
        final split = await recognizePageByLines(
          imageBytes: input.bytes,
          recognizer: recognizer!,
          concurrency: _cloud.lineConcurrency,
          fallbackTitle: _titleFromFileName(input.name),
          onStage: (s, p) {
            _omrProgress = p.clamp(0.0, 1.0);
            onStage(s);
          },
        );
        if (split != null) {
          final aiNotes = split.score;
          final fixed = await _localOctaveCheck(aiNotes, input.bytes);
          final singleLine = split.layout == ScoreLayoutMode.singleLine;
          final score = scoreFromAiNotes(fixed.score, singleLineLayout: singleLine);
          splitNote = '分行并发 ${split.okSystems}/${split.systems} 段 · '
              '${singleLine ? '单行旋律谱' : '钢琴双行谱'}'
              '${split.retries > 0 ? '（重试 ${split.retries} 段）' : ''}';
          return _PageOutcome(
            page: _pageOf(input, score, 'AI 识谱（分行并发 ${fixed.score.notes.length} 个音）· ${_cloud.model}'),
            aiScore: score,
            aiNotes: fixed.score,
            keyRaw: split.keyRaw,
            singleLine: singleLine,
            octaveNote: fixed.note,
            splitNote: splitNote,
          );
        }
      } catch (e) {
        splitNote = '分行识谱失败，已退回整页（$e）';
      }
    }

    // 整页一个请求拿不到服务端的真实进度：**单张图**时用"已用时间"做渐近估算；
    // 多张图并发时进度由"已完成 k/N 张"驱动，不能几个页面抢同一个计时器。
    if (hook == null) {
      final soloPage = _omrImageTotal <= 1;
      if (soloPage) _startRequestProgress();
      try {
        raw = await recognizeWithRhythmCheck(
          (promptOverride, {effort}) async => (await recognizer!.recognize(
                input.bytes,
                mimeType: _mimeOf(input.name),
                promptOverride: promptOverride,
                effortOverride: effort,
              ))
              .jianpuText,
          onStage: onStage,
        );
      } finally {
        if (soloPage) _stopRequestProgress();
      }
    }
    // 优先按**结构化音符事件**解析：模型直接给"音级+起始+时值"的数字，
    // 比让它用减时线/附点写节奏稳得多；这份数据本身就等价于 MIDI 事件表，
    // 由它直接生成乐谱与 MIDI（见 omr/ai_notes.dart）。
    final aiNotes = parseAiNotes(raw);
    if (aiNotes != null) {
      // 八度点交给**本地几何检测**核对一遍（云端读那些小点不稳定）
      final fixed = await _localOctaveCheck(aiNotes, input.bytes);
      final score = scoreFromAiNotes(fixed.score);
      return _PageOutcome(
        page: _pageOf(input, score, 'AI 识谱（结构化音符 ${fixed.score.notes.length} 个）· ${_cloud.model}'),
        aiScore: score,
        octaveNote: fixed.note,
        splitNote: splitNote,
      );
    }

    // 兜底：模型没按结构化格式返回。钢琴简谱的上下两行是两个声部，
    // 若按"只取第一条旋律线"处理会把低音谱整条丢掉（就只剩一行谱了）。
    final voiced = assignVoicesToText(raw);
    final split = voiced.contains('低音:');
    final text = voiced;
    final src = split
        ? 'AI 识谱（上下两行已分成两个声部）· ${_cloud.model}'
        : 'AI 识谱 · ${_cloud.model}';
    return _PageOutcome(
      page: OmrPage(input.name, input.bytes,
          OmrOutcome(omrResultFromText(text, source: src, selectAll: split), null, null, 0, 0)),
      splitNote: splitNote,
    );
  }

  OmrPage _pageOf(RecognizeInput input, Score score, String src) {
    final wrapped = omrResultFromText(toJianpu(score), source: src, selectAll: true);
    return OmrPage(input.name, input.bytes, OmrOutcome(wrapped, null, null, 0, 0));
  }

  /// 用文件名猜曲名（模型没给标题时的兜底）
  String? _titleFromFileName(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return looksLikeSongName(base) ? base : null;
  }

  /// 是否用本地几何检测核对**八度点**（默认开）。
  ///
  /// 八度点是简谱里最小的记号，云端视觉模型读它不稳定（实测同一张图两次给出相反的错）；
  /// 而"数字上/下有没有点"是几何问题，本地连通域分析反而更可靠。
  /// 关掉可以省几秒（本地那一遍要跑图像分析）。
  bool useLocalOctaveCheck = true;

  /// 最近一次"八度点本地核对"的结果说明（显示在状态里）
  String? _octaveCheckNote;

  /// 最近一次"分行并发"的结果说明（显示在状态里）
  String? _lastSplitNote;

  /// 最近一次"多页统一调号"的说明（显示在状态里）
  String? _lastKeyNote;

  /// 跑一遍本地检测，用它的八度读数纠正 [ai]；失败就原样返回。
  ///
  /// 返回结果而不是写共享字段：多张图并发时不能互相覆盖状态。
  Future<({AiNotesScore score, String? note})> _localOctaveCheck(AiNotesScore ai, Uint8List bytes) async {
    if (!useLocalOctaveCheck) return (score: ai, note: null);
    try {
      final outcome = await recognizeImageBytes(bytes);
      final lines = localOctaveLines(outcome.result);
      if (lines.isEmpty) return (score: ai, note: null);
      final fix = fixOctavesFromLocal(ai, lines);
      if (fix.changed > 0) {
        _lastOctaveFix = fix.diagnostics;
        return (score: fix.score, note: '八度点本地核对：修正 ${fix.changed} 个音');
      }
      _lastOctaveFix = fix.diagnostics;
      return (score: ai, note: '八度点本地核对：无需修改');
    } catch (e) {
      return (score: ai, note: null); // 本地那遍失败不影响识别结果
    }
  }

  /// 诊断：最近一次八度核对的逐行说明
  List<String> _lastOctaveFix = const [];
  List<String> get lastOctaveFix => _lastOctaveFix;

  /// 是否存在待识别的图片（本地核对需要原图）
  bool get hasImage => _imageBytes != null;

  /// 根据文件名猜 MIME（AI 识谱上传时用）
  String _mimeOf(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  /// 一次 HTTP 请求拿不到服务端的真实进度，但界面不能只转一条波浪线：
  /// 这里按**已用时间**做渐近估算（典型 3~20 秒），封顶 92%，
  /// 并把已用秒数显示出来，让用户明确知道还在跑、跑了多久。
  void _startRequestProgress() {
    _progressTimer?.cancel();
    _requestStart = DateTime.now();
    _omrProgress = 0.02;
    _omrStage = 'AI 识谱中… 已用 0.0 秒';
    _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final start = _requestStart;
      if (start == null) return;
      final elapsed = DateTime.now().difference(start).inMilliseconds / 1000.0;
      _omrProgress = (0.92 * (1 - math.exp(-elapsed / 8))).clamp(0.02, 0.92);
      _omrStage = 'AI 识谱中… 已用 ${elapsed.toStringAsFixed(1)} 秒';
      notifyListeners();
    });
  }

  void _stopRequestProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _requestStart = null;
  }

  /// 单张便捷入口
  Future<void> recognizeImage(Uint8List bytes, {String name = '谱子'}) =>
      recognizeImages([RecognizeInput(name, bytes)]);

  @override
  void dispose() {
    _debounce?.cancel();
    _progressTimer?.cancel();
    super.dispose();
  }

  /* ------------------------------------------------------------------ *
   * 云端识别（AI 识谱；图片会离开本机发往所填接口）
   * ------------------------------------------------------------------ */

  Future<void> loadCloudSettings() async {
    _cloud = await CloudSettingsStore.load();
    notifyListeners();
  }

  Future<void> saveCloudSettings(CloudConfig config) async {
    _cloud = config;
    await CloudSettingsStore.save(config);
    _status = config.isConfigured ? 'AI 识谱配置已保存' : 'AI 识谱配置已清空';
    notifyListeners();
  }
}
