/// 扒谱链路测试：真实示例音频 -> 分析 -> 量化 -> 钢琴卷帘/五线谱 PNG
///
/// 音高比对与调号无关（同一组音记成大调或关系小调都算对），
/// 同时产出可人工检查的 PNG 快照。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/render/staff_layout.dart';
import 'package:jianpu_app/render/staff_painter.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';
import 'package:jianpu_app/transcribe/melody.dart';
import 'package:jianpu_app/transcribe/quantize.dart';
import 'package:jianpu_app/ui/piano_roll.dart';

/// 示例音频对应的原始简谱（与 tool/make_sample_wav.dart 保持一致）
const Map<String, String> _sources = {
  'xiaoxingxing': '''1=C 4/4 ♩=96
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |
5 5 4 4 | 3 3 2 - | 5 5 4 4 | 3 3 2 - |
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]''',
  'molihua': '''1=D 4/4 ♩=72
3 3 5 6 | 1' 6 5 6 | 5 5 3 5 | 6 - - - |
3 3 5 6 | 1' 6 5 6 | 5 5 3 5 | 6 - - - |]''',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // flutter test 不自动加载 pubspec 字体，这里显式加载 Bravura 与中文字体
    final bravura = File('assets/fonts/Bravura.otf');
    if (bravura.existsSync()) {
      final loader = FontLoader('Bravura')
        ..addFont(Future.value(ByteData.sublistView(bravura.readAsBytesSync())));
      await loader.load();
    }
    final hei = File(r'C:\Windows\Fonts\simhei.ttf');
    if (hei.existsSync()) {
      final loader = FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(hei.readAsBytesSync())));
      await loader.load();
    }
  });

  test('示例音频：扒谱 -> 简谱 -> 五线谱（音高应与原谱一致，并输出快照）', () async {
    final outDir = Directory('build/snapshots');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    for (final entry in _sources.entries) {
      final name = entry.key;
      final source = entry.value;
      final file = File('test/fixtures/$name.wav');
      expect(file.existsSync(), isTrue, reason: '缺少测试音源（先跑 tool/make_sample_wav.dart）');

      final clip = prepareWavBytes(file.readAsBytesSync(), name);
      final analysis = analyzeMelody(clip.samples, sampleRate: clip.sampleRate);
      final q = quantizeToScore(analysis, options: const QuantizeOptions(beats: 4, beatType: 4));

      final expectedPitches = _pitchesOf(parseJianpu(source));
      final actualPitches = _pitchesOf(q.score);

      // ignore: avoid_print
      print('[$name] 检测 ${analysis.activeNotes.length} 个音 · ${analysis.bpm.toStringAsFixed(0)} BPM'
          ' · 分析调号 ${analysis.keyName}${analysis.mode} · 量化后用 ${q.bpm.toStringAsFixed(1)} BPM / 1=${q.keyName}');
      // ignore: avoid_print
      final match = _lcs(expectedPitches, actualPitches);
      final ratio = expectedPitches.isEmpty ? 0.0 : match / expectedPitches.length;
      // ignore: avoid_print
      print('[$name] 音高序列匹配 ${(ratio * 100).toStringAsFixed(1)}% ($match/${expectedPitches.length})');

      expect(expectedPitches.length, analysis.activeNotes.length,
          reason: '音符个数应与原谱一致（期望 ${expectedPitches.length}，实际 ${analysis.activeNotes.length}）');
      expect(ratio, greaterThan(0.9), reason: '音高序列匹配率过低：$actualPitches');

      await _snapshotPianoRoll(analysis, '${outDir.path}/${name}_钢琴卷帘.png');
      await _snapshotStaff(q, '${outDir.path}/${name}_扒谱五线谱.png');
    }
  });
}

/// 乐谱 -> MIDI 音高序列
List<int> _pitchesOf(Score score) {
  final ki = score.key;
  final out = <int>[];
  for (final m in score.measures) {
    for (final it in m.items) {
      if (it is NoteItem) out.add(noteToPitch(it, ki).midi);
    }
  }
  return out;
}

int _lcs(List<int> a, List<int> b) {
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

Future<void> _snapshotPianoRoll(MelodyAnalysis analysis, String path) async {
  const width = 1000.0;
  const height = 300.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(const Rect.fromLTWH(0, 0, width, height), Paint()..color = const Color(0xFF1C1B1F));
  PianoRollPainter(
    analysis: analysis,
    duration: analysis.durationSec,
    background: const Color(0xFF1C1B1F),
    gridLine: const Color(0x33FFFFFF),
    barLine: const Color(0x88D0BCFF),
    blackKeyRow: const Color(0xFF26232B),
    cLabel: const Color(0xFFCCC2DC),
    trackColor: const Color(0xFF7FD8C8),
    noteColor: const Color(0xFFD0BCFF),
    removedColor: const Color(0x88F2B8B5),
    textColor: const Color(0xFFE6E1E5),
  ).paint(canvas, const Size(width, height));
  final image = await recorder.endRecording().toImage(width.toInt(), height.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
  image.dispose();
}

Future<void> _snapshotStaff(QuantizeResult q, String path) async {
  final doc = layoutScore(q.score, width: 1000, style: const StaffStyle(space: 11));
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, doc.width, doc.height));
  canvas.drawRect(Rect.fromLTWH(0, 0, doc.width, doc.height), Paint()..color = const Color(0xFFFFFFFF));
  StaffPainter(doc, color: const Color(0xFF111111), accent: const Color(0xFF6750A4))
      .paint(canvas, Size(doc.width, doc.height));
  final image = await recorder.endRecording().toImage(doc.width.ceil(), doc.height.ceil());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
  image.dispose();
}
