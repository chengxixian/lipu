/// 五线谱排版引擎：把 Score 变成一串绘制指令（纯 Dart，可单元测试）
///
/// 支持：
///   - 单谱表（高音谱 / 低音谱自动或指定）
///   - **大谱表**：高音谱 + 低音谱两行，左侧大括号，小节线贯穿两行
///   - **和弦**：同一时值上多个符头共用符干，二度音程自动错开符头
///   - **A4 分页**：给定页高时按页切分系统，一页一张纸
///
/// 乐谱符号使用 Bravura（SMuFL）字体按码位绘制，因此需要外部提供该字体。
library;

import 'dart:math' as math;

import '../core/model.dart';

/// SMuFL 码位（Bravura）
class Smufl {
  static const int gClef = 0xE050;
  static const int fClef = 0xE062;
  static const int brace = 0xE000;
  static const int sharp = 0xE262;
  static const int flat = 0xE260;
  static const int natural = 0xE261;
  static const int noteheadWhole = 0xE0A2;
  static const int noteheadHalf = 0xE0A3;
  static const int noteheadBlack = 0xE0A4;
  static const int flag8Up = 0xE240;
  static const int flag8Down = 0xE241;
  static const int flag16Up = 0xE242;
  static const int flag16Down = 0xE243;
  static const int flag32Up = 0xE244;
  static const int flag32Down = 0xE245;
  static const int restWhole = 0xE4E3;
  static const int restHalf = 0xE4E4;
  static const int restQuarter = 0xE4E5;
  static const int rest8th = 0xE4E6;
  static const int rest16th = 0xE4E7;
  static const int rest32nd = 0xE4E8;
  static const int augmentationDot = 0xE1E7;
  static const int timeSig0 = 0xE080;
  static const int barlineSingle = 0xE030;
  static const int barlineDouble = 0xE031;
  static const int barlineFinal = 0xE032;
  static const int repeatLeft = 0xE040;
  static const int repeatRight = 0xE041;
  static const int repeatDots = 0xE043;
}

/// 谱表最下面一条线的音高位置（step = octave*7 + 音名字母序号，C=0）
const int kTrebleBottomStep = 30; // E4
const int kBassBottomStep = 18; // G2

/// 调号里各音名在谱表上的标准位置（相对最下面一线的**半间距**数）
const Map<String, int> kSharpStepsTreble = {'F': 8, 'C': 5, 'G': 9, 'D': 6, 'A': 3, 'E': 7, 'B': 4};
const Map<String, int> kFlatStepsTreble = {'B': 4, 'E': 7, 'A': 3, 'D': 6, 'G': 2, 'C': 5, 'F': 1};
const Map<String, int> kSharpStepsBass = {'F': 6, 'C': 3, 'G': 7, 'D': 4, 'A': 1, 'E': 5, 'B': 2};
const Map<String, int> kFlatStepsBass = {'B': 2, 'E': 5, 'A': 1, 'D': 4, 'G': 0, 'C': 3, 'F': -1};

/* ------------------------------------------------------------------ *
 * 绘制指令
 * ------------------------------------------------------------------ */

sealed class DrawOp {
  const DrawOp();
}

/// 乐谱字体字形（按 SMuFL 码位）
class GlyphOp extends DrawOp {
  final int codePoint;
  final double x, y; // x 为字形左边、y 为基线
  final double size; // 字号（= 4 × 谱表间距）
  const GlyphOp(this.codePoint, this.x, this.y, this.size);
}

/// 普通文字（歌词、标题、速度…）
class TextOp extends DrawOp {
  final String text;
  final double x, y;
  final double size;
  final bool bold;
  final bool alignCenter;
  const TextOp(this.text, this.x, this.y, this.size, {this.bold = false, this.alignCenter = false});
}

class LineOp extends DrawOp {
  final double x1, y1, x2, y2, width;
  const LineOp(this.x1, this.y1, this.x2, this.y2, this.width);
}

/// 符尾横梁（实心矩形）
class BeamOp extends DrawOp {
  final double x1, y1, x2, y2, thickness;
  final List<double> subYs; // 16/32 分音符的次级横梁 y（相对主梁的偏移）
  const BeamOp(this.x1, this.y1, this.x2, this.y2, this.thickness, {this.subYs = const []});
}

/// 连音线 / 圆滑线（二次贝塞尔）
class CurveOp extends DrawOp {
  final double x1, y1, cx, cy, x2, y2, width;
  const CurveOp(this.x1, this.y1, this.cx, this.cy, this.x2, this.y2, this.width);
}

