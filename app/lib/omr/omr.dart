/// 简谱图片识别流水线：版面分析 -> 音符列分组 -> 修饰符识别 -> 简谱文本
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'omr_core.dart';

/// 进度回调：(0..1 的比例, 当前阶段说明)
typedef OmrProgress = void Function(double fraction, String stage);

class OmrOptions {
  /// 是否使用局部自适应阈值（拍照场景建议 true）
  final bool adaptive;
  /// 倾斜校正的最大角度
  final double maxSkewDeg;
  /// 连通域最小面积（去噪）
  final int minArea;
  /// 低于该置信度会在界面上标红
  final double lowConfidence;
  /// 字形与最佳模板的相似度低于此值即视为杂记号（跳音▽、括号、谱面装饰）丢弃
  final double minGlyphScore;

  const OmrOptions({
    this.adaptive = true,
    this.maxSkewDeg = 5,
    this.minArea = 3,
    this.lowConfidence = 0.72,
    this.minGlyphScore = 0.42,
  });
}

class OmrToken {
  /// 简谱记号文本，如 `1'`、`5`、`0`、`|`
  final String text;
  final String kind; // note | rest | barline | accidental | unknown
  final double confidence;
  final int x, y, w, h;
  final String detail;
  const OmrToken(this.text, this.kind, this.confidence, this.x, this.y, this.w, this.h, this.detail);
}

class OmrBand {
  final int index;
  final int y0, y1;
  final List<OmrToken> tokens;
  final String text;
  final double score; // 越接近 1 越像简谱数字行
  final String reason;
  bool selected;
  OmrBand(this.index, this.y0, this.y1, this.tokens, this.text, this.score, this.reason, {this.selected = false});

  double get meanConfidence {
    final notes = tokens.where((t) => t.kind == 'note' || t.kind == 'rest').toList();
    if (notes.isEmpty) return 0;
    return notes.fold(0.0, (a, t) => a + t.confidence) / notes.length;
  }

  /// 给界面用的行类型提示
  String get kindHint {
    if (score >= 0.55) return '简谱数字行';
    if (score >= 0.3) return '可能是简谱行';
    return '文字/歌词行';
  }
}

class OmrResult {
  final List<OmrBand> bands;
  final String jianpuText;
  final List<String> diagnostics;
  final int imageWidth, imageHeight;
  const OmrResult(this.bands, this.jianpuText, this.diagnostics, this.imageWidth, this.imageHeight);

  double get meanConfidence {
    final sel = bands.where((b) => b.selected).toList();
    if (sel.isEmpty) return 0;
    return sel.fold(0.0, (a, b) => a + b.meanConfidence) / sel.length;
  }

  /// 低置信度音符比例，用于界面上提示“请人工校对”
  int get lowConfidenceCount => bands
      .where((b) => b.selected)
      .expand((b) => b.tokens)
      .where((t) => (t.kind == 'note' || t.kind == 'rest') && t.confidence < 0.72)
      .length;
}

/* ------------------------------------------------------------------ *
 * 主流程
 * ------------------------------------------------------------------ */

OmrResult recognizeJianpu(GrayImage gray, GlyphClassifier classifier, {OmrOptions options = const OmrOptions()}) {
  // 1. 二值化
  final bin = binarize(gray, adaptive: options.adaptive);
  // 2. 倾斜校正
  final deskewed = deskew(bin, maxDeg: options.maxSkewDeg);
  return recognizeJianpuFromBinary(deskewed, classifier, options: options);
}

/// 在已经二值化（并可选校正过倾斜）的图上做识别
OmrResult recognizeJianpuFromBinary(
  BinImage bin,
  GlyphClassifier classifier, {
  OmrOptions options = const OmrOptions(),
  OmrProgress? onProgress,
}) {
  final diag = <String>[];
  // 3. 去噪 + 连通域
  onProgress?.call(0.05, '连通域分析');
  final comps = connectedComponents(bin, minArea: options.minArea);
  diag.add('二值化(${options.adaptive ? "自适应" : "大津"}) 后共 ${comps.length} 个连通域');

  // 4. 行分割（水平投影）
  final rawBands = _splitBands(bin, comps);
  // 八度点、附点这类小记号会自成一行，需要并回相邻的数字行
  final heights = comps.where((c) => c.h >= 4).map((c) => c.h).toList()..sort();
  final medianH = heights.isEmpty ? 10.0 : heights[heights.length ~/ 2].toDouble();
  final bands = _mergeBands(rawBands, medianH);
  diag.add('检测到 ${bands.length} 个文本行（合并前 ${rawBands.length}）');
  onProgress?.call(0.15, '版面分析：${bands.length} 行');

  final outBands = <OmrBand>[];
  for (var i = 0; i < bands.length; i++) {
    final b = bands[i];
    final bandComps = comps.where((c) => c.cy >= b.$1 && c.cy <= b.$2).toList();
    final band = _readBand(i, b.$1, b.$2, bandComps, classifier, diag, options: options);
    outBands.add(band);
    // 逐行上报，界面上能看到进度往前走
    onProgress?.call(0.15 + 0.80 * (i + 1) / bands.length, '识别第 ${i + 1}/${bands.length} 行');
  }

  // 5. 自动选择“像简谱数字行”的行
  for (final b in outBands) {
    b.selected = b.score >= 0.55 && b.tokens.where((t) => t.kind == 'note' || t.kind == 'rest').length >= 2;
  }
  if (!outBands.any((b) => b.selected)) {
    // 兜底：选音符最多的行
    final withNotes = outBands.where((b) => b.tokens.isNotEmpty).toList()
      ..sort((a, c) => c.tokens.length.compareTo(a.tokens.length));
    if (withNotes.isNotEmpty) {
      withNotes.first.selected = true;
      diag.add('未找到高置信度的简谱行，已采用音符最多的一行，请人工确认');
    }
  }

  final text = buildJianpuText(outBands);
  onProgress?.call(1.0, '完成');
  return OmrResult(outBands, text, diag, bin.w, bin.h);
}

