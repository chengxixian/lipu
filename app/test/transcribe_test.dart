/// 扒谱/哼唱链路测试：WAV 编解码、基频检测、切分、量化，以及
/// 「简谱 -> 合成音频 -> 扒谱 -> 简谱」的往返一致性
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/audio/synth.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';
import 'package:jianpu_app/transcribe/melody.dart';
import 'package:jianpu_app/transcribe/quantize.dart';
import 'package:jianpu_app/transcribe/recorder.dart';
import 'package:jianpu_app/transcribe/wav.dart';

/// 把简谱文本渲染成分析用的单声道 PCM（走真实的合成器 + WAV 解码 + 重采样）
Float64List renderJianpu(String text, {int targetRate = kAnalysisRate}) {
  final score = parseJianpu(text);
  final wavBytes = synthesizeWav(score, sampleRate: 44100);
  final wav = decodeWav(wavBytes);
  var mono = toMono(wav);
  mono = resample(mono, wav.sampleRate, targetRate);
  return normalize(mono);
}

Float64List sine(double hz, double seconds, int rate, {double amp = 0.5, double noise = 0.0, int harmonics = 1}) {
  final n = (seconds * rate).round();
  final out = Float64List(n);
  final rnd = math.Random(7);
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    var v = 0.0;
    for (var h = 1; h <= harmonics; h++) {
      v += math.sin(2 * math.pi * hz * h * t) / h;
    }
    out[i] = v * amp / (harmonics > 1 ? 1.6 : 1.0) + (noise == 0 ? 0 : (rnd.nextDouble() * 2 - 1) * noise);
  }
  return out;
}

/// 从量化结果里取出音级序列
String degreesOf(String jianpu) {
  final score = parseJianpu(jianpu);
  final sb = StringBuffer();
  for (final m in score.measures) {
    for (final it in m.items) {
      if (it is NoteItem) sb.write(it.degree);
    }
  }
  return sb.toString();
}

