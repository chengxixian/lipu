/// 字形模板生成（Flutter 层）：用系统字体渲染 0-7 等字符，供分类器比对
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'omr_core.dart';

/// 需要参与分类的字符
const List<String> kDigitLabels = ['0', '1', '2', '3', '4', '5', '6', '7'];
const List<String> kSymbolLabels = ['#', 'b', 'n', '=', '/', '|', '-', '.', 'C', 'D', 'E', 'F', 'G', 'A', 'B'];

/// 移动端可用字体族有限（基本都是 Noto/Roboto），用短列表即可，
/// 既能显著降低模板生成耗时与内存，也不会损失精度。
const List<String> kTemplateFontsMobile = [
  'Roboto',
  'Noto Sans',
  'sans-serif',
  'serif',
  'Noto Serif',
];

/// 各平台常见的无衬线 / 衬线字体族，覆盖印刷体与屏幕字体
const List<String> kTemplateFonts = [
  'Roboto',
  'Noto Sans',
  'sans-serif',
  'serif',
  'Arial',
  'Times New Roman',
  'Calibri',
  'Cambria',
  'Segoe UI',
  'Verdana',
  'Georgia',
  'SimSun',
  'SimHei',
];

const List<FontWeight> kTemplateWeights = [FontWeight.w400, FontWeight.w600, FontWeight.w800];

/// 渲染单个字符为二值掩码（裁剪到字形的紧致外接框）
class _Raster {
  final int w, h;
  final Uint8List mask;
  _Raster(this.w, this.h, this.mask);
}

Future<_Raster?> _rasterize(String ch, String fontFamily, FontWeight weight) async {
  const canvasSize = 96;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()));
  // 白底
  canvas.drawRect(
    Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final tp = TextPainter(
    text: TextSpan(
      text: ch,
      style: TextStyle(fontSize: 64, fontFamily: fontFamily, fontWeight: weight, color: const Color(0xFF000000)),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset((canvasSize - tp.width) / 2, (canvasSize - tp.height) / 2));
  final picture = recorder.endRecording();
  final image = await picture.toImage(canvasSize, canvasSize);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = data == null ? null : _rasterFromRgba(data.buffer.asUint8List(), canvasSize, canvasSize, 128);
  // 及时释放：一次要渲染数百张，不释放会累积大量纹理内存
  image.dispose();
  picture.dispose();
  return out;
}

_Raster? _rasterFromRgba(Uint8List rgba, int w, int h, int threshold) {
  var minX = w, minY = h, maxX = -1, maxY = -1;
  final bits = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = (y * w + x) * 4;
      final lum = (rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) ~/ 1000;
      if (lum < threshold) {
        bits[y * w + x] = 1;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < minX || maxY < minY) return null;
  final cw = maxX - minX + 1, chh = maxY - minY + 1;
  final mask = Uint8List(cw * chh);
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      if (bits[y * w + x] != 0) mask[(y - minY) * cw + (x - minX)] = 1;
    }
  }
  return _Raster(cw, chh, mask);
}

/// 生成模板集（异步，建议在启动时后台预生成并缓存）
///
/// [fonts] 可覆盖默认字体族列表（测试环境里需要显式加载真实字体后传入）。
Future<GlyphClassifier> buildGlyphClassifier({List<String>? extraLabels, List<String>? fonts}) async {
  final labels = <String>[...kDigitLabels, ...kSymbolLabels, ...?extraLabels];
  final fontList = fonts ?? kFontsForCurrentPlatform();
  final templates = <GlyphTemplate>[];
  var rendered = 0;

  // 模板要渲染几百张，期间定期让出事件循环，避免把界面卡住
  Future<void> breathe() async {
    if (++rendered % 16 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  for (final label in labels) {
    for (final font in fontList) {
      for (final weight in kTemplateWeights) {
        final raster = await _rasterize(label, font, weight);
        await breathe();
        if (raster == null) continue;
        final comp = _CompAdapter(raster.w, raster.h, raster.mask);
        // 归一化到标准网格
        final normalized = normalizeGlyph(comp);
        final holes = countHoles(comp);
        final density = comp.area / (raster.w * raster.h);
        final aspect = raster.w / raster.h;
        templates.add(GlyphTemplate(label, normalized, aspect, holes, density));
      }
    }
    // 斜体变体，增强对手写/倾斜印刷体的容忍度
    for (final font in fontList.take(4)) {
      final raster = await _rasterizeItalic(label, font);
      await breathe();
      if (raster == null) continue;
      final comp = _CompAdapter(raster.w, raster.h, raster.mask);
      templates.add(GlyphTemplate(
        label,
        normalizeGlyph(comp),
        raster.w / raster.h,
        countHoles(comp),
        comp.area / (raster.w * raster.h),
      ));
    }
  }
  return GlyphClassifier(templates);
}

/// 按平台挑选模板字体：移动端可用的字体族很少，长列表只是重复渲染
List<String> kFontsForCurrentPlatform() {
  if (Platform.isAndroid || Platform.isIOS) return kTemplateFontsMobile;
  return kTemplateFonts;
}

Future<_Raster?> _rasterizeItalic(String ch, String fontFamily) async {
  const canvasSize = 96;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()));
  canvas.drawRect(
    Rect.fromLTWH(0, 0, canvasSize.toDouble(), canvasSize.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.save();
  canvas.translate(canvasSize / 2, canvasSize / 2);
  canvas.skew(0.18, 0); // 斜体变体
  final tp = TextPainter(
    text: TextSpan(
      text: ch,
      style: TextStyle(fontSize: 64, fontFamily: fontFamily, color: const Color(0xFF000000)),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  canvas.restore();
  final picture = recorder.endRecording();
  final image = await picture.toImage(canvasSize, canvasSize);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return null;
  return _rasterFromRgba(data.buffer.asUint8List(), canvasSize, canvasSize, 128);
}

/// 把简单位图包装成 `Comp`，以便复用归一化/孔洞统计逻辑
class _CompAdapter extends Comp {
  final int _w, _h;
  _CompAdapter(this._w, this._h, Uint8List mask) {
    minX = 0;
    minY = 0;
    maxX = _w - 1;
    maxY = _h - 1;
    var a = 0;
    var sx = 0.0, sy = 0.0;
    for (var y = 0; y < _h; y++) {
      for (var x = 0; x < _w; x++) {
        if (mask[y * _w + x] != 0) {
          a++;
          sx += x;
          sy += y;
        }
      }
    }
    area = a;
    sumX = sx;
    sumY = sy;
    this.mask = mask;
  }
}