/// 矩形（小节线加粗、反复记号点等）
class RectOp extends DrawOp {
  final double x, y, w, h;
  const RectOp(this.x, this.y, this.w, this.h);
}

/* ------------------------------------------------------------------ *
 * 样式
 * ------------------------------------------------------------------ */

class StaffStyle {
  /// 一个谱表间距（五线谱相邻两线距离）
  final double space;
  final double systemGap;
  final double marginLeft;
  final double marginRight;
  final double marginTop;
  final double marginBottom;
  final bool showLyrics;
  final bool showTitle;

  /// 大谱表两行之间的距离（两个谱表间距）
  final double grandGap;

  /// A4 分页时的**整页高度**；null = 不分页（排成一张长图）
  final double? pageHeight;

  const StaffStyle({
    this.space = 10,
    this.systemGap = 58,
    this.marginLeft = 18,
    this.marginRight = 18,
    this.marginTop = 14,
    this.marginBottom = 18,
    this.showLyrics = true,
    this.showTitle = true,
    this.grandGap = 70,
    this.pageHeight,
  });

  double get staffHeight => space * 4;
  double get noteSize => space * 4;
  double get fontSize => space * 2.6;
  double get lyricSize => space * 1.7;

  /// 一页里能放系统的净高度
  double? get pageContentHeight =>
      pageHeight == null ? null : pageHeight! - marginTop - marginBottom;

  StaffStyle copyWith({double? pageHeight}) => StaffStyle(
        space: space,
        systemGap: systemGap,
        marginLeft: marginLeft,
        marginRight: marginRight,
        marginTop: marginTop,
        marginBottom: marginBottom,
        showLyrics: showLyrics,
        showTitle: showTitle,
        grandGap: grandGap,
        pageHeight: pageHeight ?? this.pageHeight,
      );
}

/// 一页（A4 一张纸）
class StaffPage {
  final int index;
  final List<DrawOp> ops;
  final double width;

  /// 这一页实际用掉的高度（含上下边距）
  final double usedHeight;

  /// 页面总高（分页时等于 A4 高度）
  final double height;
  final int firstMeasure;
  final int lastMeasure;
  const StaffPage({
    required this.index,
    required this.ops,
    required this.width,
    required this.usedHeight,
    required this.height,
    required this.firstMeasure,
    required this.lastMeasure,
  });
}

class StaffDocument {
  final double width;

  /// 所有页拼起来的总高度
  final double height;

  /// 所有页的绘制指令（平铺，便于导出成一张长图/老代码兼容）
  final List<DrawOp> ops;

  /// 分页结果（不分页时只有一页）
  final List<StaffPage> pages;
  const StaffDocument(this.width, this.height, this.ops, {this.pages = const []});

  bool get isPaged => pages.length > 1;
}

/* ------------------------------------------------------------------ *
 * 内部结构
 * ------------------------------------------------------------------ */

class _RenderNote {
  final Item item;
  final double ticks;
  final String type; // w h q 8 16 32
  final int dots;
  final bool isRest;
  final bool tieToNext;
  final bool tieFromPrev;

  /// 从低到高的全部音高（和弦）；休止符为空
  final List<Spelling> pitches;
  final String lyric;

  double x = 0;
  int step = 0; // 代表音（和弦取平均），用于符干方向与连音线
  int lowStep = 0;
  int highStep = 0;
  bool stemUp = true;
  double? stemX;
  double? stemTipY;

  /// 与 [pitches] 一一对应的水平偏移（二度音程错开用）
  final List<double> headOffsets = [];

  /// 需要真正画出来的变音记号数（调号已经隐含的不画）
  int accidentalCount = 0;

  _RenderNote({
    required this.item,
    required this.ticks,
    required this.type,
    required this.dots,
    required this.isRest,
    required this.tieToNext,
    required this.tieFromPrev,
    required this.pitches,
    required this.lyric,
  });

  bool get beamed => type == '8' || type == '16' || type == '32';
  int get beamCount => type == '8' ? 1 : (type == '16' ? 2 : 3);
  bool get hasAccidental => accidentalCount > 0;
}

