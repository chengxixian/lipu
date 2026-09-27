/// 和弦识别准确率测量（真桌面端跑，需要 ONNX Runtime 原生库）
///
///   flutter test integration_test/chord_accuracy_test.dart -d windows
///
/// 做法：用**内置钢琴采样**渲染已知的和弦进行（真值完全可控），再喂给 Basic Pitch，
/// 逐个和弦算 recall（该响的音检出几个）/ precision（检出的音里有几个是真的），
/// 并列出漏掉/多出的音 —— 用来定位"和弦不准"到底不准在哪。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/audio/piano_samples.dart';
import 'package:jianpu_app/audio/sampler.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';
import 'package:jianpu_app/transcribe/basic_pitch.dart';
import 'package:jianpu_app/transcribe/basic_pitch_engine.dart';


/// 一个和弦的真值
class _Truth {
  final List<int> midis;
  final double startSec;
  final double durSec;
  const _Truth(this.midis, this.startSec, this.durSec);
}

/// 用钢琴采样渲染一批和弦（每个和弦 1 拍，速度 60 → 每拍 1 秒）
Future<({Float64List samples, int rate, List<_Truth> truth})> renderChords(
  List<List<int>> chords, {
  int ticksPerChord = 1,
  int tempo = 60,
}) async {
  final set = await PianoSampleSet.load();
  final meta = ScoreMeta(title: 'chords', keyName: 'C', beats: 4, beatType: 4, tempo: tempo);
  final measures = <Measure>[];
  final truth = <_Truth>[];
  var m = Measure();
  var secPerTick = 60.0 / tempo;
  var t = 0.0;
  for (final chord in chords) {
    final sorted = [...chord]..sort();
    NoteItem noteOf(int midi) {
      const offsets = [0, 2, 4, 5, 7, 9, 11];
      for (var d = 0; d < 7; d++) {
        final rel = midi - 60 - offsets[d];
        if (rel % 12 == 0) return NoteItem(degree: d + 1, octave: rel ~/ 12, ticks: ticksPerChord.toDouble());
      }
      throw ArgumentError('只支持自然音级：$midi');
    }

    final item = noteOf(sorted.first);
    for (final midi in sorted.skip(1)) {
      final n = noteOf(midi);
      item.chord.add(ChordTone(degree: n.degree, octave: n.octave, accidental: n.accidental));
    }
    m.items.add(item);
    truth.add(_Truth(sorted, t, ticksPerChord * secPerTick));
    t += ticksPerChord * secPerTick;
    if (m.filled >= 4) {
      measures.add(m);
      m = Measure();
    }
  }
  if (m.items.isNotEmpty) measures.add(m);

  final dir = Directory.systemTemp.createTempSync('chord_probe');
  final path = '${dir.path}/chords.wav';
  renderPianoWav(score: Score(meta, measures), samples: set, path: path, reverbMix: 0.2, gain: 0.7);
  // **必须走 App 自己的加载路径**：它会重采样到模型要的 22050Hz。
  // （第一版测量忘了这步，直接把 44.1kHz 喂给模型 → 整体低一个八度、时间轴也差一倍，
  //   差点误判成"模型移植有 bug"。）
  final clip = await loadAudioFile(path);
  dir.deleteSync(recursive: true);
  return (samples: clip.samples, rate: clip.sampleRate, truth: truth);
}

