/// 内置钢琴采样（真实录音，非合成）
///
/// 音源：Salamander Grand Piano V6.2 "Accurate"（Yamaha C5 近场录音）
///       作者 Alexander Holm，许可证 CC-BY-3.0
///       转存：https://huggingface.co/datasets/EinWWW/Accurate-Salamander-Grand-Piano-Yamaha-C5
/// 转换脚本：tool/fetch_piano_samples.mjs
///   —— 48kHz/24bit/立体声 -> 44.1kHz/16bit/单声道 + 相位对齐的交叉淡化循环点
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// 一个采样音（单声道 16bit，采样率见 [PianoSampleSet.sampleRate]）
class PianoSample {
  /// 这个采样本身录的音高（MIDI 音高号）
  final int midi;
  final String file;
  final Int16List pcm;

  /// 循环区（样本下标）：弹到 [loopEnd] 就跳回 [loopStart]
  final int loopStart;
  final int loopEnd;

  /// 实测基频（Hz），用于循环点对齐等，不参与音高换算
  final double freq;

  /// 该采样的峰值（0~1）
  final double peak;

  const PianoSample({
    required this.midi,
    required this.file,
    required this.pcm,
    required this.loopStart,
    required this.loopEnd,
    required this.freq,
    required this.peak,
  });

  int get frames => pcm.length;

  /// 循环段长度（采样点）
  int get loopLength => loopEnd - loopStart;
}

/// 整套钢琴采样
class PianoSampleSet {
  final int sampleRate;

  /// 按音高升序
  final List<PianoSample> samples;

  /// 音源信息（用于界面上标注出处）
  final String license;
  final String attribution;
  final String sourceUrl;

  const PianoSampleSet({
    required this.sampleRate,
    required this.samples,
    this.license = '',
    this.attribution = '',
    this.sourceUrl = '',
  });

  bool get isEmpty => samples.isEmpty;

  static const String assetDir = 'assets/piano';

  /// 从资源里读入整套采样（约 7MB，读一次后缓存）
  static Future<PianoSampleSet> load({AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    final manifest = jsonDecode(await b.loadString('$assetDir/manifest.json')) as Map<String, dynamic>;
    final rate = (manifest['sampleRate'] as num?)?.toInt() ?? 44100;
    final list = <PianoSample>[];
    for (final raw in (manifest['notes'] as List<dynamic>)) {
      final m = raw as Map<String, dynamic>;
      final file = m['file'] as String;
      final data = await b.load('$assetDir/$file');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      if (bytes.length < 44) throw StateError('采样文件损坏：$file');
      final frames = ((bytes.length - 44) ~/ 2);
      final declared = (m['frames'] as num?)?.toInt();
      if (declared != null && declared != frames) {
        throw StateError('采样长度与清单不符：$file 清单=$declared 实际=$frames');
      }
      list.add(PianoSample(
        midi: (m['midi'] as num).toInt(),
        file: file,
        pcm: _decodePcm16(bytes, frames),
        loopStart: (m['loopStart'] as num).toInt(),
        loopEnd: (m['loopEnd'] as num).toInt(),
        freq: (m['freq'] as num?)?.toDouble() ?? 0,
        peak: (m['peak'] as num?)?.toDouble() ?? 0,
      ));
    }
    list.sort((a, b) => a.midi.compareTo(b.midi));
    return PianoSampleSet(
      sampleRate: rate,
      samples: list,
      license: (manifest['license'] as String?) ?? '',
      attribution: (manifest['attribution'] as String?) ?? '',
      sourceUrl: (manifest['sourceUrl'] as String?) ?? '',
    );
  }

  /// WAV 的 data 段（跳过 44 字节头）转成 16bit 定点
  static Int16List _decodePcm16(Uint8List bytes, int frames) {
    const offset = 44;
    if ((bytes.offsetInBytes + offset) % 2 == 0) {
      // 大多数情况可以直接映射，不用拷贝
      try {
        return Int16List.view(bytes.buffer, bytes.offsetInBytes + offset, frames);
      } catch (_) {
        // 落到下面的逐字节解码
      }
    }
    final out = Int16List(frames);
    for (var i = 0; i < frames; i++) {
      final lo = bytes[offset + i * 2];
      final hi = bytes[offset + i * 2 + 1];
      out[i] = (hi << 8) | lo;
    }
    return out;
  }

  /// 取最接近 [midi] 的采样（采样点之间相差小三度，最多移调 ±1.5 个半音）
  PianoSample nearest(int midi) {
    if (samples.isEmpty) throw StateError('没有可用的钢琴采样');
    var lo = 0;
    var hi = samples.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].midi < midi) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0 && (samples[lo].midi - midi).abs() > (midi - samples[lo - 1].midi).abs()) {
      return samples[lo - 1];
    }
    return samples[lo];
  }
}