/// 调号已经隐含的升降（同类名在调号里出现过就返回 ±1）
int _impliedAlter(String letter, KeyInfo ki) {
  const sharpOrder = ['F', 'C', 'G', 'D', 'A', 'E', 'B'];
  const flatOrder = ['B', 'E', 'A', 'D', 'G', 'C', 'F'];
  final n = ki.fifths;
  if (n > 0 && sharpOrder.take(n).contains(letter)) return 1;
  if (n < 0 && flatOrder.take(-n).contains(letter)) return -1;
  return 0;
}

class _System {
  final List<_MeasureLayout> measures = [];
  double width = 0;
  double y = 0;
  double height = 0;

  /// 音符跑出谱表时额外需要的上下空间（加线不能压到上一行/页边）
  double padTop = 0;
  double padBottom = 0;
}

class _MeasureLayout {
  final int index;
  final List<_RenderNote> notes = []; // 谱表 1
  final List<_RenderNote> notes2 = []; // 谱表 2（大谱表）
  double width = 0;
  double x = 0;
  int voiceTicks = 0;
  bool repeatStart = false;
  bool repeatEnd = false;
  bool isFinal = false;
  _MeasureLayout(this.index);
}

/// 一个谱表的几何信息
class _StaffGeom {
  final double topY;
  final double bottomY;
  final int bottomStep;
  final int middleStep;
  final bool bass;
  const _StaffGeom(this.topY, this.bottomY, this.bottomStep, this.middleStep, this.bass);
}

/* ------------------------------------------------------------------ *
 * 排版主入口
 * ------------------------------------------------------------------ */

