/// **管线保真度检查**：CRNN 原始音符 → 量化 → 乐谱，音高有没有被改坏？
///
///   flutter test integration_test/crnn_pipeline_fidelity_test.dart -d windows
///
/// 背景：用户反馈"CRNN 扒钢琴谱音不对"。已单独验证过引擎本身（`crnn_real_audio_probe_test.dart`：
/// 检出音高与音频频谱峰值一致 ✓），所以嫌疑落到**下游管线**（量化把音并成和弦、
/// 时值吸附、调号/谱号转换等）。这个测试直接把两边的音高集合拿来比：
///   原始检出音高   vs   量化进乐谱后的音高
/// 少了哪些、多了哪些，一眼就能看出是哪一步弄坏的。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';
import 'package:jianpu_app/transcribe/crnn_engine.dart';
// （melody 里的类型由 quantize/crnn_engine 间接引入，不需要直接 import）
import 'package:jianpu_app/transcribe/quantize.dart';
import 'package:jianpu_app/core/model.dart';

const String _defaultModel = 'D:/dsh work region/jianpu2staff/third_party/piano_crnn/piano_crnn.onnx';
const String _wav = 'assets/samples/merry_christmas.wav';

String _n(int midi) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return '${names[((midi % 12) + 12) % 12]}${midi ~/ 12 - 1}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CRNN → 量化 → 乐谱：音高保真度', (tester) async {
    final model = File(_defaultModel);
    if (!model.existsSync()) {
      markTestSkipped('缺少 CRNN 模型');
      return;
    }
    final clip = await loadAudioFile(_wav, targetSampleRate: CrnnConst.sampleRate);
    final engine = PianoCrnnEngine();
    expect(await engine.ensureLoaded(model.path), isTrue, reason: '${engine.error}');
    addTearDown(engine.dispose);

    final notes = await engine.transcribe(clip.samples);
    final rawPitches = notes.map((n) => n.midi.round()).toSet();
    final analysis = analysisFromDetectedNotes(
      notes,
      sampleRate: clip.sampleRate,
      durationSec: clip.durationSec,
      melodyOnly: false,
    );

    // 走 App 的真实管线（transcribe_view 的默认设置：双谱表、bpm 0 = 自动估计、0.25 网格）
    final options = QuantizeOptions(
      bpm: 0, // 0 = 用分析里估计的 bpm
      beats: 4,
      beatType: 4,
      keyName: null, // null = 用分析里估计的调
      grid: 0.25,
      keepRests: true,
      title: 'float',
    );
    final result = quantizeToGrandStaff(analysis, options: options);
    final score = result.score;

    // 乐谱里出现的所有音高（含和弦音）
    final ki = score.key;
    final scorePitches = <int>{};
    var noteItems = 0;
    for (final m in score.measures) {
      for (final it in <Item>[...m.items, ...m.items2]) {
        if (it is! NoteItem) continue;
        noteItems++;
        for (final p in notePitches(it, ki)) {
          scorePitches.add(p.midi);
        }
      }
    }

    // ignore: avoid_print
    print('引擎检出 ${notes.length} 个音（${rawPitches.length} 种音高）'
        ' → 乐谱 ${noteItems} 个音（${scorePitches.length} 种音高），'
        '小节 ${score.measures.length}，估计 bpm ${analysis.bpm.toStringAsFixed(0)} 调 ${analysis.keyName}');

    final lost = rawPitches.difference(scorePitches);
    final added = scorePitches.difference(rawPitches);
    // ignore: avoid_print
    print('音高种类：丢失 ${lost.length}（${lost.take(12).map(_n).join(" ")}）'
        ' / 多出 ${added.length}（${added.take(12).map(_n).join(" ")}）');

    // 逐音高统计出现次数（看是不是"八度错位"这类系统性偏移）
    int countIn(Iterable<int> xs, int pitch) => xs.where((x) => x == pitch).length;
    final rawList = notes.map((n) => n.midi.round()).toList();
    for (final p in (rawPitches.intersection(scorePitches).toList()..sort())) {
      final a = countIn(rawList, p);
      // 乐谱里的计数（每个 NoteItem 的每个音）
      var b = 0;
      for (final m in score.measures) {
        for (final it in <Item>[...m.items, ...m.items2]) {
          if (it is! NoteItem) continue;
          for (final x in notePitches(it, ki)) {
            if (x.midi == p) b++;
          }
        }
      }
      if ((a - b).abs() > a * 0.5 && a >= 3) {
        // ignore: avoid_print
        print('   ⚠️ ${_n(p)}：检出 $a 次 → 乐谱 $b 次');
      }
    }

    // 音高集合的相似度：量化允许合并/吸附，但**不该引入大量新音高**
    final overlap = rawPitches.intersection(scorePitches).length;
    final ratio = overlap / math.max(1, rawPitches.length);
    // ignore: avoid_print
    print('音高重合率 ${(ratio * 100).toStringAsFixed(1)}%（引擎 ${rawPitches.length} 种）');
    expect(ratio, greaterThan(0.5), reason: '量化不该把一半以上的音高弄丢或改掉');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
