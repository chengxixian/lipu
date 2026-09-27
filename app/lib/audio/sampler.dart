/// 用真实钢琴采样渲染试听音频。
///
/// 与旧的 [synthesizeWav]（纯正弦合成，音色像电子琴）相比：
///   - 每个音取自真实录音，按最近采样变调播放（采样点相差小三度，最多移调 ±1.5 个半音）；
///   - 保留录音本身的起音、共鸣与自然衰减；
///   - 长音用"相位对齐的交叉淡化循环点"延续，不会中途断掉；
///   - 松键有制音包络（不是硬切）；
///   - 按音高做左右声像（低音偏左、高音偏右，和真实钢琴一样），加少量立体声混响；
///   - 末级用软限幅代替硬削顶。
///
/// 输出 44.1kHz 立体声 16bit WAV。**流式写入文件**，内存占用与曲长无关
/// （5 分钟的曲子按 44.1kHz 立体声算有 105MB，不能整块放内存）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/model.dart';
import 'notes.dart';
import 'piano_samples.dart';

/// 试听采样率（采样本身也是 44.1kHz，不用重采样）
const int kPianoSampleRate = 44100;

/// 松键后的制音时间常数（秒）；真实钢琴大约 0.1~0.3 秒
const double _kReleaseTau = 1 / 7;

/// 一次渲染的结果
class PianoRenderResult {
  final int frames;
  final int sampleRate;
  final double peak;
  final bool empty;

  const PianoRenderResult({
    required this.frames,
    required this.sampleRate,
    required this.peak,
    required this.empty,
  });

  double get seconds => frames / sampleRate;
}

/// 把乐谱渲染成钢琴采样 WAV 写到 [path]，返回统计信息。
///
/// [gain] 是整体增益：单个音的峰值大约是采样峰值×gain，
/// 和弦叠加后靠末级软限幅兜住，不会削顶。
PianoRenderResult renderPianoWav({
  required Score score,
  required PianoSampleSet samples,
  required String path,
  int sampleRate = kPianoSampleRate,
  double gain = 0.8,
  double reverbMix = 0.45,
  double maxSeconds = 300,
  void Function(double progress)? onProgress,
}) {
  final notes = collectNotesSeconds(score);
  final tail = 1.4;
  // 乐曲时长以小节为准（全休止的谱子也要放够时长）
  final scoreTicks = score.measures.fold<double>(0, (a, m) => a + math.max(m.filled, m.filled2));
  final playedSeconds = notes.isEmpty ? 0.0 : notes.last.start + notes.last.duration;
  final musicSeconds = math.max(scoreTicks * secondsPerTick(score), playedSeconds);
  final totalSeconds = math.min(musicSeconds + tail, maxSeconds);
  final totalFrames = math.max(1, (totalSeconds * sampleRate).round());

  final file = File(path);
  final raf = file.openSync(mode: FileMode.write);
  final rev = _Reverb(sampleRate);
  final voices = <_Voice>[];
  const block = 4096;
  final dryL = Float32List(block);
  final dryR = Float32List(block);
  final pcm = Int16List(block * 2);
  var peak = 0.0;
  var next = 0;
  // 直流阻断（采样与混响都可能带一点直流）
  var dcL = 0.0;
  var dcR = 0.0;

  try {
    raf.writeFromSync(_wavHeader(0, sampleRate, 2));
    for (var start = 0; start < totalFrames; start += block) {
      final n = math.min(block, totalFrames - start);
      dryL.fillRange(0, n, 0);
      dryR.fillRange(0, n, 0);

      // 这一块里开始的音
      while (next < notes.length && (notes[next].start * sampleRate) < start + n) {
        final note = notes[next++];
        final s = samples.nearest(note.midi);
        final startFrame = (note.start * sampleRate).round();
        final durFrames = math.max(1, (note.duration * sampleRate).round());
        final off = startFrame + durFrames;
        // 音高换算：按半音差变调；再用实测基频把录音本身的"伸张调律"
        // （低音偏低、高音偏高，最多 ±20 音分）校正回等程律，
        // 这样试听能跟别的等程律乐器对得上。
        final tune = s.freq > 0 ? _equalTempFreq(s.midi) / s.freq : 1.0;
        final step = math.pow(2, (note.midi - s.midi) / 12.0) * tune * (samples.sampleRate / sampleRate);
        // 声像：低音偏左、高音偏右，最多 ±0.3（约 ±4dB）
        final pan = ((note.midi - 60) / 40.0).clamp(-1.0, 1.0) * 0.3;
        final theta = (pan + 1) * math.pi / 4;
        voices.add(_Voice(
          sample: s,
          step: step,
          panL: math.cos(theta),
          panR: math.sin(theta),
          startFrame: startFrame,
          offFrame: off,
          stopFrame: off + (_kReleaseTau * 6 * sampleRate).round(),
          releaseStep: math.exp(-1 / (_kReleaseTau * sampleRate)),
        ));
      }

      voices.removeWhere((v) => v.finished);
      for (final v in voices) {
        v.render(dryL, dryR, n, start);
      }

      for (var i = 0; i < n; i++) {
        final send = (dryL[i] + dryR[i]) * 0.5;
        rev.process(send);
        var l = dryL[i] * gain + rev.wetL * reverbMix;
        var r = dryR[i] * gain + rev.wetR * reverbMix;
        // 直流阻断
        dcL += (l - dcL) * 0.0004;
        dcR += (r - dcR) * 0.0004;
        l -= dcL;
        r -= dcR;
        l = _softClip(l);
        r = _softClip(r);
        if (l.abs() > peak) peak = l.abs();
        if (r.abs() > peak) peak = r.abs();
        pcm[i * 2] = (l * 32767).round();
        pcm[i * 2 + 1] = (r * 32767).round();
      }

      final bytes = Uint8List.view(pcm.buffer, 0, n * 4);
      raf.writeFromSync(bytes);
      onProgress?.call((start + n) / totalFrames);
    }
    // 回填真正的长度
    raf.setPositionSync(0);
    raf.writeFromSync(_wavHeader(totalFrames * 4, sampleRate, 2));
  } finally {
    raf.closeSync();
  }
  return PianoRenderResult(
    frames: totalFrames,
    sampleRate: sampleRate,
    peak: peak,
    empty: notes.isEmpty,
  );
}

