/// WAV（RIFF）解码 + 重采样：把音频文件变成分析用的单声道 Float64 采样
///
/// 只用 dart:typed_data，不依赖任何第三方库。
library;

import 'dart:typed_data';

class WavData {
  final int sampleRate;
  final int channels;
  final Float64List samples; // 交错排列（多声道）
  const WavData(this.sampleRate, this.channels, this.samples);

  int get frames => channels == 0 ? 0 : samples.length ~/ channels;
  double get durationSec => sampleRate == 0 ? 0 : frames / sampleRate;
}

/// 解析 WAV 字节。支持 PCM 8/16/24/32 位与 IEEE float 32/64 位。
WavData decodeWav(Uint8List bytes) {
  if (bytes.length < 44) throw const FormatException('文件太小，不是有效的 WAV');
  final bd = ByteData.sublistView(bytes);
  String tag(int offset) => String.fromCharCodes(bytes.sublist(offset, offset + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('不是 RIFF/WAVE 文件');

  var offset = 12;
  int? audioFormat;
  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  Uint8List? dataChunk;

  while (offset + 8 <= bytes.length) {
    final id = tag(offset);
    final size = bd.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      audioFormat = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      sampleRate = bd.getUint32(body + 4, Endian.little);
      bitsPerSample = bd.getUint16(body + 14, Endian.little);
      // 扩展格式（0xFFFE）时真正的格式在 cbSize 之后
      if (audioFormat == 0xFFFE && size >= 40) {
        audioFormat = bd.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      final end = (body + size > bytes.length) ? bytes.length : body + size;
      dataChunk = Uint8List.sublistView(bytes, body, end);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }

  if (audioFormat == null || channels == null || sampleRate == null || bitsPerSample == null) {
    throw const FormatException('WAV 缺少 fmt 块');
  }
  if (dataChunk == null) throw const FormatException('WAV 缺少 data 块');
  if (channels == 0) throw const FormatException('WAV 声道数为 0');

  final bytesPerSample = bitsPerSample ~/ 8;
  final count = dataChunk.length ~/ bytesPerSample;
  final out = Float64List(count);
  final data = ByteData.sublistView(dataChunk);

  for (var i = 0; i < count; i++) {
    final p = i * bytesPerSample;
    double v;
    switch (audioFormat) {
      case 1: // PCM 整数
        switch (bitsPerSample) {
          case 8:
            v = (dataChunk[p] - 128) / 128.0;
            break;
          case 16:
            v = data.getInt16(p, Endian.little) / 32768.0;
            break;
          case 24:
            var raw = dataChunk[p] | (dataChunk[p + 1] << 8) | (dataChunk[p + 2] << 16);
            if (raw & 0x800000 != 0) raw -= 0x1000000;
            v = raw / 8388608.0;
            break;
          case 32:
            v = data.getInt32(p, Endian.little) / 2147483648.0;
            break;
          default:
            throw FormatException('不支持的位深: $bitsPerSample');
        }
        break;
      case 3: // IEEE float
        if (bitsPerSample == 32) {
          v = data.getFloat32(p, Endian.little);
        } else if (bitsPerSample == 64) {
          v = data.getFloat64(p, Endian.little);
        } else {
          throw FormatException('不支持的浮点位深: $bitsPerSample');
        }
        break;
      default:
        throw FormatException('不支持的 WAV 编码格式: $audioFormat');
    }
    out[i] = v.isFinite ? v : 0.0;
  }
  return WavData(sampleRate, channels, out);
}

/// 多声道 -> 单声道
Float64List toMono(WavData wav) {
  if (wav.channels == 1) return wav.samples;
  final n = wav.frames;
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    var sum = 0.0;
    for (var c = 0; c < wav.channels; c++) {
      sum += wav.samples[i * wav.channels + c];
    }
    out[i] = sum / wav.channels;
  }
  return out;
}

/// 线性插值重采样（够用，且不会像最近邻那样丢音高信息）
Float64List resample(Float64List input, int fromRate, int toRate) {
  if (fromRate == toRate || input.isEmpty) return input;
  final outLength = (input.length * toRate / fromRate).floor();
  final out = Float64List(outLength);
  final ratio = fromRate / toRate;
  for (var i = 0; i < outLength; i++) {
    final src = i * ratio;
    final i0 = src.floor();
    final i1 = i0 + 1 < input.length ? i0 + 1 : i0;
    final frac = src - i0;
    out[i] = input[i0] * (1 - frac) + input[i1] * frac;
  }
  return out;
}

/// 归一化到 [-1,1]（部分文件录制电平过低会严重影响阈值判断）
Float64List normalize(Float64List input, {double target = 0.9}) {
  var peak = 0.0;
  for (final v in input) {
    final a = v.abs();
    if (a > peak) peak = a;
  }
  if (peak < 1e-6) return input;
  final k = target / peak;
  final out = Float64List(input.length);
  for (var i = 0; i < input.length; i++) {
    out[i] = input[i] * k;
  }
  return out;
}

/// 把单声道 float 采样编码成 16bit PCM WAV（用于把原生解码结果落盘）
Uint8List encodeWav16(Float64List samples, int sampleRate, {int channels = 1}) {
  final dataLength = samples.length * 2;
  final out = ByteData(44 + dataLength);
  void tag(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + dataLength, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, channels, Endian.little);
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * channels * 2, Endian.little);
  out.setUint16(32, channels * 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  out.setUint32(40, dataLength, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    out.setInt16(44 + i * 2, v, Endian.little);
  }
  return out.buffer.asUint8List();
}