StaffDocument layoutScore(Score score, {double width = 900, StaffStyle style = const StaffStyle()}) {
  final meta = score.meta;
  final ki = score.key;
  final beatTicks = 4 / meta.beatType;
  final groupTicks = _groupTicksFor(meta.beats, meta.beatType);
  final grand = score.isGrandStaff;

  // ---- 1. 把每个小节打平成可绘制的音符序列（两个声部各一套） ----
  final measures = <_MeasureLayout>[];
  for (var mi = 0; mi < score.measures.length; mi++) {
    final m = score.measures[mi];
    final ml = _MeasureLayout(mi)
      ..repeatStart = m.repeatStart
      ..repeatEnd = m.repeatEnd
      ..isFinal = m.isFinal;
    _flatten(ml.notes, m.items, ki, beatTicks, groupTicks, grand);
    if (grand) _flatten(ml.notes2, m.items2, ki, beatTicks, groupTicks, grand);
    ml.voiceTicks = (grand ? math.max(m.filled, m.filled2) : m.filled).round();
    measures.add(ml);
  }

  // ---- 2. 估算宽度并分行 ----
  final contentWidth = width - style.marginLeft - style.marginRight;
  final prefixWidth = _prefixWidth(style, grand);
  final systemHeight = grand ? style.staffHeight * 2 + style.grandGap : style.staffHeight;
  for (final ml in measures) {
    ml.width = _measureWidth(ml, style);
  }
  final systems = <_System>[];
  var cur = _System();
  var used = 0.0;

  // 音符超出谱表范围时给系统加高，避免加线压到上一行或掉出页面
  void accOverhang(_System sys, _MeasureLayout ml) {
    final half = style.space / 2;
    final bottom1 = grand || meta.clef != 'bass' ? kTrebleBottomStep : kBassBottomStep;
    for (final n in ml.notes) {
      if (n.pitches.isEmpty) continue;
      final overTop = n.highStep - (bottom1 + 8);
      if (overTop > 0) sys.padTop = math.max(sys.padTop, overTop * half + style.space);
      final overBottom = bottom1 - n.lowStep;
      if (overBottom > 0 && !grand) {
        sys.padBottom = math.max(sys.padBottom, overBottom * half + style.space);
      }
    }
    if (grand) {
      for (final n in ml.notes2) {
        if (n.pitches.isEmpty) continue;
        final overBottom = kBassBottomStep - n.lowStep;
        if (overBottom > 0) sys.padBottom = math.max(sys.padBottom, overBottom * half + style.space);
      }
    }
  }

  for (final ml in measures) {
    final need = ml.width + prefixWidth;
    if (cur.measures.isNotEmpty && used + need > contentWidth) {
      systems.add(cur);
      cur = _System();
      used = 0;
    }
    cur.measures.add(ml);
    accOverhang(cur, ml);
    used += need;
    cur.width = used;
    cur.height = systemHeight + cur.padTop + cur.padBottom;
  }
  if (cur.measures.isNotEmpty) systems.add(cur);

  // ---- 3. 分页（给了页高就按 A4 一页页切） ----
  final titleBlock = (style.showTitle && meta.title.isNotEmpty) ? style.space * 4.2 : 0.0;
  final contentLimit = style.pageContentHeight;
  final pages = <StaffPage>[];
  final pageOps = <DrawOp>[];
  var y = style.marginTop;
  var pageIndex = 0;
  var pageTop = 0.0;
  var pageFirst = measures.isEmpty ? 0 : measures.first.index;
  var pageLast = pageFirst;

  for (var si = 0; si < systems.length; si++) {
    final sys = systems[si];
    final need = sys.height + (si == systems.length - 1 ? 0 : style.systemGap);
    final firstOnPage = pageOps.isEmpty;
    final usedOnPage = y - pageTop;
    // 第一页要给标题留位置，后续页不需要
    final reserve = pageIndex == 0 ? titleBlock : 0.0;
    if (contentLimit != null && !firstOnPage && usedOnPage + need > contentLimit - reserve) {
      // 收掉这一页
      pages.add(StaffPage(
        index: pageIndex,
        ops: List<DrawOp>.from(pageOps),
        width: width,
        usedHeight: y + style.marginBottom,
        height: style.pageHeight!,
        firstMeasure: pageFirst,
        lastMeasure: pageLast,
      ));
      pageOps.clear();
      pageIndex++;
      pageTop = 0;
      y = style.marginTop;
      pageFirst = sys.measures.first.index;
    }
    if (pageOps.isEmpty && pageIndex == 0) {
      pageFirst = sys.measures.first.index;
      if (titleBlock > 0) {
        pageOps.add(TextOp(meta.title, width / 2, y + style.space * 2.6,
            style.space * 2.6, bold: true, alignCenter: true));
        final sub = [
          if (meta.lyricist.isNotEmpty) '词：${meta.lyricist}',
          if (meta.composer.isNotEmpty) '曲：${meta.composer}',
        ].join('   ');
        if (sub.isNotEmpty) {
          pageOps.add(TextOp(sub, width / 2, y + style.space * 4.1, style.space * 1.6, alignCenter: true));
        }
        y += titleBlock;
      }
    } else if (pageOps.isEmpty) {
      pageFirst = sys.measures.first.index;
    }

    sys.y = y;
    _layoutSystem(sys, pageOps, style, ki, contentWidth, meta, grand,
        showTempo: si == 0);
    pageLast = sys.measures.last.index;
    y += sys.height + style.systemGap;
  }

  if (pageOps.isNotEmpty || pages.isEmpty) {
    pages.add(StaffPage(
      index: pageIndex,
      ops: List<DrawOp>.from(pageOps),
      width: width,
      usedHeight: y + style.marginBottom - style.systemGap + style.space * 2,
      height: style.pageHeight ?? (y + style.marginBottom - style.systemGap + style.space * 2),
      firstMeasure: pageFirst,
      lastMeasure: pageLast,
    ));
  }

  final totalHeight = pages.fold(0.0, (a, p) => a + p.height);
  final allOps = <DrawOp>[for (final p in pages) ...p.ops];
  return StaffDocument(width, totalHeight, allOps, pages: pages);
}

void _flatten(
  List<_RenderNote> out,
  List<Item> items,
  KeyInfo ki,
  double beatTicks,
  double groupTicks,
  bool grand,
) {
  var offset = 0.0;
  for (final item in items) {
    final segments = notateTicks(item.ticks, offset, beatTicks, groupTicks);
    for (var si = 0; si < segments.length; si++) {
      final seg = segments[si];
      final note = _RenderNote(
        item: item,
        ticks: seg.ticks,
        type: seg.type,
        dots: seg.dots,
        isRest: item is RestItem,
        tieToNext: seg.tieToNext,
        tieFromPrev: si > 0 || (item is NoteItem && item.tieToPrev),
        pitches: item is NoteItem ? notePitches(item, ki) : const <Spelling>[],
        lyric: (si == segments.length - 1 && item is NoteItem && item.lyric != null) ? item.lyric! : '',
      );
      note.accidentalCount = note.pitches.where((p) => p.alter != _impliedAlter(p.letter, ki)).length;
      // 音高位置在这里就算出来：分行时要靠它决定系统需要多高（加线不能压到别处）
      if (note.pitches.isNotEmpty) {
        final steps = note.pitches.map((p) => p.octave * 7 + kLetters.indexOf(p.letter)).toList()..sort();
        note.lowStep = steps.first;
        note.highStep = steps.last;
        note.step = ((steps.first + steps.last) / 2).round();
      }
      out.add(note);
    }
    offset += item.ticks;
  }
}

