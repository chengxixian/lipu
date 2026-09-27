/// 音频来源：文件解码（WAV 纯 Dart；其它格式交给平台原生解码）+ 采样准备
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'wav.dart';

/// 分析用的统一采样率（扒谱不需要高采样率，22050 够用且快）
const int kAnalysisRate = 22050;

class AudioClip {
  final Float64List samples; // 单声道
  final int sampleRate;
  final String name;
  final double durationSec;

  const AudioClip(this.samples, this.sampleRate, this.name, this.durationSec);
}

class AudioDecodeException implements Exception {
  final String message;
  const AudioDecodeException(this.message);
  @override
  String toString() => message;
}

/// 平台原生解码通道：Android 端用 MediaExtractor + MediaCodec 把任意
/// 系统支持的格式（mp3/m4a/aac/flac/ogg/wav）解码成单声道 WAV 文件。
class NativeAudioDecoder {
  static const MethodChannel _channel = MethodChannel('jianpu/audio');

  /// 返回解码后的 WAV 文件路径；平台不支持时返回 null
  static Future<String?> decodeToWav(String path, {int targetSampleRate = kAnalysisRate}) async {
    try {
      final result = await _channel.invokeMethod<String>('decodeToWav', {
        'path': path,
        'sampleRate': targetSampleRate,
      });
      return result;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      throw AudioDecodeException('原生解码失败：${e.message ?? e.code}');
    }
  }

  /// 当前平台是否具备原生解码能力
  static bool get available => Platform.isAndroid;
}

/// 读取音频文件 -> 单声道 Float64（目标采样率）
Future<AudioClip> loadAudioFile(String path, {int targetSampleRate = kAnalysisRate}) async {
  final file = File(path);
  if (!file.existsSync()) throw AudioDecodeException('文件不存在：$path');
  final name = path.split(RegExp(r'[\\/]')).last;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';

  if (ext == 'wav' || ext == 'wave') {
    final wav = decodeWav(await file.readAsBytes());
    return _prepare(wav, name, targetSampleRate);
  }

  // 非 WAV：交给原生解码（Android）
  final wavPath = await NativeAudioDecoder.decodeToWav(path, targetSampleRate: targetSampleRate);
  if (wavPath == null) {
    throw AudioDecodeException(
      '当前平台只能直接读取 WAV。请先把音频转成 WAV（16bit PCM）再试，'
      '例如用格式工厂 / ffmpeg -i 歌曲.mp3 歌曲.wav。',
    );
  }
  final decoded = File(wavPath);
  try {
    final wav = decodeWav(await decoded.readAsBytes());
    return _prepare(wav, name, targetSampleRate);
  } finally {
    // 解码产物放在临时目录，用完即删
    try {
      decoded.deleteSync();
    } catch (_) {}
  }
}

/// 直接从 WAV 字节构造分析用 PCM（示例音频、内存里的音频数据）
AudioClip prepareWavBytes(Uint8List bytes, String name, {int targetSampleRate = kAnalysisRate}) =>
    _prepare(decodeWav(bytes), name, targetSampleRate);

AudioClip _prepare(WavData wav, String name, int targetSampleRate) {  var mono = toMono(wav);
  if (wav.sampleRate != targetSampleRate) {
    mono = resample(mono, wav.sampleRate, targetSampleRate);
  }
  mono = normalize(mono);
  return AudioClip(mono, targetSampleRate, name, mono.length / targetSampleRate);
}

/// 录音得到的 PCM16 小端字节 -> Float64
Float64List pcm16ToFloat(Uint8List bytes) {
  final count = bytes.length ~/ 2;
  final out = Float64List(count);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