String buildJianpuText(List<OmrBand> bands) {
  final buf = StringBuffer();
  for (final b in bands.where((b) => b.selected)) {
    if (b.text.trim().isEmpty) continue;
    buf.writeln(b.text);
  }
  return buf.toString().trimRight();
}

/* ------------------------------------------------------------------ *
 * 行分割
 * ------------------------------------------------------------------ */

List<(int, int)> _splitBands(BinImage bin, List<Comp> comps) {
  final h = bin.h, w = bin.w;
  // 用连通域的纵向范围构造行投影（比逐像素更抗噪）
  final cover = List<int>.filled(h + 1, 0);
  for (final c in comps) {
    if (c.h <= 1) continue;
    cover[c.minY]++;
    cover[c.maxY + 1]--;
  }
  var running = 0;
  final active = List<bool>.filled(h, false);
  for (var y = 0; y < h; y++) {
    running += cover[y];
    active[y] = running > 0;
  }
  // 统计每行墨迹量，用于切开粘连行
  final inkRow = List<int>.filled(h, 0);
  for (var y = 0; y < h; y++) {
    var c = 0;
    for (var x = 0; x < w; x++) {
      if (bin.d[y * w + x] != 0) c++;
    }
    inkRow[y] = c;
  }
  final gapTolerance = math.max(2, (h * 0.004).round());
  final bands = <(int, int)>[];
  var start = -1;
  var gap = 0;
  for (var y = 0; y < h; y++) {
    final has = active[y] && inkRow[y] > 0;
    if (has) {
      if (start < 0) start = y;
      gap = 0;
    } else if (start >= 0) {
      gap++;
      if (gap > gapTolerance) {
        final end = y - gap;
        if (end - start >= 4) bands.add((start, end));
        start = -1;
        gap = 0;
      }
    }
  }
  if (start >= 0 && h - 1 - start >= 4) bands.add((start, h - 1));
  return bands;
}

/// 把紧贴在数字行上下方的“细行”（八度点、附点等）并回去
List<(int, int)> _mergeBands(List<(int, int)> bands, double medianH) {
  final out = <(int, int)>[];
  for (final b in bands) {
    if (out.isNotEmpty) {
      final prev = out.last;
      final gap = b.$1 - prev.$2;
      final prevH = prev.$2 - prev.$1;
      final curH = b.$2 - b.$1;
      final thin = prevH <= medianH * 0.5 || curH <= medianH * 0.5;
      if (gap <= medianH * 0.45 && thin) {
        out[out.length - 1] = (prev.$1, b.$2);
        continue;
      }
    }
    out.add(b);
  }
  return out;
}

/* ------------------------------------------------------------------ *
 * 整页识别：先版面分析，再逐行放大识别
 * ------------------------------------------------------------------ */

/// 目标字形高度（像素）：放大到这个量级后模板匹配才可靠
const double kTargetGlyphHeight = 42;

/// 双声部简谱会把上下两条旋律排在同一"行"里。若一个行带的高度明显超过字高，
/// 就按行内"数字中心"的最大空隙把它切成两个声部，避免两条旋律被混成一条。
List<(int, int)> _splitVoices(List<(int, int)> bands, List<Comp> comps, double medianH) {
  final out = <(int, int)>[];
  for (final b in bands) {
    if (b.$2 - b.$1 < medianH * 2.2) {
      out.add(b);
      continue;
    }
    // 只看"像数字"的连通域，用它们的中心找空隙
    final inside = comps.where((c) {
      if (c.cy < b.$1 || c.cy > b.$2) return false;
      final hRatio = c.h / medianH;
      final aspect = c.w / math.max(1, c.h);
      return hRatio >= 0.6 && hRatio <= 1.6 && aspect <= 1.2;
    }).map((c) => c.cy).toList()
      ..sort();
    if (inside.length < 6) {
      out.add(b);
      continue;
    }
    var bestGap = 0.0;
    var splitIndex = -1;
    for (var i = 1; i < inside.length; i++) {
      final gap = inside[i] - inside[i - 1];
      if (gap > bestGap) {
        bestGap = gap;
        splitIndex = i;
      }
    }
    if (bestGap > medianH * 1.6 && splitIndex > 1 && splitIndex < inside.length - 1) {
      final mid = ((inside[splitIndex - 1] + inside[splitIndex]) / 2).round();
      out.add((b.$1, mid));
      out.add((mid + 1, b.$2));
    } else {
      out.add(b);
    }
  }
  return out;
}

