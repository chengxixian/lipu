/// 麦克风录音（哼唱记谱）：PCM16 流 + 实时音高显示
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

import 'audio_source.dart';
import 'dsp.dart';
import 'melody.dart';

class MicRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  /// 是否有录音权限（会自动申请）
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  Future<bool> isRecording() async {
    try {
      return await _recorder.isRecording();
    } catch (_) {
      return false;
    }
  }

  /// 开始录音，返回 PCM16 单声道字节流
  Future<Stream<Uint8List>> start({int sampleRate = kAnalysisRate}) async {
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: false,
        noiseSuppress: false,
      ),
    );
    return stream;
  }

  Future<void> stop() async {
    try {
      await _recorder.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _recorder.dispose();
    } catch (_) {}
  }
}

/// 边录边算：累积 PCM，同时给出实时音高点（用于界面上的音高条）
class LivePitchTracker {
  final int sampleRate;
  final TranscribeOptions options;

  final List<double> _samples = <double>[];
  final List<PitchPoint> points = <PitchPoint>[];
  final List<double> _pending = <double>[];

  late final int _frameSize;
  late final YinDetector _yin;
  int _hopRemainder = 0;

  LivePitchTracker({this.sampleRate = kAnalysisRate, this.options = const TranscribeOptions()}) {
    _frameSize = _nextPow2((sampleRate * 0.046).round()).clamp(512, 4096);
    _yin = YinDetector(
      sampleRate: sampleRate,
      frameSize: _frameSize,
      threshold: 0.12 + 0.16 * options.sensitivity,
      minHz: options.minHz,
      maxHz: options.maxHz,
    );
  }

  static int _nextPow2(int n) {
    var p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p;
  }

  int get sampleCount => _samples.length;
  double get durationSec => _samples.length / sampleRate;

  /// 已录到的完整 PCM（停止后交给 analyzeMelody）
  Float64List get pcm {
    final out = Float64List(_samples.length);
    for (var i = 0; i < _samples.length; i++) {
      out[i] = _samples[i];
    }
    return out;
  }

  /// 最近的响度（0..1），用于电平条
  double get level {
    if (points.isEmpty) return 0;
    return points.last.level;
  }

  /// 送入一块 PCM16 字节；返回这一次新产生的音高点
  List<PitchPoint> push(Uint8List bytes) {
    final chunk = pcm16ToFloat(bytes);
    _samples.addAll(chunk);
    _pending.addAll(chunk);
    final produced = <PitchPoint>[];
    final hop = math.max(1, (options.hopSec * sampleRate).round());

    while (_pending.length >= _frameSize + _hopRemainder) {
      final frame = Float64List(_frameSize);
      for (var i = 0; i < _frameSize; i++) {
        frame[i] = _pending[i];
      }
      final level = rms(frame);
      final p = _yin.detect(frame);
      final t = (_samples.length - _pending.length + _frameSize) / sampleRate;
      final point = PitchPoint(
        t,
        (p.voiced && level > 0.008) ? hzToMidi(p.hz) : 0,
        p.confidence,
        level,
      );
      points.add(point);
      produced.add(point);
      _pending.removeRange(0, hop);
      _hopRemainder = 0;
    }
    return produced;
  }
}