double _groupTicksFor(int beats, int beatType) {
  final beat = 4 / beatType;
  if (beats % 3 == 0 && beats > 3) return beat * 3;
  if (beats >= 4 && beats % 2 == 0) return beat * 2;
  return beat * beats;
}

double _prefixWidth(StaffStyle s, bool grand) => s.space * 6.4 + _grandIndent(s, grand);

/// 大谱表左侧要给大括号留出的横向空间（谱表整体右移这么多）
double _grandIndent(StaffStyle s, bool grand) => grand ? s.space * 2.6 : 0;

double _measureWidth(_MeasureLayout ml, StaffStyle s) {
  double sum(List<_RenderNote> notes) {
    var w = 0.0;
    for (final n in notes) {
      w += _noteWidth(n, s);
    }
    return w;
  }

  final w = math.max(sum(ml.notes), sum(ml.notes2));
  return w + s.space * 2.2; // 小节两侧留白
}

double _noteWidth(_RenderNote n, StaffStyle s) {
  var w = switch (n.type) {
    'w' => s.space * 3.6,
    'h' => s.space * 2.9,
    _ => s.space * 2.5,
  };
  if (n.beamed) w += s.space * 0.5;
  if (n.hasAccidental) w += s.space * 1.15 * n.accidentalCount.clamp(1, 3);
  w += n.dots * s.space * 0.75;
  return w;
}