/// 把（AI 识谱返回的）简谱文本包装成与本地识别一致的 OmrBand 结构。
///
/// 这样"人工校对 -> 逐行勾选 -> 合并成简谱"这一套逻辑本地/AI 完全复用。
OmrResult omrResultFromText(
  String text, {
  String source = 'AI 识谱',
  double confidence = 0.95,
  int imageWidth = 0,
  int imageHeight = 0,
  bool selectAll = false,
}) {
  final lineRe = RegExp(r"[#bn♯♭♮]?[0-7][',^v\/\.\-\+]*|\|\:|\:\|\||\:\||\|\||\|\]|\||-");
  final bands = <OmrBand>[];
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final isHeader = RegExp(r'^\s*[1-7]\s*=');
  var musicLineSeen = 0;
  final diag = <String>['识别方式：$source'];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final tokens = <OmrToken>[];
    for (final m in lineRe.allMatches(line)) {
      final s = m.group(0)!;
      final kind = (s == '|' || s == '||' || s == '|]' || s == '|:' || s == ':|' || s == ':||')
          ? 'barline'
          : (s.startsWith('0') ? 'rest' : 'note');
      tokens.add(OmrToken(s, kind, confidence, 0, i, 0, 0, source));
    }
    if (tokens.isEmpty) continue;
    final header = isHeader.hasMatch(line);
    // 单声部管线：多声部时默认只取第一条旋律线，其余留给用户勾选。
    // 结构化输出（模型已经分好高音/低音声部）则全部选中，否则低音谱会被丢掉。
    final selected = selectAll || header || musicLineSeen == 0;
    if (!header) musicLineSeen++;
    bands.add(OmrBand(i, i, i + 1, tokens, line, 1.0, source, selected: selected));
  }
  if (musicLineSeen > 1 && !selectAll) {
    diag.add('检测到 $musicLineSeen 条声部线，默认只取第一条（可在下方勾选切换）');
  }
  return OmrResult(bands, text, diag, imageWidth, imageHeight);
}

/// 整页识别的结果（同时把页面级二值图带回去，供界面预览）
class OmrPageResult {
  final OmrResult result;
  final BinImage pageBinary;
  const OmrPageResult(this.result, this.pageBinary);
}

/// 整页识别入口
///
/// 真实谱页里一行简谱的数字常常只有 12~20 像素高，直接分类基本必错
/// （JPEG 压缩 + 笔画粘连）。所以这里：
///   1) 在原尺度上做二值化 + 版面分析，找到每一行；
///   2) 把每一行裁出来、双线性放大到字高约 42px，再重新二值化、识别。
/// 这样既保证了分类精度，又让任何时刻只有一行的大图在内存里（手机也扛得住）。
OmrPageResult recognizeJianpuPage(
  GrayImage gray,
  GlyphClassifier classifier, {
  OmrOptions options = const OmrOptions(),
  OmrProgress? onProgress,
}) {
  final diag = <String>[];
  onProgress?.call(0.03, '二值化');
  final pageBin = binarize(gray, adaptive: options.adaptive);
  onProgress?.call(0.08, '倾斜校正');
  final angle = estimateSkewAngle(pageBin, maxDeg: options.maxSkewDeg);
  if (angle.abs() >= 0.5) diag.add('倾斜 ${angle.toStringAsFixed(1)}° 已校正');

  // 版面分析（原尺度即可，找行不需要放大）
  final pageComps = connectedComponents(pageBin, minArea: options.minArea);
  final rawBands = _splitBands(pageBin, pageComps);
  final heights = pageComps
      .where((c) => c.h >= 3 && c.w / math.max(1, c.h) <= 1.8)
      .map((c) => c.h)
      .toList()
    ..sort();
  final pageMedianH = heights.isEmpty ? 12.0 : heights[heights.length ~/ 2].toDouble();
  final bands = _mergeBands(rawBands, pageMedianH);
  // 双声部简谱：一行里上下两条旋律。若行高明显大于字高，按"数字中心的空隙"切开
  final splitBands = _splitVoices(bands, pageComps, pageMedianH);
  diag.add('版面：${splitBands.length} 行（合并前 ${rawBands.length}），字高约 ${pageMedianH.toStringAsFixed(0)}px'
      '${splitBands.length != bands.length ? '，已按声部拆分' : ''}');
  onProgress?.call(0.12, '版面分析：${splitBands.length} 行');

  // 逐行：裁出来 -> 放大 -> 识别
  final scale = (kTargetGlyphHeight / math.max(4.0, pageMedianH)).clamp(1.0, 4.0);
  diag.add('每行放大 ${scale.toStringAsFixed(1)}× 后识别');
  final outBands = <OmrBand>[];
  for (var i = 0; i < splitBands.length; i++) {
    final b = splitBands[i];
    final pad = (pageMedianH * 0.8).round() + 6;
    final y0 = math.max(0, b.$1 - pad);
    final y1 = math.min(gray.h - 1, b.$2 + pad);
    final strip = gray.crop(0, y0, gray.w, y1 - y0 + 1);
    final up = resizeGrayBilinear(strip, scale);
    var bin = binarize(up, adaptive: options.adaptive);
    if (angle.abs() >= 0.5) bin = rotate(bin, angle);
    final comps = connectedComponents(bin, minArea: options.minArea);
    final band = _readBand(i, 0, bin.h - 1, comps, classifier, diag, options: options);
    outBands.add(_remapBand(band, y0, scale));
    onProgress?.call(0.12 + 0.86 * (i + 1) / splitBands.length, '识别第 ${i + 1}/${splitBands.length} 行');
  }

  _selectBands(outBands, diag);
  final text = buildJianpuText(outBands);
  onProgress?.call(1.0, '完成');
  return OmrPageResult(OmrResult(outBands, text, diag, gray.w, gray.h), pageBin);
}

/// 把行内（放大后）坐标换算回整页坐标，便于界面叠加显示
OmrBand _remapBand(OmrBand band, int y0, double scale) {
  final tokens = band.tokens
      .map((t) => OmrToken(
            t.text,
            t.kind,
            t.confidence,
            (t.x / scale).round(),
            (t.y / scale).round() + y0,
            math.max(1, (t.w / scale).round()),
            math.max(1, (t.h / scale).round()),
            t.detail,
          ))
      .toList();
  return OmrBand(
    band.index,
    (band.y0 / scale).round() + y0,
    (band.y1 / scale).round() + y0,
    tokens,
    band.text,
    band.score,
    band.reason,
    selected: band.selected,
  );
}

