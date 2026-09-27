/// 简谱图片识别（OMR）核心：图像处理 / 连通域 / 字形分类
///
/// 这一层是纯 Dart（不依赖 Flutter），便于单元测试；
/// 字形模板由 `omr_templates.dart` 用 Flutter 的文字渲染生成后注入。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/* ------------------------------------------------------------------ *
 * 图像结构
 * ------------------------------------------------------------------ */

/// 灰度图（0 = 黑，255 = 白）
class GrayImage {
  final int w;
  final int h;
  final Uint8List d;
  GrayImage(this.w, this.h, this.d);

  int at(int x, int y) => d[y * w + x];

  /// 从 RGBA 字节构造
  factory GrayImage.fromRgba(Uint8List rgba, int w, int h) {
    final out = Uint8List(w * h);
    for (var i = 0, p = 0; i < out.length; i++, p += 4) {
      // Rec.601 亮度
      out[i] = ((rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) / 1000).round().clamp(0, 255);
    }
    return GrayImage(w, h, out);
  }

  /// 裁剪一块区域（越界部分补白）
  GrayImage crop(int x0, int y0, int cw, int ch) {
    final out = Uint8List(cw * ch);
    out.fillRange(0, out.length, 255);
    for (var y = 0; y < ch; y++) {
      final sy = y0 + y;
      if (sy < 0 || sy >= h) continue;
      for (var x = 0; x < cw; x++) {
        final sx = x0 + x;
        if (sx < 0 || sx >= w) continue;
        out[y * cw + x] = d[sy * w + sx];
      }
    }
    return GrayImage(cw, ch, out);
  }
}

/// 灰度图双线性放大（整页谱子数字太小，按行裁出来后要放大才能可靠分类）
GrayImage resizeGrayBilinear(GrayImage src, double scale) {
  if (scale <= 1.0) return src;
  final nw = math.max(1, (src.w * scale).round());
  final nh = math.max(1, (src.h * scale).round());
  final out = Uint8List(nw * nh);
  for (var y = 0; y < nh; y++) {
    final sy = (y + 0.5) / scale - 0.5;
    final y0 = sy.floor().clamp(0, src.h - 1);
    final y1 = (y0 + 1).clamp(0, src.h - 1);
    final fy = (sy - y0).clamp(0.0, 1.0);
    for (var x = 0; x < nw; x++) {
      final sx = (x + 0.5) / scale - 0.5;
      final x0 = sx.floor().clamp(0, src.w - 1);
      final x1 = (x0 + 1).clamp(0, src.w - 1);
      final fx = (sx - x0).clamp(0.0, 1.0);
      final v00 = src.d[y0 * src.w + x0].toDouble();
      final v01 = src.d[y0 * src.w + x1].toDouble();
      final v10 = src.d[y1 * src.w + x0].toDouble();
      final v11 = src.d[y1 * src.w + x1].toDouble();
      final top = v00 + (v01 - v00) * fx;
      final bottom = v10 + (v11 - v10) * fx;
      out[y * nw + x] = (top + (bottom - top) * fy).round().clamp(0, 255);
    }
  }
  return GrayImage(nw, nh, out);
}

/// 二值图：1 = 墨迹（黑）
class BinImage {
  final int w;
  final int h;
  final Uint8List d;
  BinImage(this.w, this.h, this.d);

  bool at(int x, int y) => x >= 0 && y >= 0 && x < w && y < h && d[y * w + x] != 0;
  void set(int x, int y, bool v) {
    if (x >= 0 && y >= 0 && x < w && y < h) d[y * w + x] = v ? 1 : 0;
  }

  int count() {
    var c = 0;
    for (final v in d) {
      if (v != 0) c++;
    }
    return c;
  }

  BinImage clone() => BinImage(w, h, Uint8List.fromList(d));

  /// 生成一张调试用位图（墨迹为黑、背景为白），便于界面预览
  Uint8List toRgba() {
    final out = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      final v = d[i] != 0 ? 0 : 255;
      out[i * 4] = v;
      out[i * 4 + 1] = v;
      out[i * 4 + 2] = v;
      out[i * 4 + 3] = 255;
    }
    return out;
  }
}

/* ------------------------------------------------------------------ *
 * 二值化
 * ------------------------------------------------------------------ */

/// 大津法阈值
int otsuThreshold(GrayImage g) {
  final hist = List<int>.filled(256, 0);
  for (final v in g.d) {
    hist[v]++;
  }
  final total = g.d.length;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0.0, threshold = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sum - sumB) / wF;
    final between = wB.toDouble() * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      threshold = t;
    }
  }
  return threshold;
}

