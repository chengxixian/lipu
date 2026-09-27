/// 简易合成器：把乐谱渲染成 16bit PCM WAV（纯 Dart，用于本地试听）
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/model.dart';
import 'notes.dart';

/// 生成 WAV 字节
Uint8List synthesizeWav(
  Score score, {
  int sampleRate = 44100,
  double gain = 0.32,
  int timbre = 0, // 0 = 钢琴感，1 = 柔和正弦
}) {
  final notes = collectNotesSeconds(score);
  if (notes.isEmpty) {
    return _encodeWav(Float32List(sampleRate ~/ 2), sampleRate);
  }
  var endSec = 0.0;
  for (final n in notes) {
    endSec = math.max(endSec, n.start + n.duration);
  }
  final total = ((endSec + 1.2) * sampleRate).round();
  final buffer = Float32List(total);

  for (final n in notes) {
    final freq = 440.0 * math.pow(2, (n.midi - 69) / 12.0);
    final startSample = (n.start * sampleRate).round();
    final durSamples = (n.duration * sampleRate).round();
    final releaseSamples = (0.06 * sampleRate).round();
    final stop = math.min(total, startSample + durSamples + releaseSamples);
    for (var i = startSample; i < stop; i++) {
      final t = (i - startSample) / sampleRate;
      // 包络：5ms 起音 + 指数衰减 + 尾部释放
      final attack = math.min(1.0, t / 0.005);
      final decay = math.exp(-t * (timbre == 0 ? 1.1 : 2.2));
      var release = 1.0;
      if (i > startSample + durSamples) {
        release = 1.0 - (i - startSample - durSamples) / math.max(1, releaseSamples);
      }
      final env = attack * decay * math.max(0.0, release);
      if (env <= 0) continue;
      final phase = 2 * math.pi * freq * t;
      double s;
      if (timbre == 0) {
        s = math.sin(phase) + 0.45 * math.sin(2 * phase) + 0.22 * math.sin(3 * phase) + 0.1 * math.sin(4 * phase);
        s /= 1.77;
      } else {
        s = math.sin(phase);
      }
      buffer[i] += (s * env * 0.6).toDouble();
    }
  }
  // 归一化
  var peak = 0.0;
  for (final v in buffer) {
    peak = math.max(peak, v.abs());
  }
  if (peak > 0) {
    final k = gain / peak;
    for (var i = 0; i < buffer.length; i++) {
      buffer[i] = (buffer[i] * k).clamp(-1.0, 1.0);
    }
  }
  return _encodeWav(buffer, sampleRate);
}

Uint8List _encodeWav(Float32List samples, int sampleRate) {
  final dataLength = samples.length * 2;
  final out = ByteData(44 + dataLength);
  void writeString(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  out.setUint32(4, 36 + dataLength, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  writeString(36, 'data');
  out.setUint32(40, dataLength, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i] * 32767).round().clamp(-32768, 32767);
    out.setInt16(44 + i * 2, v, Endian.little);
  }
  return out.buffer.asUint8List();
}