/// 挑出真正参与转换的行：既要"像简谱数字行"，也要字形认得准
void _selectBands(List<OmrBand> bands, List<String> diag) {
  for (final b in bands) {
    final noteCount = b.tokens.where((t) => t.kind == 'note' || t.kind == 'rest').length;
    b.selected = b.score >= 0.55 && noteCount >= 2 && b.meanConfidence >= 0.5;
  }
  if (bands.any((b) => b.selected)) return;
  // 全都不达标时，退而求其次：挑字形认得最准且音符最多的一行
  final candidates = bands.where((b) => b.tokens.any((t) => t.kind == 'note' || t.kind == 'rest')).toList()
    ..sort((a, b) {
      final c = b.meanConfidence.compareTo(a.meanConfidence);
      if (c != 0) return c;
      return b.tokens.length.compareTo(a.tokens.length);
    });
  if (candidates.isNotEmpty && candidates.first.meanConfidence >= 0.3) {
    candidates.first.selected = true;
    diag.add('未找到高置信度的简谱行，已选中识别质量最好的一行（请人工确认）');
  }
}

/* ------------------------------------------------------------------ *
 * 单行（已是放大后的条带）识别
 * ------------------------------------------------------------------ */

class _Glyph {
  final Comp comp;
  String kind; // digit | dot | dash | underline | barline | accidental | other
  String label = '';
  double conf = 0;
  _Glyph(this.comp, this.kind);
}