void _layoutSystem(
  _System sys,
  List<DrawOp> ops,
  StaffStyle s,
  KeyInfo ki,
  double contentWidth,
  ScoreMeta meta,
  bool grand, {
  bool showTempo = true,
}) {
  // 把多余空间均摊到小节（两端对齐）
  final baseWidths = sys.measures.fold(0.0, (a, m) => a + m.width);
  final available = contentWidth - _prefixWidth(s, grand);
  final extra = math.max(0.0, available - baseWidths);
  final perMeasure = sys.measures.isEmpty ? 0.0 : extra / sys.measures.length;

  // ---- 谱表几何 ----
  final indent = _grandIndent(s, grand);
  final leftX = s.marginLeft + indent; // 谱表/音符的起始 x（给大括号让位）
  final usableWidth = contentWidth - indent;
  final singleBass = !grand && meta.clef == 'bass';
  final topY1 = sys.y + sys.padTop;
  final bottomY1 = topY1 + s.staffHeight;
  final geom1 = _StaffGeom(
    topY1,
    bottomY1,
    singleBass ? kBassBottomStep : kTrebleBottomStep,
    (singleBass ? kBassBottomStep : kTrebleBottomStep) + 4,
    singleBass,
  );
  final topY2 = bottomY1 + s.grandGap;
  final bottomY2 = topY2 + s.staffHeight;
  final geom2 = _StaffGeom(topY2, bottomY2, kBassBottomStep, kBassBottomStep + 4, true);
  final bottomMostY = grand ? bottomY2 : bottomY1;

  double yOf(_StaffGeom g, int step) => g.bottomY - (step - g.bottomStep) * s.space / 2;

  // ---- 谱表线 ----
  void staffLines(_StaffGeom g) {
    for (var i = 0; i < 5; i++) {
      final lineY = g.bottomY - i * s.space;
      ops.add(LineOp(leftX, lineY, leftX + usableWidth, lineY, 1.1));
    }
  }

  staffLines(geom1);
  if (grand) staffLines(geom2);

  // ---- 大括号 ----
  if (grand) {
    final braceHeight = bottomY2 - topY1;
    final size = s.noteSize * (braceHeight / s.staffHeight) * 0.98;
    // Bravura 的 brace 以字形中心对齐两行谱表的中心
    final centerY = (topY1 + bottomY2) / 2;
    ops.add(GlyphOp(Smufl.brace, s.marginLeft + s.space * 0.15, centerY, size));
  }

  // ---- 谱号 + 调号 + 拍号（每个谱表各来一套）----
  void prefix(_StaffGeom g) {
    var px = leftX;
    final clefCp = g.bass ? Smufl.fClef : Smufl.gClef;
    final clefLabel = g.bass ? 'bass' : 'treble';
    if (g.bass) {
      ops.add(GlyphOp(clefCp, px + s.space * 0.4, g.bottomY + s.space * 0.2, s.noteSize));
    } else {
      ops.add(GlyphOp(clefCp, px + s.space * 0.4, g.bottomY + s.space * 0.9, s.noteSize));
    }
    px += s.space * 2.9;

    final fifths = ki.fifths;
    const sharpOrder = ['F', 'C', 'G', 'D', 'A', 'E', 'B'];
    const flatOrder = ['B', 'E', 'A', 'D', 'G', 'C', 'F'];
    final sharpSteps = clefLabel == 'bass' ? kSharpStepsBass : kSharpStepsTreble;
    final flatSteps = clefLabel == 'bass' ? kFlatStepsBass : kFlatStepsTreble;
    final keyGlyphs = <int>[];
    if (fifths > 0) {
      for (var i = 0; i < fifths && i < 7; i++) {
        final letter = sharpOrder[i];
        keyGlyphs.add(Smufl.sharp);
        ops.add(GlyphOp(Smufl.sharp, px, g.bottomY - sharpSteps[letter]! * s.space / 2, s.noteSize * 0.9));
        px += s.space * 0.85;
      }
    } else if (fifths < 0) {
      for (var i = 0; i < -fifths && i < 7; i++) {
        final letter = flatOrder[i];
        keyGlyphs.add(Smufl.flat);
        ops.add(GlyphOp(Smufl.flat, px, g.bottomY - flatSteps[letter]! * s.space / 2, s.noteSize * 0.9));
        px += s.space * 0.85;
      }
    }
    if (keyGlyphs.isNotEmpty) px += s.space * 0.6;

    for (final ch in meta.beats.toString().split('')) {
      ops.add(GlyphOp(Smufl.timeSig0 + int.parse(ch), px, g.topY + s.space * 1.75, s.noteSize));
      px += s.space * 1.35;
    }
    for (final ch in meta.beatType.toString().split('')) {
      ops.add(GlyphOp(Smufl.timeSig0 + int.parse(ch), px, g.topY + s.space * 3.95, s.noteSize));
      px += s.space * 1.35;
    }
    px += s.space * 0.6;
  }

  prefix(geom1);
  if (grand) prefix(geom2);

  // 速度：只在第一行谱表上方标一次（每行都标会满屏 ♩=96）
  if (showTempo) {
    ops.add(TextOp('♩= ${meta.tempo}', leftX + usableWidth - s.space * 6, topY1 - s.space * 0.7, s.space * 1.7));
  }

  // ---- 各小节 ----
  var x = leftX;
  for (final ml in sys.measures) {
    final measureStartX = x;
    ml.x = measureStartX;
    if (ml.repeatStart) {
      ops.add(GlyphOp(Smufl.repeatLeft, x - s.space * 1.2, bottomY1, s.noteSize));
      ops.add(GlyphOp(Smufl.repeatDots, x + s.space * 0.1, bottomY1 - s.space * 2, s.noteSize * 0.95));
    }

    final innerWidth = ml.width + perMeasure - s.space * 2.2;

    void place(List<_RenderNote> notes, _StaffGeom g) {
      final totalW = notes.fold(0.0, (a, n) => a + _noteWidth(n, s));
      var nx = measureStartX + s.space * 1.1;      for (final n in notes) {
        final w = _noteWidth(n, s);
        final slot = totalW <= 0 ? innerWidth / math.max(1, notes.length) : innerWidth * (w / totalW);
        n.x = nx + slot / 2;
        if (n.pitches.isNotEmpty) {
          n.stemUp = n.step < g.middleStep + 1;
          // 二度音程：把下面那个符头挪到符干另一侧，避免重叠
          final steps = n.pitches.map((p) => p.octave * 7 + kLetters.indexOf(p.letter)).toList();
          n.headOffsets
            ..clear()
            ..addAll(List<double>.filled(n.pitches.length, 0));
          final sorted = List<int>.from(steps)..sort();
          for (var i = 0; i + 1 < sorted.length; i++) {
            if (sorted[i + 1] - sorted[i] == 1) {
              final idx = steps.indexOf(sorted[i]);
              if (idx >= 0) n.headOffsets[idx] = n.stemUp ? -s.space * 0.95 : s.space * 0.95;
            }
          }
        }
        nx += slot;
      }
    }

    place(ml.notes, geom1);
    if (grand) place(ml.notes2, geom2);

    // 符头 / 休止符
    void drawNotes(List<_RenderNote> notes, _StaffGeom g) {
      for (final n in notes) {
        if (n.isRest) {
          _drawRest(ops, n, s, g.topY, g.bottomY);
          continue;
        }
        final cp = switch (n.type) {
          'w' => Smufl.noteheadWhole,
          'h' => Smufl.noteheadHalf,
          _ => Smufl.noteheadBlack,
        };

        final headTop = yOf(g, n.highStep);
        final headBottom = yOf(g, n.lowStep);
        // 符干：向上从最低符头往上，向下从最高符头往下
        if (n.type != 'w') {
          final stemX = n.x + (n.stemUp ? s.space * 0.62 : -s.space * 0.62);
          final tipY = n.stemUp ? headBottom - s.space * 3.5 : headTop + s.space * 3.5;
          n.stemX = stemX;
          n.stemTipY = tipY;
          ops.add(LineOp(stemX, n.stemUp ? headBottom : headTop, stemX, tipY, 1.4));
        }

        for (var pi = 0; pi < n.pitches.length; pi++) {
          final p = n.pitches[pi];
          final step = p.octave * 7 + kLetters.indexOf(p.letter);
          final noteY = yOf(g, step);
          final hx = n.x + (pi < n.headOffsets.length ? n.headOffsets[pi] : 0);
          // 加线
          var st = step;
          while (st <= g.bottomStep - 2) {
            final ly = yOf(g, st);
            ops.add(LineOp(hx - s.space * 1.05, ly, hx + s.space * 1.05, ly, 1.2));
            st += 2;
          }
          st = step;
          while (st >= g.bottomStep + 8 + 2) {
            final ly = yOf(g, st);
            ops.add(LineOp(hx - s.space * 1.05, ly, hx + s.space * 1.05, ly, 1.2));
            st -= 2;
          }
          // 变音记号（调号已隐含的不画；和弦时按顺序往左排开）
          final implied = _impliedAlter(p.letter, ki);
          if (p.alter != implied) {
            final cpAcc = p.alter > 0 ? Smufl.sharp : (p.alter < 0 ? Smufl.flat : Smufl.natural);
            final accX = n.x - s.space * (2.1 + 0.95 * (n.accidentalCount - 1 - pi).clamp(0, 2));
            ops.add(GlyphOp(cpAcc, accX, noteY, s.noteSize * 0.92));
          }
          ops.add(GlyphOp(cp, hx - s.space, noteY + s.space * 0.5, s.noteSize));
        }

        // 附点
        for (var d = 0; d < n.dots; d++) {
          ops.add(GlyphOp(Smufl.augmentationDot, n.x + s.space * 0.95 + d * s.space * 0.55, yOf(g, n.step), s.noteSize * 0.9));
        }
      }
    }

    drawNotes(ml.notes, geom1);
    if (grand) drawNotes(ml.notes2, geom2);

    // 符尾成组（同拍内连续的八分/十六分）
    _beamNotes(ml.notes, ops, s);
    if (grand) _beamNotes(ml.notes2, ops, s);

    // 连音线（和弦时逐音高连线）
    void ties(List<_RenderNote> notes, _StaffGeom g) {
      for (var i = 0; i + 1 < notes.length; i++) {
        final a = notes[i], b = notes[i + 1];
        if (!a.tieToNext || a.isRest || b.isRest) continue;
        final common = a.pitches.where((pa) => b.pitches.any((pb) => pb.midi == pa.midi)).toList();
        final chosen = common.isNotEmpty ? common : [a.pitches.last];
        for (final p in chosen) {
          final step = p.octave * 7 + kLetters.indexOf(p.letter);
          final ya = yOf(g, step);
          final yb = yOf(g, step);
          final up = a.stemUp;
          final y1 = ya + (up ? s.space * 0.7 : -s.space * 0.7);
          final y2 = yb + (up ? s.space * 0.7 : -s.space * 0.7);
          final cy = up ? math.min(y1, y2) - s.space * 0.8 : math.max(y1, y2) + s.space * 0.8;
          ops.add(CurveOp(a.x + s.space * 0.7, y1, (a.x + b.x) / 2, cy, b.x - s.space * 0.7, y2, 1.3));
        }
      }
    }

    ties(ml.notes, geom1);
    if (grand) ties(ml.notes2, geom2);

    // 歌词（只挂在高音谱一行下面）
    if (s.showLyrics) {
      for (final n in ml.notes) {
        if (n.lyric.isEmpty) continue;
        ops.add(TextOp(n.lyric, n.x, bottomY1 + s.space * 3.6, s.lyricSize, alignCenter: true));
      }
    }

    // 小节线（大谱表时贯穿两行）
    final barX = measureStartX + ml.width + perMeasure - s.space * 1.1;
    final topLine = grand ? topY1 : geom1.topY;
    void barline(double bx) {
      if (ml.isFinal) {
        ops.add(LineOp(bx - s.space * 0.5, topLine, bx - s.space * 0.5, bottomMostY, 1.2));
        ops.add(RectOp(bx, topLine, s.space * 0.42, bottomMostY - topLine));
      } else if (ml.repeatEnd) {
        ops.add(RectOp(bx - s.space * 0.1, topLine, s.space * 0.4, bottomMostY - topLine));
        ops.add(LineOp(bx + s.space * 0.5, topLine, bx + s.space * 0.5, bottomMostY, 1.2));
        ops.add(GlyphOp(Smufl.repeatDots, bx - s.space * 1.3, bottomY1 - s.space * 2, s.noteSize * 0.95));
      } else {
        ops.add(LineOp(bx, topLine, bx, bottomMostY, 1.2));
      }
    }

    barline(barX);
    x = barX;
  }
}