/// 二值化：Sauvola 局部阈值（滑动窗口均值/方差，内存 O(宽)）
///
/// 早先的实现用两张整图积分图（Float64List），1800×1800 就要 ~52MB，
/// 手机上会直接 OOM 闪退；改成可分离的滑动窗口累加，额外内存只有几 KB。
BinImage binarize(GrayImage g, {bool adaptive = true, int window = 25, double k = 0.12, int? globalThreshold}) {
  final w = g.w, h = g.h;
  final out = Uint8List(w * h);
  if (w == 0 || h == 0) return BinImage(w, h, out);

  if (!adaptive) {
    final t = globalThreshold ?? otsuThreshold(g);
    for (var i = 0; i < w * h; i++) {
      out[i] = g.d[i] <= t ? 1 : 0;
    }
    return BinImage(w, h, out);
  }

  final half = math.max(1, window ~/ 2);
  // 列方向的滚动和（当前窗口覆盖的行区间），长度 w
  final colSum = Float64List(w);
  final colSumSq = Float64List(w);
  // 行方向的前缀和，长度 w+1
  final prefix = Float64List(w + 1);
  final prefixSq = Float64List(w + 1);
  const maxStd = 128.0;

  void addRow(int y, double sign) {
    if (y < 0 || y >= h) return;
    final base = y * w;
    for (var x = 0; x < w; x++) {
      final v = g.d[base + x].toDouble();
      colSum[x] += sign * v;
      colSumSq[x] += sign * v * v;
    }
  }

  // 初始窗口：行 [-half, half]
  for (var y = 0; y <= math.min(h - 1, half); y++) {
    addRow(y, 1);
  }

  for (var y = 0; y < h; y++) {
    if (y > 0) {
      addRow(y + half, 1);
      addRow(y - half - 1, -1);
    }
    // 行方向前缀和
    prefix[0] = 0;
    prefixSq[0] = 0;
    for (var x = 0; x < w; x++) {
      prefix[x + 1] = prefix[x] + colSum[x];
      prefixSq[x + 1] = prefixSq[x] + colSumSq[x];
    }
    final y0 = math.max(0, y - half), y1 = math.min(h - 1, y + half);
    final rows = (y1 - y0 + 1).toDouble();
    final rowBase = y * w;
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - half), x1 = math.min(w - 1, x + half);
      final area = rows * (x1 - x0 + 1);
      final sum = prefix[x1 + 1] - prefix[x0];
      final sumSq = prefixSq[x1 + 1] - prefixSq[x0];
      final mean = sum / area;
      final variance = math.max(0.0, sumSq / area - mean * mean);
      final std = math.sqrt(variance);
      final t = mean * (1 + k * (std / maxStd - 1));
      out[rowBase + x] = g.d[rowBase + x] <= t ? 1 : 0;
    }
  }
  return BinImage(w, h, out);
}

/* ------------------------------------------------------------------ *
 * 连通域
 * ------------------------------------------------------------------ */

class Comp {
  int minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1, area = 0;
  double sumX = 0, sumY = 0;
  late Uint8List mask; // 尺寸 w*h，1 = 属于该连通域

  int get w => maxX - minX + 1;
  int get h => maxY - minY + 1;
  double get aspect => h == 0 ? 0 : w / h;
  double get cx => area == 0 ? 0 : sumX / area;
  double get cy => area == 0 ? 0 : sumY / area;
  double get density => (w * h) == 0 ? 0 : area / (w * h);

  /// 笔画的“粗细”：面积 / 外接框周长近似
  double get thickness => (w + h) == 0 ? 0 : area / (w + h).toDouble();
}

/// 8 连通标记；[minArea] 以下的噪点直接丢弃
List<Comp> connectedComponents(BinImage b, {int minArea = 2}) {
  final w = b.w, h = b.h;
  final seen = Uint8List(w * h);
  final out = <Comp>[];
  final stack = <int>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      if (seen[idx] != 0 || b.d[idx] == 0) continue;
      final comp = Comp();
      final pixels = <int>[];
      stack.add(idx);
      seen[idx] = 1;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final px = p % w, py = p ~/ w;
        pixels.add(p);
        comp.area++;
        comp.sumX += px;
        comp.sumY += py;
        if (px < comp.minX) comp.minX = px;
        if (py < comp.minY) comp.minY = py;
        if (px > comp.maxX) comp.maxX = px;
        if (py > comp.maxY) comp.maxY = py;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = px + dx, ny = py + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            final ni = ny * w + nx;
            if (seen[ni] != 0 || b.d[ni] == 0) continue;
            seen[ni] = 1;
            stack.add(ni);
          }
        }
      }
      if (comp.area < minArea) continue;
      comp.mask = Uint8List(comp.w * comp.h);
      for (final p in pixels) {
        final px = p % w, py = p ~/ w;
        comp.mask[(py - comp.minY) * comp.w + (px - comp.minX)] = 1;
      }
      out.add(comp);
    }
  }
  return out;
}