OmrBand _readBand(
  int index,
  int y0,
  int y1,
  List<Comp> comps,
  GlyphClassifier classifier,
  List<String> diag, {
  OmrOptions options = const OmrOptions(),
}) {
  if (comps.isEmpty) return OmrBand(index, y0, y1, const [], '', 0, '空行');

  // 先按面积过滤噪点，再估计字高
  final real = comps.where((c) => c.area >= 6).toList();
  if (real.isEmpty) return OmrBand(index, y0, y1, const [], '', 0, '只有噪点');
  // 用“方块状”连通域估计字高，避免横线拉低中位数
  final squares = real.where((c) => c.h >= 4 && c.w / math.max(1, c.h) <= 1.6).toList();
  final heightSrc = (squares.length >= 3 ? squares : real).map((c) => c.h).toList()..sort();
  final medianH = heightSrc[heightSrc.length ~/ 2].toDouble();
  final widthSrc = (squares.length >= 3 ? squares : real).map((c) => c.w).toList()..sort();
  final medianW = widthSrc[widthSrc.length ~/ 2].toDouble();

  final glyphs = <_Glyph>[];
  final underlines = <(int, int, int)>[]; // 从粘连字形里拆出来的减时线 (x0, x1, y)
  final merged = <Comp>{}; // 被拆分的粘连连通域（不参与行评分）

  for (final c in real) {
    final aspect = c.w / math.max(1, c.h);
    final hRatio = c.h / medianH;

    // 分裂“数字 + 下划线”粘连的情况
    final split = _trySplitUnderline(c, medianH);
    if (split != null) {
      glyphs.add(_Glyph(split.$1, 'digit'));
      underlines.add(split.$2);
      merged.add(c);
      continue;
    }

    String kind;
    if (hRatio >= 1.55 && aspect <= 0.62) {
      kind = 'barline';
    } else if (aspect >= 2.2 && hRatio <= 0.6) {
      // 横线：是减时线还是延音短横，要结合它相对数字的垂直位置再判断
      kind = 'hseg';
    } else if (hRatio <= 0.42 && aspect >= 0.45 && aspect <= 2.2 && c.area <= 0.28 * medianH * medianH) {
      kind = 'dot';
    } else if (hRatio >= 0.5 && hRatio <= 1.6 && aspect <= 1.15) {
      kind = 'digit';
    } else if (c.area <= 0.5 * medianH * medianH && c.w <= medianW * 1.2) {
      kind = 'accidental';
    } else {
      kind = 'other';
    }
    glyphs.add(_Glyph(c, kind));
  }

  final digits = glyphs.where((g) => g.kind == 'digit').toList()
    ..sort((a, b) => a.comp.cx.compareTo(b.comp.cx));
  if (digits.isEmpty) {
    return OmrBand(index, y0, y1, const [], '', 0, '无数字字形');
  }

  // 分类数字
  for (final g in digits) {
    final r = classifier.classify(g.comp);
    g.label = r.label;
    g.conf = r.score;
  }

  // 丢掉落魄的杂记号（跳音▽、括号、谱面装饰）：它们形状接近数字但匹配分很低
  final kept = digits.where((g) => g.conf >= options.minGlyphScore).toList();
  final usable = kept.length >= math.max(2, (digits.length * 0.4).round()) ? kept : digits;
  if (usable.length < digits.length) {
    diag.add('第${index + 1}行丢弃 ${digits.length - usable.length} 个非数字记号');
  }

  // 列分组：每个 digit 一列
  final columns = usable.map((g) => _Column(g)).toList();
  for (final g in glyphs) {
    if (g.kind == 'digit') continue;
    if (g.kind == 'dot' || g.kind == 'accidental') {
      final col = _nearestColumn(columns, g.comp.cx, medianH);
      if (col != null) col.attach(g, medianH, classifier);
    }
  }

  // 从“数字+下划线”粘连字形里拆出来的减时线
  for (final u in underlines) {
    for (var i = 0; i < columns.length; i++) {
      final d = columns[i].digit.comp;
      final halfW = math.max(medianH * 0.6, d.w * 0.7);
      if (u.$3 > d.cy && d.cx + halfW >= u.$1 - 1 && d.cx - halfW <= u.$2 + 1) {
        columns[i].underlines++;
      }
    }
  }

  // 横线：低于数字中心的算减时线（可能跨越多个音），与数字同高的算延音短横
  final dashesByColumn = <int, int>{};
  final hsegs = glyphs.where((g) => g.kind == 'hseg').toList();
  for (final s in hsegs) {
    var asUnderline = false;
    for (var i = 0; i < columns.length; i++) {
      final d = columns[i].digit.comp;
      final halfW = math.max(medianH * 0.6, d.w * 0.7);
      final overlaps = d.cx + halfW >= s.comp.minX - 1 && d.cx - halfW <= s.comp.maxX + 1;
      if (!overlaps) continue;
      if (s.comp.cy > d.cy + medianH * 0.18) {
        columns[i].underlines++;
        asUnderline = true;
      }
    }
    if (asUnderline) continue;
    // 延音短横：归给左侧最近、且高度接近的列
    var best = -1;
    var bestDist = double.infinity;
    for (var i = 0; i < columns.length; i++) {
      final d = columns[i].digit.comp;
      final dy = (s.comp.cy - d.cy).abs();
      if (dy > medianH * 0.5) continue;
      final dx = s.comp.minX - d.maxX;
      if (dx < -d.w * 0.4) continue;
      if (dx < bestDist) {
        bestDist = dx.toDouble();
        best = i;
      }
    }
    if (best >= 0 && bestDist <= medianH * 2.4) {
      dashesByColumn[best] = (dashesByColumn[best] ?? 0) + 1;
    }
  }

  // 小节线：作为独立 token 插入
  final bars = glyphs.where((g) => g.kind == 'barline').toList()..sort((a, b) => a.comp.cx.compareTo(b.comp.cx));

  // 组装 token（按 x 排序：小节线插在正确位置）
  final tokens = <OmrToken>[];
  final events = <(double, OmrToken)>[];
  for (var i = 0; i < columns.length; i++) {
    final col = columns[i];
    final t = col.toToken(i, dashesByColumn[i] ?? 0, classifier);
    events.add((col.digit.comp.cx, t));
  }
  for (final b in bars) {
    // 两根很靠近的竖线 => 双小节线
    final near = bars.where((o) => o != b && (o.comp.cx - b.comp.cx).abs() <= medianH * 0.82).length;
    final style = near > 0 ? '||' : '|';
    events.add((b.comp.cx, OmrToken(style, 'barline', 0.95, b.comp.minX, b.comp.minY, b.comp.w, b.comp.h, '竖线')));
  }
  events.sort((a, b) => a.$1.compareTo(b.$1));
  for (final e in events) {
    tokens.add(e.$2);
  }

  // 行评分：以"识别结果"为准——数字越多、混进来的字母越少、认得越准，越像简谱数字行。
  // （早先只看字形比例的评分会把"1=C 4/4 ♩=60"这类标题行也选上）
  var digitCount = 0;
  var letterCount = 0;
  var symbolCount = 0;
  var digitConfSum = 0.0;
  final letterRe = RegExp(r'^[A-Ga-g]$');
  for (final t in tokens) {
    // 先按"认出来的字符"判断，再按 token 类型统计（标题行里的 C/D/B/G 会先被判成音符）
    if (letterRe.hasMatch(t.text)) {
      letterCount++;
      continue;
    }
    if (t.kind == 'note' || t.kind == 'rest') {
      digitCount++;
      digitConfSum += t.confidence;
    } else {
      symbolCount++;
    }
  }
  final digitMeanConf = digitCount == 0 ? 0.0 : digitConfSum / digitCount;
  final relevance = (digitCount - 2.0 * letterCount) /
      math.max(1.0, digitCount + letterCount + 0.4 * symbolCount);
  var score = relevance.clamp(0.0, 1.0) * (0.45 + 0.55 * digitMeanConf);
  if (digitCount < 4) score *= 0.35;
  if (glyphs.any((g) => g.kind == 'hseg')) score += 0.04;
  score = score.clamp(0.0, 1.0);

  final text = tokens.map((t) => t.text).join(' ');
  final reason = '字高≈${medianH.toStringAsFixed(0)}px，识别 ${digitCount} 个数字 / 字母 $letterCount'
      '，平均置信 ${(digitMeanConf * 100).toStringAsFixed(0)}%';
  return OmrBand(index, y0, y1, tokens, text, score, reason);
}
/// 把“数字 + 底部减时线”粘连的连通域拆开
/// 返回 (数字连通域, (x0, x1, y))；无法判定时返回 null
(Comp, (int, int, int))? _trySplitUnderline(Comp c, double medianH) {
  if (c.h < medianH * 0.9 || c.w < 3) return null;
  // 只有比自身高明显更宽时才可能是“数字 + 下划线”（避免把 3/5 的底部笔画当成减时线）
  if (c.w < c.h * 1.25) return null;
  final w = c.w, h = c.h;
  // 每行的墨迹宽度
  final rowW = List<int>.filled(h, 0);
  final rowMin = List<int>.filled(h, 1 << 30);
  final rowMax = List<int>.filled(h, -1);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (c.mask[y * w + x] == 0) continue;
      rowW[y]++;
      if (x < rowMin[y]) rowMin[y] = x;
      if (x > rowMax[y]) rowMax[y] = x;
    }
  }
  // 上半部分（数字主体）宽度中位数
  final upper = <int>[];
  for (var y = 0; y < (h * 0.6).round(); y++) {
    if (rowW[y] > 0) upper.add(rowMax[y] - rowMin[y] + 1);
  }
  if (upper.isEmpty) return null;
  upper.sort();
  final baseW = upper[upper.length ~/ 2].toDouble();
  // 底部是否存在明显更宽的横带
  var cut = -1;
  for (var y = (h * 0.62).round(); y < h; y++) {
    final width = rowMax[y] - rowMin[y] + 1;
    if (rowW[y] > 0 && width > baseW * 1.45 && width > baseW + 2) {
      cut = y;
      break;
    }
  }
  if (cut < 0) return null;
  // 从 cut 开始，向下连续的行都算减时线（允许 1 行空档）
  var end = cut;
  var miss = 0;
  for (var y = cut; y < h; y++) {
    final width = rowMax[y] - rowMin[y] + 1;
    if (rowW[y] > 0 && width > baseW * 1.25) {
      end = y;
      miss = 0;
    } else {
      miss++;
      if (miss > 1) break;
    }
  }
  if (end - cut > h * 0.55) return null; // 太厚，不像减时线
  final digit = Comp();
  var area = 0;
  for (var y = 0; y < cut; y++) {
    for (var x = 0; x < w; x++) {
      if (c.mask[y * w + x] == 0) continue;
      digit.minX = math.min(digit.minX, x);
      digit.minY = math.min(digit.minY, y);
      digit.maxX = math.max(digit.maxX, x);
      digit.maxY = math.max(digit.maxY, y);
      area++;
    }
  }
  if (area < 8 || digit.maxX < digit.minX) return null;
  digit.area = area;
  digit.mask = Uint8List(digit.w * digit.h);
  for (var y = digit.minY; y <= digit.maxY; y++) {
    for (var x = digit.minX; x <= digit.maxX; x++) {
      if (c.mask[y * w + x] != 0) digit.mask[(y - digit.minY) * digit.w + (x - digit.minX)] = 1;
    }
  }
  var x0 = 1 << 30, x1 = -1;
  for (var y = cut; y <= end; y++) {
    if (rowW[y] == 0) continue;
    x0 = math.min(x0, rowMin[y]);
    x1 = math.max(x1, rowMax[y]);
  }
  if (x1 < x0) return null;
  // 局部坐标 -> 原图坐标
  digit.sumX += c.minX * area;
  digit.sumY += c.minY * area;
  digit.minX += c.minX;
  digit.maxX += c.minX;
  digit.minY += c.minY;
  digit.maxY += c.minY;
  return (digit, (c.minX + x0, c.minX + x1, c.minY + cut));
}

