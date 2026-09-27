/// 端到端：Tsumugi（乐器无关）跑真实 ONNX + Dart 侧半-CRF 解码，
/// 与 Basic Pitch / CRNN 用**同一套和弦基准**出数字。
///
///   flutter test integration_test/tsumugi_e2e_test.dart -d windows
///
/// 需要导出的模型：third_party/tsumugi/tsumugi_amt.onnx（同目录要有 .onnx.data）
///   生成方式：tools/onnx_export/probe_tsumugi_export.py
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';
import 'package:jianpu_app/transcribe/tsumugi_engine.dart';

const String _defaultModel = 'D:/dsh work region/jianpu2staff/third_party/tsumugi/tsumugi_amt.onnx';

String _modelPath() => Platform.environment['TSUMUGI_ONNX_PATH'] ?? _defaultModel;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Tsumugi：真实 ONNX + Dart 解码，在和弦基准上出数字', (tester) async {
    final model = File(_modelPath());
    if (!model.existsSync() || !File('${model.path}.data').existsSync()) {
      markTestSkipped('缺少 Tsumugi ONNX（${model.path} 或同名 .data），先跑导出脚本');
      return;
    }
    final fixtureDir = Directory('build/fixtures');
    if (!fixtureDir.existsSync()) {
      markTestSkipped('缺少测试音频，先跑 flutter test test/_make_fixtures_test.dart');
      return;
    }
    final truth = jsonDecode(File('${fixtureDir.path}/truth.json').readAsStringSync()) as Map<String, dynamic>;
    final cases = truth['cases'] as Map<String, dynamic>;

    final engine = TsumugiEngine();
    expect(await engine.ensureLoaded(model.path), isTrue, reason: '加载失败：${engine.error}');
    addTearDown(engine.dispose);

    var tpAll = 0, detAll = 0, truthAll = 0;
    final sw = Stopwatch()..start();
    var audioSec = 0.0;

    for (final entry in cases.entries) {
      final name = entry.key;
      final chords = (entry.value as List<dynamic>).map((e) => e as Map<String, dynamic>).toList();
      final clip = await loadAudioFile('${fixtureDir.path}/chords_$name.wav',
          targetSampleRate: TsumugiConst.sampleRate);
      audioSec += clip.durationSec;
      final notes = await engine.transcribe(
        clip.samples,
        sampleRate: clip.sampleRate,
        onTiming: (onnxMs, scoreMs, viterbiMs, frames, pitches) {
          // ignore: avoid_print
          print('   [耗时] ONNX ${onnxMs}ms / 打分矩阵 ${scoreMs}ms / Viterbi ${viterbiMs}ms'
              '（$frames 帧 × $pitches 音高）');
        },
      );
      var tp = 0, det = 0, tot = 0;
      final lines = <String>[];
      for (final ch in chords) {
        final start = (ch['start'] as num).toDouble();
        final dur = (ch['dur'] as num).toDouble();
        final want = (ch['midis'] as List<dynamic>).map((e) => (e as num).toInt()).toSet();
        final found = notes
            .where((n) => n.startSec >= start - 0.25 && n.startSec <= start + dur * 0.6)
            .map((n) => n.midi.round())
            .toSet();
        final hit = found.intersection(want);
        tp += hit.length;
        det += found.length;
        tot += want.length;
        lines.add('   ${start.toStringAsFixed(1)}s [${want.map(_n).join(" ")}] 检出 ${found.length}：'
            '${found.map(_n).join(" ")}'
            '${want.difference(found).isEmpty ? "" : "  漏:${want.difference(found).map(_n).join(",")}"}'
            '${found.difference(want).isEmpty ? "" : "  多:${found.difference(want).map(_n).join(",")}"}');
      }
      tpAll += tp;
      detAll += det;
      truthAll += tot;
      // ignore: avoid_print
      print('== $name：recall=${(tp / tot * 100).round()}% '
          'precision=${det == 0 ? 0 : (tp / det * 100).round()}%');
      for (final l in lines) {
        // ignore: avoid_print
        print(l);
      }
    }
    sw.stop();
    final recall = (tpAll / truthAll * 100).round();
    final precision = detAll == 0 ? 0 : (tpAll / detAll * 100).round();
    // ignore: avoid_print
    print('合计：recall=$recall%  precision=$precision%（真值 $truthAll，检出 $detAll，命中 $tpAll）');
    // ignore: avoid_print
    print('速度：${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s 处理 '
        '${audioSec.toStringAsFixed(1)}s 音频（实时率 '
        '${(sw.elapsedMilliseconds / 1000 / audioSec).toStringAsFixed(2)}×）');
  }, timeout: const Timeout(Duration(minutes: 20)));
}

String _n(int midi) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return '${names[midi % 12]}${midi ~/ 12 - 1}';
}