/// 统计被包围的“孔洞”数量（用于区分 0/6/8/4 等）
int countHoles(Comp c) {
  final w = c.w, h = c.h;
  final bg = Uint8List(w * h);
  final stack = <int>[];
  void push(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final i = y * w + x;
    if (bg[i] != 0 || c.mask[i] != 0) return;
    bg[i] = 1;
    stack.add(i);
  }

  for (var x = 0; x < w; x++) {
    push(x, 0);
    push(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    push(0, y);
    push(w - 1, y);
  }
  while (stack.isNotEmpty) {
    final p = stack.removeLast();
    final x = p % w, y = p ~/ w;
    push(x - 1, y);
    push(x + 1, y);
    push(x, y - 1);
    push(x, y + 1);
  }
  var holes = 0;
  final seen = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    if (c.mask[i] != 0 || bg[i] != 0 || seen[i] != 0) continue;
    holes++;
    final st = <int>[i];
    seen[i] = 1;
    while (st.isNotEmpty) {
      final p = st.removeLast();
      final x = p % w, y = p ~/ w;
      for (final d in const [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
        final nx = x + d[0], ny = y + d[1];
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final ni = ny * w + nx;
        if (seen[ni] != 0 || c.mask[ni] != 0 || bg[ni] != 0) continue;
        seen[ni] = 1;
        st.add(ni);
      }
    }
  }
  return holes;
}

/* ------------------------------------------------------------------ *
 * 倾斜校正
 * ------------------------------------------------------------------ */

/// 用行投影方差估计倾斜角（不旋转，只返回角度）
double estimateSkewAngle(BinImage src, {double maxDeg = 6, double step = 0.5}) {
  var bestAngle = 0.0;
  var bestScore = -1.0;
  for (var a = -maxDeg; a <= maxDeg + 1e-9; a += step) {
    final score = _projectionScore(src, a);
    if (score > bestScore) {
      bestScore = score;
      bestAngle = a;
    }
  }
  return bestAngle;
}

/// 用行投影方差估计倾斜角，并旋转回正
BinImage deskew(BinImage src, {double maxDeg = 6, double step = 0.5}) {
  final bestAngle = estimateSkewAngle(src, maxDeg: maxDeg, step: step);
  if (bestAngle.abs() < step / 2) return src;
  return rotate(src, bestAngle);
}

double _projectionScore(BinImage b, double deg) {
  final rad = deg * math.pi / 180;
  final tan = math.tan(rad);
  final rows = List<double>.filled(b.h, 0);
  for (var y = 0; y < b.h; y++) {
    final shift = ((y - b.h / 2) * tan).round();
    var count = 0;
    for (var x = 0; x < b.w; x++) {
      final sx = x + shift;
      if (sx >= 0 && sx < b.w && b.d[y * b.w + sx] != 0) count++;
    }
    rows[y] = count.toDouble();
  }
  // 行投影的方差越大，说明行与行之间越“分明”
  var mean = 0.0;
  for (final v in rows) {
    mean += v;
  }
  mean /= rows.length;
  var varr = 0.0;
  for (final v in rows) {
    varr += (v - mean) * (v - mean);
  }
  return varr / rows.length;
}

BinImage rotate(BinImage src, double deg) {
  final rad = deg * math.pi / 180;
  final cosA = math.cos(rad), sinA = math.sin(rad);
  final w = src.w, h = src.h;
  final cx = w / 2, cy = h / 2;
  final out = BinImage(w, h, Uint8List(w * h));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - cx, dy = y - cy;
      final sx = (dx * cosA - dy * sinA + cx).round();
      final sy = (dx * sinA + dy * cosA + cy).round();
      if (src.at(sx, sy)) out.d[y * w + x] = 1;
    }
  }
  return out;
}

/* ------------------------------------------------------------------ *
 * 字形模板与分类
 * ------------------------------------------------------------------ */

/// 归一化后的字形模板（固定 24×32 网格，保持宽高比并水平居中）
class GlyphTemplate {
  final String label;
  final Float32List mask; // 24*32
  final double aspect; // 原始宽/高
  final int holes;
  final double density;
  const GlyphTemplate(this.label, this.mask, this.aspect, this.holes, this.density);
}

const int kTw = 24;
const int kTh = 32;