class _Column {
  final _Glyph digit;
  int underlines = 0;
  int octaveUp = 0;
  int octaveDown = 0;
  bool dotted = false;
  String accidental = '';

  _Column(this.digit);

  void attach(_Glyph g, double medianH, GlyphClassifier classifier) {
    final d = digit.comp;
    if (g.kind == 'accidental') {
      // 只有位于数字左侧的才可能是变音记号
      if (g.comp.cx > d.cx) return;
      final r = classifier.classify(g.comp);
      final label = r.label;
      if ((label == '#' || label == 'b' || label == 'n') && r.score >= 0.3) accidental = label;
      return;
    }
    // 点在数字右侧、且垂直居中 => 附点
    final rightOfDigit = g.comp.minX >= d.maxX - d.w * 0.15;
    final dx = g.comp.minX - d.maxX;
    if (rightOfDigit && dx <= medianH * 1.1 && (g.comp.cy - d.cy).abs() <= medianH * 0.45) {
      dotted = true;
      return;
    }
    // 否则按上下方判定八度
    if (g.comp.cy < d.cy) {
      octaveUp++;
    } else {
      octaveDown++;
    }
  }

  OmrToken toToken(int index, int dashes, GlyphClassifier classifier) {
    final c = digit.comp;
    final rec = classifier.classify(c);
    final isRest = rec.label == '0';
    final oct = octaveUp > 0 ? "'" * octaveUp : (octaveDown > 0 ? ',' * octaveDown : '');
    final dur = underlines > 0 ? '/' * underlines : '';
    final dot = dotted ? '.' : '';
    final ext = dashes > 0 ? ' ${List.filled(dashes, '-').join(' ')}' : '';
    final text = '$accidental${rec.label}$oct$dur$dot$ext';
    final kind = isRest ? 'rest' : 'note';
    final detail = '候选: ${rec.ranking.take(3).map((r) => '${r.label}(${(r.score * 100).toStringAsFixed(0)}%)').join(' ')}';
    return OmrToken(text, kind, rec.score, c.minX, c.minY, c.w, c.h, detail);
  }
}

_Column? _nearestColumn(List<_Column> cols, double x, double medianH) {
  _Column? best;
  var bestDist = double.infinity;
  for (final c in cols) {
    final dist = (c.digit.comp.cx - x).abs();
    if (dist < bestDist) {
      bestDist = dist;
      best = c;
    }
  }
  if (best == null) return null;
  final limit = math.max(medianH * 0.85, best.digit.comp.w * 0.9);
  return bestDist <= limit ? best : null;
}

/* ------------------------------------------------------------------ *
 * 只做"切行"：给 AI 分行并发识谱用（不跑字形识别）
 * ------------------------------------------------------------------ */

