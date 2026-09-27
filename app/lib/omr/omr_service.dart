/// 图片 -> 简谱识别服务（Flutter 层：解码图片、缓存模板、跑 OMR 流水线）
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'omr.dart';
import 'omr_core.dart';
import 'omr_templates.dart';

class OmrOutcome {
  final OmrResult result;

  /// 本地识别才有灰度图/二值图；AI 识谱走网络，没有这些中间结果
  final GrayImage? gray;
  final BinImage? binary;
  final int decodeWidth, decodeHeight;
  const OmrOutcome(this.result, this.gray, this.binary, this.decodeWidth, this.decodeHeight);
}

GlyphClassifier? _cachedClassifier;
Future<GlyphClassifier>? _building;

/// 测试用注入口：单元测试里没有系统字体，需要传入用已加载字体构建的分类器
@visibleForTesting
GlyphClassifier? debugClassifierOverride;

/// 预生成（或复用）字形模板
Future<GlyphClassifier> glyphClassifier({bool forceRebuild = false}) {
  final override = debugClassifierOverride;
  if (override != null) return Future.value(override);
  if (_cachedClassifier != null && !forceRebuild) return Future.value(_cachedClassifier);
  _building ??= buildGlyphClassifier().then((c) {
    _cachedClassifier = c;
    return c;
  });
  return _building!;
}

/// 识别一张图片（bytes 为 PNG/JPEG 原始字节）
///
/// 1) 只按目标尺寸解码一次：用 ImageDescriptor 读头部拿到原始尺寸，避免先全尺寸
///    解码再缩放（手机照片全尺寸 RGBA 动辄 40MB+，会 OOM 闪退）
/// 2) 真正的图像分析全部丢到后台 isolate：这些是纯 Dart 计算，不需要 GPU，
///    放在 UI 线程上会把界面卡住好几秒（Windows 上表现为"卡"、Android 上更糟）
/// 3) isolate 会把进度通过 SendPort 回传，界面用确定性进度条显示到"第几行"
Future<OmrOutcome> recognizeImageBytes(
  Uint8List bytes, {
  OmrOptions options = const OmrOptions(),
  int? maxDimension,
  OmrProgress? onProgress,
}) async {
  // 移动端内存/算力都紧张，把上限压得更低一些；识别精度几乎不受影响
  final limit = maxDimension ?? (Platform.isAndroid || Platform.isIOS ? 1200 : 1800);
  onProgress?.call(0.0, '解码图片');
  final decoded = await decodeGrayScaled(bytes, limit);
  final gray = decoded.gray;
  final imgW = gray.w;
  final imgH = gray.h;

  final classifier = await glyphClassifier();
  onProgress?.call(0.02, '准备字形模板');
  final out = await _runOmrIsolate(
    <String, dynamic>{
      'w': gray.w,
      'h': gray.h,
      'data': gray.d,
      'options': options,
      'templates': classifier.templates,
    },
    onProgress: onProgress,
  );
  final result = out['result'] as OmrResult;
  final binary = BinImage(out['bw'] as int, out['bh'] as int, out['bdata'] as Uint8List);
  return OmrOutcome(result, gray, binary, imgW, imgH);
}

/// 按最长边限制解码图片，并转成灰度图（只解码一次，避免全尺寸 RGBA 撑爆内存）
Future<({GrayImage gray, int originalWidth, int originalHeight})> decodeGrayScaled(
  Uint8List bytes,
  int limit,
) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);

  var targetWidth = descriptor.width;
  var targetHeight = descriptor.height;
  final longest = math.max(descriptor.width, descriptor.height);
  if (longest > limit && longest > 0) {
    final scale = limit / longest;
    targetWidth = math.max(1, (descriptor.width * scale).round());
    targetHeight = math.max(1, (descriptor.height * scale).round());
  }

  final codec = await descriptor.instantiateCodec(targetWidth: targetWidth, targetHeight: targetHeight);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final imgW = image.width;
  final imgH = image.height;
  if (data == null) {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    throw StateError('图片解码失败');
  }
  final gray = GrayImage.fromRgba(data.buffer.asUint8List(), imgW, imgH);
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return (gray: gray, originalWidth: imgW, originalHeight: imgH);
}

