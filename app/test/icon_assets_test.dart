/// 应用图标生成器（用 Flutter 自带解码器，无需第三方依赖）
///
///   flutter test test/icon_assets_test.dart
///
/// 源图：assets/icon/app_icon.webp（1920×1920）
/// 生成：
///   android/app/src/main/res/mipmap-*/ic_launcher.png  （48/72/96/144/192）
///   windows/runner/resources/app_icon.ico              （16~256 多尺寸，PNG 内嵌）
///   assets/icon/app_icon_1024.png                      （归档一份 PNG 源）
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String kSource = 'assets/icon/app_icon.webp';

/// Android 各密度对应的图标边长
const Map<String, int> kAndroidMipmaps = {
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

/// Windows ICO 内嵌的尺寸（PNG 压缩，Vista 以后都支持）
const List<int> kIcoSizes = [16, 24, 32, 48, 64, 128, 256];

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// 把图片按边长缩放后编码成 PNG（正方形，居中不裁切；源图本身就是正方形）
Future<Uint8List> _pngAtSize(ui.Image src, int size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()));
  final paint = Paint()
    ..filterQuality = FilterQuality.high
    ..isAntiAlias = true;
  canvas.drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    paint,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (data == null) throw StateError('PNG 编码失败（$size）');
  return data.buffer.asUint8List();
}

/// 组装多尺寸 ICO（每个尺寸存一张 PNG）
Uint8List _buildIco(Map<int, Uint8List> pngs) {
  final sizes = pngs.keys.toList()..sort();
  final header = BytesBuilder();
  // ICONDIR: reserved(2) + type(2, 1=icon) + count(2)
  header.add([0, 0, 1, 0, sizes.length & 0xFF, (sizes.length >> 8) & 0xFF]);
  var offset = 6 + 16 * sizes.length;
  final entries = BytesBuilder();
  final payload = BytesBuilder();
  for (final size in sizes) {
    final data = pngs[size]!;
    // ICONDIRENTRY: width, height, colors, reserved, planes, bpp, bytes, offset
    entries.add([
      size >= 256 ? 0 : size, // 256 用 0 表示
      size >= 256 ? 0 : size,
      0, 0, // 调色板数 / 保留
      1, 0, // planes
      32, 0, // 位深
      data.length & 0xFF, (data.length >> 8) & 0xFF, (data.length >> 16) & 0xFF, (data.length >> 24) & 0xFF,
      offset & 0xFF, (offset >> 8) & 0xFF, (offset >> 16) & 0xFF, (offset >> 24) & 0xFF,
    ]);
    payload.add(data);
    offset += data.length;
  }
  final out = BytesBuilder();
  out.add(header.toBytes());
  out.add(entries.toBytes());
  out.add(payload.toBytes());
  return out.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('从源图生成安卓与 Windows 图标', () async {
    final source = File(kSource);
    expect(source.existsSync(), isTrue, reason: '缺少图标源文件 $kSource');

    final src = await _decode(source.readAsBytesSync());
    expect(src.width, greaterThan(64));
    // ignore: avoid_print
    print('源图尺寸：${src.width}×${src.height}');

    // 1) Android mipmap
    for (final entry in kAndroidMipmaps.entries) {
      final dir = Directory('android/app/src/main/res/${entry.key}');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final png = await _pngAtSize(src, entry.value);
      File('${dir.path}/ic_launcher.png').writeAsBytesSync(png);
      expect(png.length, greaterThan(200));
      // ignore: avoid_print
      print('  ${entry.key}/ic_launcher.png  ${entry.value}×${entry.value}  ${(png.length / 1024).toStringAsFixed(1)}KB');
    }

    // 2) Windows ICO（多尺寸）
    final pngs = <int, Uint8List>{};
    for (final size in kIcoSizes) {
      pngs[size] = await _pngAtSize(src, size);
    }
    final ico = _buildIco(pngs);
    final icoPath = 'windows/runner/resources/app_icon.ico';
    File(icoPath).writeAsBytesSync(ico);
    // ignore: avoid_print
    print('  $icoPath  ${kIcoSizes.length} 个尺寸  ${(ico.length / 1024).toStringAsFixed(1)}KB');
    // ICO 头校验：00 00 01 00
    expect(ico[0], 0);
    expect(ico[1], 0);
    expect(ico[2], 1);
    expect(ico[3], 0);

    // 3) 归档一张 1024 PNG 源（方便以后重新生成）
    final big = await _pngAtSize(src, 1024);
    File('assets/icon/app_icon_1024.png').writeAsBytesSync(big);
    // ignore: avoid_print
    print('  assets/icon/app_icon_1024.png  ${(big.length / 1024).toStringAsFixed(1)}KB');

    src.dispose();
  });
}