/// 把连通域归一化成 24×32 的掩码（高度缩放到 28，保持宽高比，水平居中）
///
/// 采用**面积平均**采样而不是最近邻：真实谱子的数字往往只有十几像素高，
/// 放大到标准网格时最近邻会产生锯齿、和字体模板对不上；面积平均接近抗锯齿效果，
/// 两边的归一化方式一致后匹配分数才可比。
Float32List normalizeGlyph(Comp c) {
  final out = Float32List(kTw * kTh);
  final gw = c.w, gh = c.h;
  if (gw <= 0 || gh <= 0) return out;
  const targetH = 28.0;
  final scale = targetH / gh;
  final tw = math.max(1, (gw * scale).round());
  final offsetY = ((kTh - targetH) / 2).round();
  final offsetX = ((kTw - tw) / 2).round();
  for (var ty = 0; ty < targetH.round(); ty++) {
    final iy0 = (ty / scale).floor().clamp(0, gh - 1);
    final iy1 = math.min(gh - 1, math.max(iy0, ((ty + 1) / scale - 1e-9).floor()));
    for (var tx = 0; tx < tw; tx++) {
      final ix0 = (tx / scale).floor().clamp(0, gw - 1);
      final ix1 = math.min(gw - 1, math.max(ix0, ((tx + 1) / scale - 1e-9).floor()));
      var sum = 0.0;
      var count = 0;
      for (var y = iy0; y <= iy1; y++) {
        for (var x = ix0; x <= ix1; x++) {
          sum += c.mask[y * gw + x];
          count++;
        }
      }
      if (count == 0) continue;
      final px = offsetX + tx;
      final py = offsetY + ty;
      if (px < 0 || py < 0 || px >= kTw || py >= kTh) continue;
      out[py * kTw + px] = sum / count;
    }
  }
  return out;
}

class Candidate {
  final String label;
  final double score;
  const Candidate(this.label, this.score);
}

class Recognition {
  final String label;
  final double score;
  final List<Candidate> ranking; // 从高到低
  const Recognition(this.label, this.score, this.ranking);
}

/// 字形分类器：多字体模板（IoU + 形状特征）联合打分
class GlyphClassifier {
  final List<GlyphTemplate> templates;
  GlyphClassifier(this.templates);

  Recognition classify(Comp c) {
    final mask = normalizeGlyph(c);
    final holes = countHoles(c);
    final density = c.area / math.max(1, c.w * c.h);
    final aspect = c.w / math.max(1, c.h);

    final scores = <String, double>{};
    for (final t in templates) {
      final iou = _bestIou(mask, t.mask);
      final feat = _featureSim(aspect: aspect, holes: holes, density: density, t: t);
      final s = iou * 0.78 + feat * 0.22;
      if (!scores.containsKey(t.label) || s > scores[t.label]!) scores[t.label] = s;
    }
    final ranking = scores.entries.map((e) => Candidate(e.key, e.value)).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final top = ranking.isEmpty ? const Candidate('?', 0) : ranking.first;
    // 置信度：top1 绝对分 + 与 top2 的间距
    final second = ranking.length > 1 ? ranking[1].score : 0.0;
    final conf = (top.score * 0.7 + (top.score - second).clamp(0.0, 0.5) * 0.6).clamp(0.0, 1.0);
    return Recognition(top.label, conf, ranking);
  }

  /// 模糊 Jaccard 相似度：Σmin/Σmax。
  /// 掩码是面积平均得到的灰度（0..1），比硬阈值 IoU 更能容忍笔画粗细差异。
  double _bestIou(Float32List a, Float32List b) {
    var best = 0.0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        var inter = 0.0, union = 0.0;
        for (var y = 0; y < kTh; y++) {
          for (var x = 0; x < kTw; x++) {
            final av = a[y * kTw + x];
            final bx = x + dx, by = y + dy;
            final bv = (bx >= 0 && by >= 0 && bx < kTw && by < kTh) ? b[by * kTw + bx] : 0.0;
            inter += av < bv ? av : bv;
            union += av > bv ? av : bv;
          }
        }
        if (union > 1e-6) {
          final iou = inter / union;
          if (iou > best) best = iou;
        }
      }
    }
    return best;
  }

  double _featureSim({required double aspect, required int holes, required double density, required GlyphTemplate t}) {
    final dAspect = (aspect - t.aspect).abs() / 0.6;
    final dHoles = (holes - t.holes).abs() / 2.0;
    final dDensity = (density - t.density).abs() / 0.5;
    final sim = 1.0 - (dAspect * 0.45 + dHoles * 0.35 + dDensity * 0.2);
    return sim.clamp(0.0, 1.0);
  }
}