/// 在后台 isolate 里跑识别，并把进度回传主 isolate
Future<Map<String, dynamic>> _runOmrIsolate(
  Map<String, dynamic> payload, {
  OmrProgress? onProgress,
  String isolateName = 'jianpu-omr',
}) async {
  final receive = ReceivePort();
  final errors = ReceivePort();
  final completer = Completer<Map<String, dynamic>>();

  receive.listen((message) {
    if (message is! Map) return;
    switch (message['type']) {
      case 'progress':
        onProgress?.call((message['fraction'] as num).toDouble(), message['stage'] as String);
        break;
      case 'result':
        if (!completer.isCompleted) completer.complete(Map<String, dynamic>.from(message));
        break;
      case 'error':
        if (!completer.isCompleted) completer.completeError(StateError('识别失败：${message['message']}'));
        break;
    }
  });
  errors.listen((message) {
    if (!completer.isCompleted) completer.completeError(StateError('识别进程异常：$message'));
  });

  final isolate = await Isolate.spawn(
    _omrIsolateEntry,
    <String, dynamic>{'port': receive.sendPort, 'payload': payload},
    onError: errors.sendPort,
    errorsAreFatal: true,
    debugName: isolateName,
  );
  try {
    return await completer.future;
  } finally {
    isolate.kill(priority: Isolate.immediate);
    receive.close();
    errors.close();
  }
}

/// 后台 isolate 的入口（纯 Dart，不含任何 dart:ui 调用）
void _omrIsolateEntry(Map<String, dynamic> args) {
  final port = args['port'] as SendPort;
  final payload = args['payload'] as Map<String, dynamic>;
  void report(double fraction, String stage) =>
      port.send(<String, dynamic>{'type': 'progress', 'fraction': fraction, 'stage': stage});

  try {
    final gray = GrayImage(payload['w'] as int, payload['h'] as int, payload['data'] as Uint8List);
    final options = payload['options'] as OmrOptions;
    if (payload['mode'] == 'strips') {
      // 只做版面分析与裁图（给 AI 分行并发用），不跑字形识别
      final split = splitPageStrips(gray, options: options);
      port.send(<String, dynamic>{
        'type': 'result',
        'systems': split.systemCount,
        'diag': split.diag,
        'bands': [
          for (final b in split.bands) [b.$1, b.$2],
        ],
        'bandGlyphs': split.bandGlyphs,
        'medianH': split.medianH,
        'mode': split.mode == ScoreLayoutMode.grandStaff ? 'grand' : 'single',
        'groupSizes': split.groupSizes,
        'strips': [
          for (final s in split.strips)
            <String, dynamic>{
              'w': s.bin.w,
              'h': s.bin.h,
              'd': s.bin.d,
              'header': s.header,
              'index': s.groupIndex,
              'y0': s.y0,
              'y1': s.y1,
            },
        ],
      });
      return;
    }
    final classifier = GlyphClassifier(payload['templates'] as List<GlyphTemplate>);
    // 整页识别：内部会按行切条并放大，进度映射到 0.05~0.98
    final page = recognizeJianpuPage(
      gray,
      classifier,
      options: options,
      onProgress: (f, stage) => report(0.05 + f * 0.93, stage),
    );
    port.send(<String, dynamic>{
      'type': 'result',
      'result': page.result,
      'bw': page.pageBinary.w,
      'bh': page.pageBinary.h,
      'bdata': page.pageBinary.d,
    });
  } catch (e, st) {
    port.send(<String, dynamic>{'type': 'error', 'message': '$e\n$st'});
  }
}

/// 把二值图导出成 PNG（界面里用于预览二值化效果）
Future<Uint8List> binToPng(BinImage bin) async {  final buffer = await ui.ImmutableBuffer.fromUint8List(bin.toRgba());
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: bin.w,
    height: bin.h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  final out = png!.buffer.asUint8List();
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return out;
}

/* ------------------------------------------------------------------ *
 * 给 AI 分行并发识谱切图
 * ------------------------------------------------------------------ */

/// 一张要发给 AI 的行条图（PNG）+ 它在整页里的位置
class AiStripImage {
  final Uint8List png;

  /// 是否是页面顶部的标题区（曲名/调号/拍号/速度）
  final bool header;

  /// 第几组谱行（header 为 -1）
  final int groupIndex;

  /// 在整页里的 y 范围（不含 padding），用于调试与界面提示
  final int y0, y1;

  const AiStripImage(this.png, this.header, this.groupIndex, this.y0, this.y1);

  int get height => y1 - y0;
}

class AiPageSplit {
  /// 标题区（如果有）+ **每个谱表行一张图**（顺序 = 从上到下）
  final List<AiStripImage> strips;
  final int systemCount;
  final List<String> diag;

  /// 版面分析出来的原始行（y0..y1）与每行的"简谱字形数"
  final List<(int, int)> bands;
  final List<int> bandGlyphs;
  final double medianH;

  /// 本地几何判断的谱式（AI 的判断优先，本地只作兜底与交叉验证）
  final ScoreLayoutMode mode;