int? _restCodePoint(String type, _RenderNote n, double bottomY, double space, double bottomStep) {
  switch (type) {
    case 'w':
      return Smufl.restWhole;
    case 'h':
      return Smufl.restHalf;
    case 'q':
      return Smufl.restQuarter;
    case '8':
      return Smufl.rest8th;
    case '16':
      return Smufl.rest16th;
    case '32':
      return Smufl.rest32nd;
  }
  return null;
}

void _drawRest(List<DrawOp> ops, _RenderNote n, StaffStyle s, double topY, double bottomY) {
  final cp = _restCodePoint(n.type, n, bottomY, s.space, 30);
  if (cp == null) return;
  // 全休止符挂在第四线下；二分休止符坐在第三线上；其余居中
  final double y;
  if (n.type == 'w') {
    y = topY + s.space;
  } else if (n.type == 'h') {
    y = topY + s.space * 2;
  } else {
    y = topY + s.space * 2;
  }
  ops.add(GlyphOp(cp, n.x - s.space * 0.8, y, s.noteSize));
}

void _beamNotes(List<_RenderNote> notes, List<DrawOp> ops, StaffStyle s) {
  var i = 0;
  while (i < notes.length) {
    if (!notes[i].beamed || notes[i].isRest) {
      i++;
      continue;
    }
    var j = i;
    while (j + 1 < notes.length && notes[j + 1].beamed && !notes[j + 1].isRest) {
      j++;
    }
    if (j - i + 1 < 2) {
      // 单符尾：画符尾
      final n = notes[i];
      final up = n.stemUp;
      final cp = switch (n.type) {
        '8' => up ? Smufl.flag8Up : Smufl.flag8Down,
        '16' => up ? Smufl.flag16Up : Smufl.flag16Down,
        _ => up ? Smufl.flag32Up : Smufl.flag32Down,
      };
      if (n.stemX != null && n.stemTipY != null) {
        final sx = n.stemX!;
        ops.add(GlyphOp(cp, up ? sx - s.space * 0.1 : sx - s.space * 1.1, n.stemTipY!, s.noteSize));
      }
      i++;
      continue;
    }
    // 成组：连接符干末端
    final group = notes.sublist(i, j + 1);
    final up = group.first.stemUp;
    final ys = group.map((n) => n.stemTipY ?? 0).toList();
    final beamY = up ? ys.reduce(math.min) : ys.reduce(math.max);
    final x1 = group.first.stemX ?? group.first.x;
    final x2 = group.last.stemX ?? group.last.x;
    ops.add(BeamOp(x1, beamY, x2, beamY, s.space * 0.5));
    final maxBeams = group.map((n) => n.beamCount).reduce(math.max);
    for (var b = 1; b < maxBeams; b++) {
      final dy = s.space * 0.75 * b * (up ? 1 : -1);
      var lastIdx = group.length - 1;
      while (lastIdx > 0 && group[lastIdx].beamCount <= b) {
        lastIdx--;
      }
      final sx1 = group.first.stemX ?? group.first.x;
      final sx2 = group[lastIdx].stemX ?? group[lastIdx].x;
      ops.add(BeamOp(sx1, beamY + dy, sx2, beamY + dy, s.space * 0.42));
    }
    i = j + 1;
  }
}