/// 谱式：整页是**单行旋律谱**（一行数字 + 汉字歌词）还是**钢琴双行谱**（每组上下两行）。
///
/// 为什么要分：两种谱式的读法不同——单行谱下面的汉字歌词**不是音符**，
/// 用双行谱的提示词去问，模型很容易凭空编出一个低音声部；反过来把双行谱当单行读，
/// 左手整条就丢了。所以要先判谱式，再用对应的提示词与转换规则。
enum ScoreLayoutMode {
  singleLine,
  grandStaff,
}

/// 一段行条：已经裁好、放大、二值化、纠斜之后的图（不识别字形）
class PageStrip {
  /// 二值图（可以直接编码成 PNG 发给视觉模型）
  final BinImage bin;

  /// 这一组谱行在整页里的 y 范围（未加 padding）
  final int y0, y1;

  /// 第几组谱行；-1 表示页面顶部的标题区
  final int groupIndex;

  /// 是否是页面顶部的标题/调号区
  final bool header;

  const PageStrip(this.bin, this.y0, this.y1, this.groupIndex, {this.header = false});
}

class PageStripResult {
  final List<PageStrip> strips;

  /// 每组谱行的 y 范围（不含 padding）
  final List<(int, int)> groups;

  /// 版面分析出来的原始行（合并八度点行之后），以及每行里"像简谱数字"的字形个数。
  /// 单行/双行谱的判断、以及给界面报"这段是几行谱"都用它。
  final List<(int, int)> bands;
  final List<int> bandGlyphs;

  /// 这一页是单行旋律谱还是钢琴双行谱
  final ScoreLayoutMode mode;

  /// 识别出的"谱表行"总数（不含歌词行）——双行谱大约是组数的两倍
  final int musicRowCount;

  /// 本地分组：每组合了几个谱表行（顺序与 [strips] 里的谱行一致）
  final List<int> groupSizes;

  final double skewDeg;
  final double medianH;
  final int width, height;
  final List<String> diag;

  const PageStripResult(
    this.strips,
    this.groups,
    this.skewDeg,
    this.medianH,
    this.width,
    this.height,
    this.diag, {
    this.bands = const [],
    this.bandGlyphs = const [],
    this.mode = ScoreLayoutMode.singleLine,
    this.musicRowCount = 0,
    this.groupSizes = const [],
  });

  /// 谱行组数（不含标题区）
  int get systemCount => groups.length;
}

/// 这一行里"像简谱数字"的连通域个数：字高量级、接近方形。
/// 曲名那类大块字、装饰线、页码都过不了这个筛子。
int _glyphCount((int, int) band, List<Comp> comps, double medianH) {
  var count = 0;
  for (final c in comps) {
    if (c.cy < band.$1 || c.cy > band.$2) continue;
    if (c.h >= medianH * 0.5 && c.h <= medianH * 1.8 && c.w <= c.h * 1.8) count++;
  }
  return count;
}