String nameOf(int midi) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return '${names[midi % 12]}${midi ~/ 12 - 1}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> measure(String tag, List<List<int>> chords,
      {BasicPitchParams params = const BasicPitchParams(), bool clean = false, bool verbose = false}) async {
    final r = await renderChords(chords);
    final engine = BasicPitchEngine();
    expect(await engine.ensureLoaded(), isTrue, reason: 'ONNX 模型应当能加载：${engine.error}');
    final raw = await engine.transcribe(r.samples, params: params);
    await engine.dispose();
    final times = modelFramesToTime(raw.isEmpty ? 0 : raw.map((n) => n.endFrame).reduce(math.max) + 1);
    double timeAt(int f) => f < times.length ? times[f] : f * BpConst.fftHop / BpConst.sampleRate;

    var detected = <({int midi, double start, double end, double amp})>[
      for (final n in raw) (midi: n.midi, start: timeAt(n.startFrame), end: timeAt(n.endFrame), amp: n.amplitude),
    ];
    // clean = 走 App 的后处理（复调模式：去泛音鬼影）
    if (clean) {
      final analysis = analysisFromBasicPitch(raw,
          sampleRate: r.rate, durationSec: r.samples.length / r.rate, melodyOnly: false, samples: r.samples);
      detected = [
        for (final n in analysis.activeNotes)
          (midi: n.midi.round(), start: n.startSec, end: n.endSec, amp: n.confidence),
      ];
    }

    var tpTotal = 0, detTotal = 0, truthTotal = 0;
    final lines = <String>[];
    for (final t in r.truth) {
      // 这个和弦的时间窗内检出的音（允许 ±0.25 拍的时间误差）
      final win = detected.where((n) =>
          n.midi >= 21 && n.midi <= 108 && n.start >= t.startSec - 0.25 && n.start <= t.startSec + t.durSec * 0.6);
      final found = win.map((n) => n.midi).toSet();
      final truth = t.midis.toSet();
      final hit = found.intersection(truth);
      final miss = truth.difference(found);
      final extra = found.difference(truth);
      tpTotal += hit.length;
      detTotal += found.length;
      truthTotal += truth.length;
      lines.add('  ${t.startSec.toStringAsFixed(1)}s [${truth.map(nameOf).join(" ")}] '
          '检出 ${found.length} 个：${found.map(nameOf).join(" ")}'
          '${miss.isEmpty ? "" : "  漏:${miss.map(nameOf).join(",")}"}'
          '${extra.isEmpty ? "" : "  多:${extra.map(nameOf).join(",")}"}');
      if (verbose) {
        // 每个音的「响度 / 时长」，用来分辨"真叠置"与"泛音鬼影"
        final detail = win
            .map((n) =>
                '${nameOf(n.midi)}(${n.amp.toStringAsFixed(2)},${(n.end - n.start).toStringAsFixed(2)}s)')
            .join(' ');
        lines.add('       $detail');
      }
    }
    final recall = truthTotal == 0 ? 0.0 : tpTotal / truthTotal;
    final precision = detTotal == 0 ? 0.0 : tpTotal / detTotal;
    // ignore: avoid_print
    print('=== $tag：recall=${(recall * 100).toStringAsFixed(0)}% '
        'precision=${(precision * 100).toStringAsFixed(0)}% '
        '（真值 $truthTotal 音，检出 $detTotal 音，命中 $tpTotal）');
    for (final l in lines) {
      // ignore: avoid_print
      print(l);
    }
  }

  testWidgets('和弦准确率基线', (tester) async {
    // 1) 中音区三和弦（钢琴右手常见）
    await measure('三和弦（C F G C）', [
      [60, 64, 67],
      [65, 69, 72],
      [67, 71, 74],
      [60, 64, 67],
    ], clean: true, verbose: true);
    // 2) 七和弦（更密）
    await measure('七和弦（Cmaj7 Dm7 G7 Cmaj7）', [
      [60, 64, 67, 71],
      [62, 65, 69, 72],
      [67, 71, 74, 77],
      [60, 64, 67, 71],
    ], clean: true, verbose: true);
    // 3) 低音 + 右手和弦（钢琴典型织体）
    await measure('低音+和弦', [
      [48, 60, 64, 67],
      [53, 65, 69, 72],
      [55, 67, 71, 74],
      [48, 60, 64, 67],
    ], clean: true, verbose: true);
    // 4) 开放排列（跨八度）
    await measure('开放排列', [
      [48, 55, 64, 72],
      [53, 60, 69, 77],
    ], clean: true, verbose: true);
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('诊断：音频本身的音高 vs 模型报的音高', (tester) async {
    final r = await renderChords([
      [60, 64, 67],
      [65, 69, 72],
    ]);
    // 1) 直接量第 1 个和弦（0.2~0.9 秒）的频谱峰
    final sr = r.rate;
    const n = 16384;
    final from = (0.2 * sr).round();
    final re = Float64List(n), im = Float64List(n);
    for (var i = 0; i < n; i++) {
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
      re[i] = (from + i < r.samples.length ? r.samples[from + i] : 0) * w;
    }
    _fft(re, im);
    final peaks = <(double, double)>[];
    for (var i = 2; i < n ~/ 2; i++) {
      final mag = math.sqrt(re[i] * re[i] + im[i] * im[i]);
      if (mag > math.sqrt(re[i - 1] * re[i - 1] + im[i - 1] * im[i - 1]) &&
          mag >= math.sqrt(re[i + 1] * re[i + 1] + im[i + 1] * im[i + 1])) {
        peaks.add((i * sr / n, mag));
      }
    }
    peaks.sort((a, b) => b.$2.compareTo(a.$2));
    // ignore: avoid_print
    print('音频频谱前 8 个峰：${peaks.take(8).map((p) => "${p.$1.toStringAsFixed(0)}Hz").join(" ")}');
    // ignore: avoid_print
    print('（C4=262 E4=330 G4=392 F4=349 A4=440 C5=523）');

    // 2) 模型报的原音符（用引擎自己的时间换算）
    final engine = BasicPitchEngine();
    expect(await engine.ensureLoaded(), isTrue, reason: '${engine.error}');
    final notes = await engine.transcribe(r.samples);
    await engine.dispose();
    // ignore: avoid_print
    print('模型共报 ${notes.length} 个音符：');
    final times = modelFramesToTime(notes.isEmpty ? 0 : notes.map((n) => n.endFrame).reduce(math.max) + 1);
    double timeAt(int f) => f < times.length ? times[f] : f * BpConst.fftHop / BpConst.sampleRate;
    for (final note in notes.take(24)) {
      // ignore: avoid_print
      print('   ${nameOf(note.midi)} midi=${note.midi} '
          't=${timeAt(note.startFrame).toStringAsFixed(2)}~${timeAt(note.endFrame).toStringAsFixed(2)}s '
          'amp=${note.amplitude.toStringAsFixed(2)}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// 就地 FFT（radix-2）
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
      for (var k = 0; k < len ~/ 2; k++) {
        final ur = re[i + k], ui = im[i + k];
        final vr = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
        final vi = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len ~/ 2] = ur - vr;
        im[i + k + len ~/ 2] = ui - vi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}