  /// 本地分组：每组合了几个谱表行（顺序对应 strips 里的谱行）
  final List<int> localGroupSizes;

  const AiPageSplit(
    this.strips,
    this.systemCount,
    this.diag, {
    this.bands = const [],
    this.bandGlyphs = const [],
    this.medianH = 0,
    this.mode = ScoreLayoutMode.singleLine,
    this.localGroupSizes = const [],
  });

  /// 标题区
  AiStripImage? get header {
    for (final s in strips) {
      if (s.header) return s;
    }
    return null;
  }

  /// 谱表行（不含标题区），按从上到下排序
  List<AiStripImage> get rows => strips.where((s) => !s.header).toList();

  /// 本地几何分出来的"段"：每段是一个谱表行的列表（1 行 = 单行，2 行 = 双行）
  List<List<AiStripImage>> get localSegments {
    final all = rows;
    final out = <List<AiStripImage>>[];
    var i = 0;
    for (final size in localGroupSizes) {
      final take = <AiStripImage>[];
      for (var k = 0; k < size && i < all.length; k++) {
        take.add(all[i++]);
      }
      if (take.isNotEmpty) out.add(take);
    }
    while (i < all.length) {
      out.add([all[i++]]);
    }
    return out;
  }

  /// 兼容旧调用
  List<AiStripImage> get systems => rows;
}

/// 把若干"谱表行"的图**竖着拼成一张**（AI 判定这两行属于同一组时用）
///
/// 每行的小图已经带好上下留白，直接按顺序贴在一起即可。
Future<Uint8List> composeRowStrips(List<AiStripImage> rows) async {
  if (rows.isEmpty) return Uint8List(0);
  if (rows.length == 1) return rows.first.png;
  final images = <ui.Image>[];
  try {
    for (final r in rows) {
      final codec = await ui.instantiateImageCodec(r.png);
      final frame = await codec.getNextFrame();
      images.add(frame.image);
      codec.dispose();
    }
    final width = images.map((i) => i.width).reduce(math.max);
    final height = images.map((i) => i.height).reduce((a, b) => a + b);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    var y = 0.0;
    for (final img in images) {
      canvas.drawImage(img, ui.Offset(0, y), ui.Paint());
      y += img.height;
    }
    final out = await recorder.endRecording().toImage(width, height);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    return data!.buffer.asUint8List();
  } finally {
    for (final img in images) {
      img.dispose();
    }
  }
}

/// 把整页切成"每段一组谱行"的小图（PNG），供 AI 分行并发识别
///
/// 版面分析（投影分行/合并八度点行/放大/纠斜）跟本地 OMR 用的是同一套几何，
/// 但**不跑字形识别**；图直接二值化后编码，发给视觉模型比原照片更干净。
Future<AiPageSplit> splitPageForAi(
  Uint8List bytes, {
  OmrOptions options = const OmrOptions(),
  int? maxDimension,
}) async {
  final limit = maxDimension ?? (Platform.isAndroid || Platform.isIOS ? 1200 : 1800);
  final decoded = await decodeGrayScaled(bytes, limit);
  final gray = decoded.gray;

  final out = await _runOmrIsolate(
    <String, dynamic>{
      'w': gray.w,
      'h': gray.h,
      'data': gray.d,
      'options': options,
      'mode': 'strips',
    },
    isolateName: 'jianpu-strips',
  );
  if (out['strips'] == null) throw StateError('版面分析失败');
  final raw = out['strips'] as List<dynamic>;
  final strips = <AiStripImage>[];
  for (final item in raw) {
    final m = item as Map<String, dynamic>;
    // dart:ui 的 PNG 编码只能在主 isolate 做
    final png = await binToPng(BinImage(m['w'] as int, m['h'] as int, m['d'] as Uint8List));
    strips.add(AiStripImage(png, m['header'] as bool, m['index'] as int, m['y0'] as int, m['y1'] as int));
  }
  return AiPageSplit(
    strips,
    out['systems'] as int? ?? strips.where((s) => !s.header).length,
    List<String>.from(out['diag'] as List? ?? const []),
    bands: ((out['bands'] as List?) ?? const [])
        .map((e) => ((e as List)[0] as int, e[1] as int))
        .toList(),
    bandGlyphs: List<int>.from((out['bandGlyphs'] as List?) ?? const []),
    medianH: (out['medianH'] as num?)?.toDouble() ?? 0,
    mode: (out['mode'] as String?) == 'grand' ? ScoreLayoutMode.grandStaff : ScoreLayoutMode.singleLine,
    localGroupSizes: List<int>.from((out['groupSizes'] as List?) ?? const []),
  );
}
