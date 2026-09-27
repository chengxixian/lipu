/// 生成"已知答案"的扒谱测试音频（纯 Dart，不依赖 Flutter 运行时）
///
///   dart run tool/make_chord_fixtures.dart
///
/// 输出到 build/fixtures/：
///   chords_triad.wav / chords_seventh.wav / chords_bass.wav / chords_open.wav
///   + truth.json（每个和弦的真实音高与起止时间）
///
/// 用途：给"哪个扒谱后端更准"提供**可复现的真值**。钢琴采样直接从 assets/piano 读，
/// 所以这个脚本不需要 Flutter 环境（`flutter test` 之外的命令行也能跑）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:jianpu_app/audio/piano_samples.dart';
import 'package:jianpu_app/audio/sampler.dart';
import 'package:jianpu_app/core/model.dart';

/// 从磁盘目录读采样（绕开 rootBundle，命令行/裸 Dart 也能用）
Future<PianoSampleSet> loadSamplesFromDir(String dir) async {
  final manifest = jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final rate = (manifest['sampleRate'] as num).toInt();
  final samples = <PianoSample>[];
  for (final raw in manifest['notes'] as List<dynamic>) {
    final m = raw as Map<String, dynamic>;
    final bytes = File('$dir/${m['file']}').readAsBytesSync();
    final frames = (bytes.length - 44) ~/ 2;
    samples.add(PianoSample(
      midi: (m['midi'] as num).toInt(),
      file: m['file'] as String,
      pcm: _decodePcm16(bytes, frames),
      loopStart: (m['loopStart'] as num).toInt(),
      loopEnd: (m['loopEnd'] as num).toInt(),
      freq: (m['freq'] as num).toDouble(),
      peak: (m['peak'] as num).toDouble(),
    ));
  }
  samples.sort((a, b) => a.midi.compareTo(b.midi));
  return PianoSampleSet(sampleRate: rate, samples: samples);
}

Int16List _decodePcm16(Uint8List bytes, int frames) {
  final out = Int16List(frames);
  for (var i = 0; i < frames; i++) {
    out[i] = (bytes[44 + i * 2 + 1] << 8) | bytes[44 + i * 2];
  }
  return out;
}

Score _scoreOf(List<List<int>> chords, {int ticksPerChord = 1, int tempo = 60}) {
  final meta = ScoreMeta(title: 'chords', keyName: 'C', beats: 4, beatType: 4, tempo: tempo);
  final measures = <Measure>[];
  var m = Measure();
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
    if (m.filled >= 4) {
      measures.add(m);
      m = Measure();
    }
  }
  if (m.items.isNotEmpty) measures.add(m);
  return Score(meta, measures);
}

Future<void> main() async {
  final appDir = Directory.current.path;
  final samples = await loadSamplesFromDir('$appDir/assets/piano');
  final outDir = Directory('$appDir/build/fixtures')..createSync(recursive: true);

  final cases = <String, List<List<int>>>{
    'triad': [
      [60, 64, 67],
      [65, 69, 72],
      [67, 71, 74],
      [60, 64, 67],
    ],
    'seventh': [
      [60, 64, 67, 71],
      [62, 65, 69, 72],
      [67, 71, 74, 77],
      [60, 64, 67, 71],
    ],
    'bass': [
      [48, 60, 64, 67],
      [53, 65, 69, 72],
      [55, 67, 71, 74],
      [48, 60, 64, 67],
    ],
    'open': [
      [48, 55, 64, 72],
      [53, 60, 69, 77],
      [55, 62, 71, 79],
      [48, 55, 64, 72],
    ],
  };

  final truth = <String, dynamic>{};
  for (final entry in cases.entries) {
    final score = _scoreOf(entry.value);
    final path = '${outDir.path}/chords_${entry.key}.wav';
    renderPianoWav(score: score, samples: samples, path: path, reverbMix: 0.2, gain: 0.7);
    final notes = <Map<String, dynamic>>[];
    for (var i = 0; i < entry.value.length; i++) {
      notes.add({'start': i * 1.0, 'dur': 1.0, 'midis': entry.value[i]});
    }
    truth[entry.key] = notes;
    final size = (File(path).lengthSync() / 1024).toStringAsFixed(0);
    stdout.writeln('写出 chords_${entry.key}.wav（$size KB，${entry.value.length} 个和弦，'
        '${entry.value.map((c) => c.length).reduce(math.max)} 声部）');
  }
  File('${outDir.path}/truth.json').writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert({'sampleRate': 44100, 'cases': truth}),
  );
  stdout.writeln('真值写入 build/fixtures/truth.json');
}
