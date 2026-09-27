/// CRNN 在**真实钢琴录音**上的交叉验证（用户反馈"扒钢琴谱音完全不对"）。
///
///   flutter test integration_test/crnn_real_audio_probe_test.dart -d windows
///
/// 做法：跑完 CRNN 后，在若干时间窗里把「模型检出的音高」与「该窗口音频频谱的峰值音高」
/// 对照 —— 频谱是独立于模型的物理量，两边一致才说明链路没有系统性错误
/// （采样率、键位映射、帧率、张量取错这些错误都会在这里暴露）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';
import 'package:jianpu_app/transcribe/crnn_engine.dart';

const String _defaultModel = 'D:/dsh work region/jianpu2staff/third_party/piano_crnn/piano_crnn.onnx';
const String _wav = 'assets/samples/merry_christmas.wav';

String _n(int midi) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return '${names[((midi % 12) + 12) % 12]}${midi ~/ 12 - 1}';
}

/// 频谱峰值 → 最近的 MIDI（用自相关不准，这里用 FFT 峰值 + 谐波校正）
List<int> spectralPeaks(Float64List x, int sr, {int top = 5}) {
  const n = 16384;
  if (x.length < n) return const [];
  final re = Float64List(n), im = Float64List(n);
  for (var i = 0; i < n; i++) {
    re[i] = x[i] * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)));
  }
  _fft(re, im);
  final peaks = <(double, double)>[];
  for (var k = 2; k < n ~/ 2; k++) {
    final mag = math.sqrt(re[k] * re[k] + im[k] * im[k]);
    final prev = math.sqrt(re[k - 1] * re[k - 1] + im[k - 1] * im[k - 1]);
    final next = math.sqrt(re[k + 1] * re[k + 1] + im[k + 1] * im[k + 1]);
    if (mag > prev && mag >= next) peaks.add((k * sr / n, mag));
  }
  peaks.sort((a, b) => b.$2.compareTo(a.$2));
  final out = <int>[];
  for (final p in peaks) {
    if (p.$1 < 60 || p.$1 > 4000) continue;
    final midi = (69 + 12 * (math.log(p.$1 / 440) / math.ln2)).round();
    if (!out.contains(midi)) out.add(midi);
    if (out.length >= top) break;
  }
  return out;
}

void _fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len >> 1; k++) {
        final ur = re[i + k], ui = im[i + k];
        final vr = re[i + k + (len >> 1)] * cr - im[i + k + (len >> 1)] * ci;
        final vi = re[i + k + (len >> 1)] * ci + im[i + k + (len >> 1)] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + (len >> 1)] = ur - vr;
        im[i + k + (len >> 1)] = ui - vi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CRNN 真实钢琴：检出音高 vs 频谱峰值', (tester) async {
    final model = File(_defaultModel);
    if (!model.existsSync()) {
      markTestSkipped('缺少 CRNN 模型');
      return;
    }
    final clip = await loadAudioFile(_wav, targetSampleRate: CrnnConst.sampleRate);
    final engine = PianoCrnnEngine();
    expect(await engine.ensureLoaded(model.path), isTrue, reason: '${engine.error}');
    addTearDown(engine.dispose);

    final sw = Stopwatch()..start();
    final notes = await engine.transcribe(clip.samples);
    sw.stop();
    // ignore: avoid_print
    print('真实钢琴 ${clip.durationSec.toStringAsFixed(1)}s → 检出 ${notes.length} 个音'
        '（${(notes.length / clip.durationSec).toStringAsFixed(1)} 音/秒，'
        '用时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s）');
    if (notes.isNotEmpty) {
      final lo = notes.map((n) => n.midi.round()).reduce(math.min);
      final hi = notes.map((n) => n.midi.round()).reduce(math.max);
      // ignore: avoid_print
      print('音域 ${_n(lo)} ~ ${_n(hi)}');
    }

    // 抽样对照：每 12 秒取一个窗口
    for (var t = 0.0; t < clip.durationSec - 1; t += 12.0) {
      final from = (t * clip.sampleRate).round();
      final win = Float64List.sublistView(
          clip.samples, from, math.min(clip.samples.length, from + clip.sampleRate * 2));
      final peaks = spectralPeaks(win, clip.sampleRate);
      final detected = notes
          .where((n) => n.startSec >= t && n.startSec < t + 2)
          .map((n) => n.midi.round())
          .toSet()
          .toList()
        ..sort();
      // ignore: avoid_print
      print('  ${t.toStringAsFixed(0)}s  模型: ${detected.map(_n).join(" ")}'
          '   |   频谱峰值: ${peaks.map(_n).join(" ")}');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