/// 整页 -> 行条（只做版面分析与裁图，**不做字形识别**）
///
/// 与 [recognizeJianpuPage] 用的是同一套版面几何（投影分行、按字高并回八度点行、
/// 每行加 padding 后放大重二值化、按倾斜角纠斜），区别只是不跑模板匹配分类——
/// AI 识谱要的是"把每行裁出来发给模型"，本地不需要读字形。
///
/// 分组规则：相邻且靠得很近的两行算**同一组谱行**（钢琴简谱的上下两行 = 高低音两个
/// 声部，必须放在同一张图里一起发给模型，否则模型分不清哪个是低音）。
PageStripResult splitPageStrips(
  GrayImage gray, {
  OmrOptions options = const OmrOptions(),
}) {
  final diag = <String>[];
  final pageBin = binarize(gray, adaptive: options.adaptive);
  final angle = estimateSkewAngle(pageBin, maxDeg: options.maxSkewDeg);
  if (angle.abs() >= 0.5) diag.add('倾斜 ${angle.toStringAsFixed(1)}° 已校正');

  final comps = connectedComponents(pageBin, minArea: options.minArea);
  final rawBands = _splitBands(pageBin, comps);
  final heights = comps
      .where((c) => c.h >= 3 && c.w / math.max(1, c.h) <= 1.8)
      .map((c) => c.h)
      .toList()
    ..sort();
  final medianH = heights.isEmpty ? 12.0 : heights[heights.length ~/ 2].toDouble();
  final bands = _mergeBands(rawBands, medianH);

  // 双声部简谱会把上下两条旋律排进同一个"行"里：先用**数字中心的空隙**把声部拆开
  // （`_splitVoices` 本来就是干这个的），拆完的每一行才是"一个谱表行"。
  final staffRows = _splitVoices(bands, comps, medianH);
  final counts = [for (final b in staffRows) _glyphCount(b, comps, medianH)];

  // 谱表行 vs 歌词行：谱表行里有八度点（数字上方）和减时线（数字下方），行高约为字高的
  // 2.5 倍；歌词是汉字，只有字高那么高。实测：
  //   二十二 p1（单行旋律谱）字高 23px —— 谱行 58~65px、歌词行 22~23px、装饰行 36px；
  //   春风吹 p1（钢琴双行谱）字高 17px —— 拆声部后的谱行 58~150px、曲名/页码行 ≤29px。
  var isMusic = [for (final b in staffRows) (b.$2 - b.$1) >= medianH * 2.0];
  if (isMusic.where((f) => f).isEmpty && staffRows.length >= 3) {
    // 一行都没判成谱行 → 可能是整页四分音符（既没加点也没减时线，行高就等于字高）：
    // 改用"字形数"判据（曲名/页码那种行的字形数少得可怜）。
    final sortedCounts = [...counts]..sort();
    final medianCount = sortedCounts.isEmpty ? 0 : sortedCounts[sortedCounts.length ~/ 2];
    final keep = math.max(4.0, medianCount * 0.45);
    isMusic = [for (final c in counts) c >= keep];
    diag.add('行高判不出谱行（可能整页都是四分音符），改用字形数阈值 ${keep.toStringAsFixed(0)}');
  }
  if (isMusic.where((f) => f).isEmpty) {
    // 最后兜底：宁可多识别几段，也不能一行都不发（丢一段就是丢一段旋律）
    isMusic = [for (final _ in staffRows) true];
    diag.add('版面判据都不成立，按"每行都是谱行"处理');
  }

  var firstMusic = isMusic.indexOf(true);
  if (firstMusic < 0) firstMusic = 0;
  final headerEnd = staffRows.isEmpty ? 0 : staffRows[firstMusic].$1;
  if (firstMusic > 0) {
    diag.add('标题区上方 $firstMusic 行不算谱行（曲名/调号/歌词/页码），已并入标题区');
  }

  // 分组：**只有"同一行拆出来的两行"才算一组**。
  // `_splitVoices` 是把一个行带从中间切开，所以这两行的间距恰好是 1px；
  // 而相邻两组谱行（哪怕挤得只剩 12px）是真·两行谱，不能并。
  // 用"间距阈值"是行不通的：二十二 p1 里第一段的谱行间距只有 1.4 个字高，
  // 用 1.6 个字高去并会把 4 组谱行串成 695px 的一大块（实测踩过）。
  final groups = <(int, int)>[];
  final rowsPerGroup = <int>[];
  var musicRowCount = 0;
  var prevMusicEnd = -9999;
  for (var i = firstMusic; i < staffRows.length; i++) {
    if (!isMusic[i]) continue;
    musicRowCount++;
    final b = staffRows[i];
    final gap = b.$1 - prevMusicEnd;
    prevMusicEnd = b.$2;
    if (groups.isNotEmpty && gap <= 2) {
      groups[groups.length - 1] = (groups.last.$1, b.$2);
      rowsPerGroup[rowsPerGroup.length - 1]++;
    } else {
      groups.add(b);
      rowsPerGroup.add(1);
    }
  }

  // 每组是几行谱：拆出来的两行 = 2；没拆开但"高得像两行"（≥3.4 个字高）= 2；否则 1。
  var grandGroups = 0;
  for (var i = 0; i < groups.length; i++) {
    final h = groups[i].$2 - groups[i].$1;
    if (rowsPerGroup[i] >= 2 || h >= medianH * 3.4) grandGroups++;
  }
  // 多数组都是双行才算钢琴双行谱（个别行判错不影响整体）
  final mode = (groups.isNotEmpty && grandGroups * 2 > groups.length)
      ? ScoreLayoutMode.grandStaff
      : ScoreLayoutMode.singleLine;
  diag.add('版面：${groups.length} 组谱行 / $musicRowCount 行谱（原始行 ${rawBands.length}，'
      '字高约 ${medianH.toStringAsFixed(0)}px，双行组 $grandGroups 个）'
      '→ ${mode == ScoreLayoutMode.grandStaff ? "钢琴双行谱" : "单行旋律谱"}');

  final scale = (kTargetGlyphHeight / math.max(4.0, medianH)).clamp(1.0, 3.0);
  final pad = (medianH * 0.8).round() + 6;

  BinImage cut(int y0, int y1) {
    final a = math.max(0, y0);
    final b = math.min(gray.h - 1, y1);
    final strip = gray.crop(0, a, gray.w, math.max(1, b - a + 1));
    final up = resizeGrayBilinear(strip, scale);
    var bin = binarize(up, adaptive: options.adaptive);
    if (angle.abs() >= 0.5) bin = rotate(bin, angle);
    return bin;
  }

  final strips = <PageStrip>[];
  // 顶部标题区（曲名/调号/拍号/速度都在这里）：够高才单独裁一张。
  // 往**下多带 0.9 个字高**：调号/速度那行常常紧贴在第一个谱行上方，
  // 只裁到第一个谱行的顶边会把它切掉（实测：二十二 p1 的 `1=F 4/4` 就这么没了，
  // 结果各段自己猜调号，全都猜成 1=C）。
  if (headerEnd > math.max(24, medianH * 1.6)) {
    final hEnd = math.min(gray.h - 1, headerEnd + (medianH * 0.9).round());
    strips.add(PageStrip(cut(0, hEnd), 0, hEnd, -1, header: true));
  }
  // **一个谱表行一张图**（顺序 = 从上到下）。分组（哪两行属于同一组）交给 AI 判断，
  // 这里只提供精确的行边界——AI 给的归一化坐标要吸附到这些边界上，才不会裁歪。
  final rowStrips = <PageStrip>[];
  for (var i = firstMusic; i < staffRows.length; i++) {
    if (!isMusic[i]) continue;
    final b = staffRows[i];
    rowStrips.add(PageStrip(cut(b.$1 - pad, b.$2 + pad), b.$1, b.$2, i));
  }
  strips.addAll(rowStrips);

  return PageStripResult(strips, groups, angle, medianH, gray.w, gray.h, diag,
      bands: staffRows,
      bandGlyphs: counts,
      mode: mode,
      musicRowCount: musicRowCount,
      groupSizes: rowsPerGroup);
}