/// 等程律音高（A4 = 440Hz）
double _equalTempFreq(int midi) => 440.0 * math.pow(2, (midi - 69) / 12.0);

/// 末级软限幅：0.72 以下不动，以上平滑压到 1.0（不是硬削顶，不会"炸"）
double _softClip(double x) {
  const knee = 0.72;
  final a = x.abs();
  if (a <= knee) return x;
  final u = (a - knee) / (1 - knee);
  final v = knee + (1 - knee) * (u / (1 + u));
  return x < 0 ? -v : v;
}

Uint8List _wavHeader(int dataBytes, int rate, int channels) {
  final b = ByteData(44);
  void str(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * channels * 2, Endian.little);
  b.setUint16(32, channels * 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

/// 一个正在发声的音
class _Voice {
  final PianoSample sample;
  final double step;
  final double panL;
  final double panR;
  final int startFrame;
  final int offFrame;
  final int stopFrame;
  final double releaseStep;

  double pos = 0;
  double env = 1;
  bool finished = false;

  _Voice({
    required this.sample,
    required this.step,
    required this.panL,
    required this.panR,
    required this.startFrame,
    required this.offFrame,
    required this.stopFrame,
    required this.releaseStep,
  });

  void render(Float32List l, Float32List r, int n, int blockStart) {
    final pcm = sample.pcm;
    final loopLen = sample.loopLength;
    final loopEnd = sample.loopEnd;
    final last = pcm.length - 1;
    for (var i = 0; i < n; i++) {
      final f = blockStart + i;
      if (f < startFrame) continue;
      if (f >= stopFrame) {
        // 已经衰减到听不见（-52dB）
        finished = true;
        return;
      }
      final idx = pos.toInt();
      final a = pcm[idx].toDouble();
      final b = idx < last ? pcm[idx + 1].toDouble() : a;
      var v = (a + (b - a) * (pos - idx)) * (1 / 32768.0);
      if (f >= offFrame) {
        env *= releaseStep;
        v *= env;
      }
      l[i] += v * panL;
      r[i] += v * panR;
      pos += step;
      if (pos >= loopEnd && loopLen > 1) pos -= loopLen;
    }
  }
}

/// 轻量级 Schroeder 混响（4 梳状 + 2 全通，梳状按左右分开取用形成立体声）
class _Reverb {
  late final List<_Comb> _combs;
  late final List<_Allpass> _ap;
  double wetL = 0;
  double wetR = 0;

  _Reverb(int rate) {
    int n(double ms) => math.max(8, (ms * rate / 1000).round());
    // 延迟时间取互质一些的素数毫秒值，避免金属味
    _combs = [
      _Comb(n(35.3)),
      _Comb(n(36.7)),
      _Comb(n(33.8)),
      _Comb(n(32.2)),
    ];
    _ap = [
      _Allpass(n(12.6), 0.5),
      _Allpass(n(5.1), 0.5),
      _Allpass(n(10.7), 0.5),
      _Allpass(n(7.3), 0.5),
    ];
  }

  void process(double x) {
    // 梳状滤波器带反馈，直流增益约 1/(1-0.8)=5；这个送入系数是听感调出来的
    // （实测：0.16 时混响尾巴大约和钢琴采样自身的余韵一样响，不会糊）
    final s = x * 0.16;
    final c0 = _combs[0].process(s);
    final c1 = _combs[1].process(s);
    final c2 = _combs[2].process(s);
    final c3 = _combs[3].process(s);
    wetL = -_ap[1].process(_ap[0].process((c0 + c2) * 0.5));
    wetR = -_ap[3].process(_ap[2].process((c1 + c3) * 0.5));
  }
}

class _Comb {
  final Float32List buf;
  final double fb;
  final double damp;
  int idx = 0;
  double lp = 0;

  _Comb(int len)
      : buf = Float32List(len),
        fb = 0.80,
        damp = 0.32;

  double process(double x) {
    final y = buf[idx];
    lp += (y - lp) * damp;
    buf[idx] = x + lp * fb;
    if (++idx >= buf.length) idx = 0;
    return y;
  }
}

class _Allpass {
  final Float32List buf;
  final double g;
  int idx = 0;

  _Allpass(int len, this.g) : buf = Float32List(len);

  double process(double x) {
    final y = buf[idx];
    buf[idx] = x + y * g;
    if (++idx >= buf.length) idx = 0;
    // 标准 Schroeder 全通是 y-x（每级都反相，两级串联正好抵消），
    // 所以整体极性在 process() 里统一翻一次，让混响尾巴与直达声同相叠加
    // （实测：不翻时尾巴会和采样自身的余韵互相抵消，加了混响反而更干）
    return y - x;
  }
}