void main() {
  group('WAV 编解码', () {
    test('16bit 单声道往返', () {
      final samples = sine(440, 0.2, 16000, amp: 0.8);
      final bytes = encodeWav16(samples, 16000);
      final decoded = decodeWav(bytes);
      expect(decoded.sampleRate, 16000);
      expect(decoded.channels, 1);
      expect(decoded.samples.length, samples.length);
      for (var i = 0; i < 100; i++) {
        expect((decoded.samples[i] - samples[i]).abs(), lessThan(0.001));
      }
    });

    test('立体声 -> 单声道', () {
      final left = sine(300, 0.1, 8000, amp: 0.5);
      final frames = left.length;
      final interleaved = Float64List(frames * 2);
      for (var i = 0; i < frames; i++) {
        interleaved[i * 2] = left[i];
        interleaved[i * 2 + 1] = -left[i];
      }
      final mono = toMono(WavData(8000, 2, interleaved));
      expect(mono.length, frames);
      for (var i = 0; i < frames; i += 97) {
        expect(mono[i].abs(), lessThan(1e-9)); // 左右完全反相 -> 抵消
      }
    });

    test('重采样保持音高', () {
      final src = sine(440, 0.3, 44100, amp: 0.7);
      final dst = resample(src, 44100, 22050);
      expect((dst.length - src.length / 2).abs(), lessThan(3));
      // 过零率应保持 440Hz 的量级
      var crossings = 0;
      for (var i = 1; i < dst.length; i++) {
        if ((dst[i - 1] < 0) != (dst[i] < 0)) crossings++;
      }
      final hz = crossings / 2 / (dst.length / 22050);
      expect(hz, closeTo(440, 8));
    });
  });

  group('主旋律提取', () {
    test('单声部音阶：音高与数量', () {
      // 1 2 3 4 5，C 大调四分音符，♩=96（每音 0.625s）
      final pcm = renderJianpu('1=C 4/4 ♩=96\n1 2 3 4 5 - - - |]');
      final a = analyzeMelody(pcm, sampleRate: kAnalysisRate, options: const TranscribeOptions());
      final midis = a.activeNotes.map((n) => n.midiRound).toList();
      // ignore: avoid_print
      print('单声部音阶识别: $midis  (期望 60 62 64 65 67)');
      expect(midis.length, greaterThanOrEqualTo(5));
      expect(midis.take(5).toList(), [60, 62, 64, 65, 67]);
      for (final n in a.activeNotes.take(5)) {
        expect(n.cents.abs(), lessThan(35), reason: '音分偏差过大: ${n.midi}');
      }
    });

    test('带噪声仍能识别（模拟哼唱）', () {
      final base = renderJianpu('1=C 4/4 ♩=100\n1 3 5 3 1 - - - |]');
      final noisy = Float64List(base.length);
      final rnd = math.Random(3);
      for (var i = 0; i < base.length; i++) {
        noisy[i] = base[i] * 0.9 + (rnd.nextDouble() * 2 - 1) * 0.02;
      }
      final a = analyzeMelody(normalize(noisy), sampleRate: kAnalysisRate, options: const TranscribeOptions());
      final midis = a.activeNotes.map((n) => n.midiRound).toList();
      // ignore: avoid_print
      print('带噪声识别: $midis  (期望 60 64 67 64 60)');
      expect(midis.take(5).toList(), [60, 64, 67, 64, 60]);
    });

    test('混音模式：旋律 + 更强的低音伴奏时抓旋律而不是贝斯', () {
      // 旋律：C4 起的音阶；伴奏：C3 持续低音（基频能量比旋律还强）
      final melody = renderJianpu("1=C 4/4 ♩=96\n1 2 3 4 5 6 7 1' 1' 7 6 5 4 3 2 |]");
      final bass = sine(130.81, melody.length / kAnalysisRate, kAnalysisRate, amp: 1.0, harmonics: 3);
      final mix = Float64List(melody.length);
      for (var i = 0; i < melody.length; i++) {
        mix[i] = melody[i] * 0.55 + (i < bass.length ? bass[i] * 1.0 : 0);
      }
      final a = analyzeMelody(normalize(mix), sampleRate: kAnalysisRate, options: const TranscribeOptions(mixMode: true));
      final midis = a.activeNotes.map((n) => n.midiRound).toList();
      // ignore: avoid_print
      print('混音主旋律提取: $midis  (期望接近 60 62 64 65 67 69 71 72，而不是低音 48)');
      expect(midis, isNotEmpty);
      final inMelodyRange = midis.where((m) => m >= 58 && m <= 74).length;
      expect(inMelodyRange / midis.length, greaterThan(0.6),
          reason: '大部分音应该落在旋律音区: $midis');
    });

    test('速度估计接近真值', () {
      final pcm = renderJianpu('1=C 4/4 ♩=96\n1 1 5 5 6 6 5 - 4 4 3 3 2 2 1 - |]');
      final a = analyzeMelody(pcm, sampleRate: kAnalysisRate, options: const TranscribeOptions());
      // ignore: avoid_print
      print('速度估计: ${a.bpm.toStringAsFixed(1)} BPM (真值 96)');
      expect(a.bpm, greaterThan(0));
      // 允许把八分音符当拍的折算误差（96 或 192/2=96、48*2=96 这类等价）
      expect((a.bpm - 96).abs() / 96, lessThan(0.2), reason: 'bpm=${a.bpm}');
    });

    test('调号估计', () {
      final pcm = renderJianpu('1=C 4/4 ♩=96\n1 2 3 4 5 6 7 1\' 1\' 7 6 5 4 3 2 1 - |]');
      final a = analyzeMelody(pcm, sampleRate: kAnalysisRate, options: const TranscribeOptions());
      // ignore: avoid_print
      print('调号估计: ${a.keyName} ${a.mode}');
      expect(a.keyName, 'C');
      expect(a.mode, 'major');
    });
  });

  group('量化与小节', () {
    test('量化后小节容量正确且音数一致', () {
      final pcm = renderJianpu('1=C 4/4 ♩=96\n1 2 3 4 5 - 6 - | 5 4 3 2 1 - - - |]');
      final a = analyzeMelody(pcm, sampleRate: kAnalysisRate, options: const TranscribeOptions());
      final q = quantizeToScore(a, options: QuantizeOptions(bpm: 96, keyName: 'C'));
      final cap = measureTicksOf(4, 4);
      for (final m in q.score.measures) {
        expect(m.filled, greaterThan(0));
        expect(m.filled, lessThanOrEqualTo(cap + 1e-6), reason: '小节超容量: ${m.filled}');
      }
      final notation = degreesOf(q.jianpu);
      // ignore: avoid_print
      print('量化音级: $notation');
      expect(notation.length, greaterThanOrEqualTo(8));
      expect(q.score.noteCount, a.activeNotes.length);
    });

    test('小调往返仍是小调', () {
      final score = parseJianpu("6=A 3/4 ♩=90\n6, 7, 1 2 3 4 | 5 4 3 2 1 7, | 6, - - |]");
      expect(score.key.mode, 'minor');
      final text = toJianpu(score);
      // ignore: avoid_print
      print('小调回写: ${text.split('\n').first}');
      final again = parseJianpu(text);
      expect(again.key.mode, 'minor');
      expect(again.key.tonicPc, score.key.tonicPc);
    });
  });

  group('端到端往返', () {
    test('小星星：简谱 -> 音频 -> 扒谱 -> 简谱', () {
      const src = '1=C 4/4 ♩=96\n1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]';
      final pcm = renderJianpu(src);
      final a = analyzeMelody(pcm, sampleRate: kAnalysisRate, options: const TranscribeOptions());
      final q = quantizeToScore(a, options: const QuantizeOptions(bpm: 96, keyName: 'C'));
      final expected = degreesOf(src);
      final actual = degreesOf(q.jianpu);
      // ignore: avoid_print
      print('原谱: $expected');
      // ignore: avoid_print
      print('扒谱: $actual');
      // 允许极少量切分误差，但要求序列高度一致
      final matchCount = _lcsLength(expected, actual);
      final ratio = matchCount / expected.length;
      // ignore: avoid_print
      print('匹配率: ${(ratio * 100).toStringAsFixed(1)}% ($matchCount/${expected.length})');
      expect(ratio, greaterThan(0.85), reason: '往返匹配率过低: $actual');
    });
  });
  group('哼唱：实时音高跟踪（模拟麦克风 PCM16 分块输入）', () {
    /// 把一段 float 采样编码成 PCM16 小端字节（与录音插件输出的格式一致）
    Uint8List toPcm16(Float64List samples) {
      final out = Uint8List(samples.length * 2);
      final bd = ByteData.sublistView(out);
      for (var i = 0; i < samples.length; i++) {
        bd.setInt16(i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
      }
      return out;
    }

    test('pcm16ToFloat 基本正确性与边界', () {
      final bytes = toPcm16(Float64List.fromList([0.0, 0.5, -0.5, 1.0]));
      final f = pcm16ToFloat(bytes);
      expect(f.length, 4);
      expect(f[0], closeTo(0, 1e-4));
      expect(f[1], closeTo(0.5, 1e-3));
      expect(f[2], closeTo(-0.5, 1e-3));
      expect(f[3], closeTo(1.0, 1e-3));
      expect(pcm16ToFloat(Uint8List(0)), isEmpty);
    });

    test('持续哼唱 A4：实时音高稳定，整段分析与量化得到该音', () {
      final samples = sine(440, 1.2, kAnalysisRate, amp: 0.6, harmonics: 3);
      final bytes = toPcm16(samples);
      final tracker = LivePitchTracker();

      // 按 2048 字节一块喂入，模拟录音插件的回调
      final points = <PitchPoint>[];
      const chunk = 2048;
      for (var off = 0; off < bytes.length; off += chunk) {
        final end = math.min(off + chunk, bytes.length);
        points.addAll(tracker.push(Uint8List.sublistView(bytes, off, end)));
      }

      final voiced = points.where((p) => p.voiced).toList();
      // ignore: avoid_print
      print('哼唱跟踪：共 ${points.length} 帧，有声 ${voiced.length} 帧');
      expect(points.length, greaterThan(40), reason: '1.2 秒应有上百帧');
      expect(voiced.length, greaterThan(points.length * 0.6), reason: '持续音应大部分帧都判为有声');
      for (final p in voiced.skip(5)) {
        expect(p.midi, closeTo(69, 0.5), reason: 'A4 应稳定在 midi 69 附近');
      }
      expect(tracker.durationSec, closeTo(1.2, 0.05));
      expect(tracker.pcm.length, closeTo(samples.length, 4), reason: '录到的 PCM 不应丢样');
      expect(tracker.level, greaterThan(0));

      // 停止录音后走与文件相同的分析链路
      final a = analyzeMelody(tracker.pcm, sampleRate: kAnalysisRate);
      expect(a.activeNotes, isNotEmpty, reason: '应至少切出一个音');
      expect(a.activeNotes.first.midiRound, 69);
      // ignore: avoid_print
      print('哼唱分析：${a.activeNotes.map((n) => describePitch(n.midi)).toList()}');
    });

    test('哼唱三音小旋律：能切出对应的音', () {
      // do - mi - sol（C4 E4 G4），每音 0.6 秒，中间留 0.1 秒换气
      final buffer = <double>[];
      for (final hz in [261.63, 329.63, 392.00]) {
        buffer.addAll(sine(hz, 0.6, kAnalysisRate, amp: 0.6, harmonics: 2));
        buffer.addAll(List<double>.filled((0.1 * kAnalysisRate).round(), 0.0));
      }
      final samples = Float64List.fromList(buffer);
      final tracker = LivePitchTracker();
      final bytes = toPcm16(samples);
      for (var off = 0; off < bytes.length; off += 4096) {
        tracker.push(Uint8List.sublistView(bytes, off, math.min(off + 4096, bytes.length)));
      }

      final analysis = analyzeMelody(tracker.pcm, sampleRate: kAnalysisRate);
      final midis = analysis.activeNotes.map((n) => n.midiRound).toList();
      // ignore: avoid_print
      print('哼唱小旋律: $midis  (期望 60 64 67)');
      expect(midis.length, greaterThanOrEqualTo(3));
      expect(midis.take(3).toList(), [60, 64, 67]);

      // 量化后应能生成简谱（复用现有管线）
      final q = quantizeToScore(analysis, options: const QuantizeOptions(keyName: 'C', bpm: 100));
      expect(q.jianpu.trim(), isNotEmpty);
      expect(degreesOf(q.jianpu).startsWith('135'), isTrue, reason: 'C 大调下应为 1 3 5，实际 ${q.jianpu}');
    });
  });
}

/// 最长公共子序列长度：用于容忍少量漏音/多音
int _lcsLength(String a, String b) {
  final dp = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    var prev = 0;
    for (var j = 1; j <= b.length; j++) {
      final tmp = dp[j];
      dp[j] = a[i - 1] == b[j - 1] ? prev + 1 : math.max(dp[j], dp[j - 1]);
      prev = tmp;
    }
  }
  return dp[b.length];
}
