import 'dart:io';

import '../lib/core/model.dart';
import '../lib/core/parse.dart';
import '../lib/transcribe/melody.dart';
import '../lib/transcribe/quantize.dart';
import '../lib/transcribe/wav.dart';

/// 扒谱调试：dart run tool/dbg_transcribe.dart [文件名]
void main(List<String> args) {
  final name = args.isNotEmpty ? args.first : 'xiaoxingxing';
  final bytes = File('assets/samples/$name.wav').readAsBytesSync();
  // 纯 Dart 解码，避免引入 flutter 依赖（dart run 里没有 dart:ui）
  final wav = decodeWav(bytes);
  var mono = toMono(wav);
  if (wav.sampleRate != 22050) mono = resample(mono, wav.sampleRate, 22050);
  mono = normalize(mono);

  final a = analyzeMelody(mono, sampleRate: 22050);
  print('[$name] notes=${a.notes.length} bpm=${a.bpm.toStringAsFixed(1)} key=${a.keyName}${a.mode}');
  for (var i = 0; i < a.notes.length && i < 6; i++) {
    final n = a.notes[i];
    print('  $i  t=${n.startSec.toStringAsFixed(3)} dur=${n.durationSec.toStringAsFixed(3)}'
        '  ${describePitch(n.midi)}  cents=${n.cents.toStringAsFixed(1)}');
  }

  final q = quantizeToScore(a, options: const QuantizeOptions(beats: 4, beatType: 4));
  print('量化: bpm=${q.bpm.toStringAsFixed(1)} key=${q.keyName}${q.mode} '
      '小节=${q.score.measures.length} 音=${q.score.noteCount}');
  print('音级: ${_degreesOf(q.jianpu)}');
}

String _degreesOf(String jianpu) {
  if (jianpu.trim().isEmpty) return '';
  final score = parseJianpu(jianpu);
  final sb = StringBuffer();
  for (final m in score.measures) {
    for (final it in m.items) {
      if (it is NoteItem) sb.write(it.degree);
    }
  }
  return sb.toString();
}
