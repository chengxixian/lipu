/// 端到端测试：在真实桌面端跑 Basic Pitch 神经网络扒谱。
///
/// 单元测试跑不了 ONNX Runtime（`flutter test` 没有原生插件），所以模型推理、
/// 切窗拼接、整条"音频 → 音符 → 简谱"链路都在这里验证。
///
/// 运行：
///   flutter test integration_test/basic_pitch_e2e_test.dart -d windows
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/core/midi.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';
import 'package:jianpu_app/transcribe/basic_pitch.dart';
import 'package:jianpu_app/transcribe/basic_pitch_engine.dart';
import 'package:jianpu_app/transcribe/melody.dart';
import 'package:jianpu_app/transcribe/quantize.dart';

/// 小星星主旋律真值（就是 `tool/make_polyphonic_sample.dart` 里用的那 42 个音）
const List<int> kXiaoXingXingMelody = [
  60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60,
  67, 67, 65, 65, 64, 64, 62, 67, 67, 65, 65, 64, 64, 62,
  60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60,
];

/// 最长公共子序列占比：容忍多检/漏检与时间偏移，衡量"旋律抓对了吗"
double melodyLcsRatio(List<int> detected, List<int> truth) {
  if (truth.isEmpty) return 1;
  var prev = List<int>.filled(truth.length + 1, 0);
  for (final d in detected) {
    final cur = List<int>.filled(truth.length + 1, 0);
    for (var j = 1; j <= truth.length; j++) {
      cur[j] = d == truth[j - 1]
          ? prev[j - 1] + 1
          : (prev[j] > cur[j - 1] ? prev[j] : cur[j - 1]);
    }
    prev = cur;
  }
  return prev[truth.length] / truth.length;
}

/// 大谱表简谱要能往返解析（两个声部前缀 + 和弦都保留）
bool quantizeGmOk(String jianpu) {
  if (!jianpu.contains('高音:') || !jianpu.contains('低音:')) return false;
  final again = parseJianpu(jianpu);
  return again.isGrandStaff && again.measures.any((m) => m.items2.isNotEmpty);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Basic Pitch 在真机上能识别小星星并给出正确旋律', (tester) async {
    final data = ByteData.sublistView(File('test/fixtures/xiaoxingxing.wav').readAsBytesSync());
    final clip = prepareWavBytes(data.buffer.asUint8List(), '小星星');
    expect(clip.sampleRate, BpConst.sampleRate);

    final engine = BasicPitchEngine();
    expect(await engine.ensureLoaded(), isTrue, reason: 'ONNX 模型应能加载：${engine.error}');

    final stages = <String>[];
    final notes = await engine.transcribe(clip.samples, onProgress: (_, s) => stages.add(s));
    expect(notes, isNotEmpty, reason: '应当检测到音符');
    // ignore: avoid_print
    print('Basic Pitch 原始音符 ${notes.length} 个，进度阶段 ${stages.length} 次');

    final analysis = analysisFromBasicPitch(
      notes,
      sampleRate: clip.sampleRate,
      durationSec: clip.durationSec,
    );
    final melody = analysis.activeNotes.map((n) => n.midiRound).toList();
    // ignore: avoid_print
    print('提取出的主旋律：$melody');

    // 小星星开头两句：1 1 5 5 6 6 5 | 4 4 3 3 2 2 1
    expect(melody.length, greaterThanOrEqualTo(13));
    expect(melody.take(7).toList(), [60, 60, 67, 67, 69, 69, 67]);
    expect(melodyLcsRatio(melody, kXiaoXingXingMelody), 1.0,
        reason: '干净单声部应当逐音全中');

    final result = quantizeToScore(analysis, options: const QuantizeOptions());
    // ignore: avoid_print
    print('生成的简谱：\n${result.jianpu}');
    expect(result.jianpu, contains('1'));
    expect(result.warnings.where((w) => w.contains('小节')), isEmpty,
        reason: '量化后每小节时值应当自洽');

    await engine.dispose();
  });

  testWidgets('复调混音（旋律+低音+琶音+噪声）里能扒出主旋律，并导出 MIDI / MusicXML', (tester) async {
    final data = ByteData.sublistView(File('test/fixtures/polyphonic.wav').readAsBytesSync());
    final clip = prepareWavBytes(data.buffer.asUint8List(), '复调示例');

    // 1) Basic Pitch（默认引擎）
    final engine = BasicPitchEngine();
    expect(await engine.ensureLoaded(), isTrue, reason: '${engine.error}');
    final notes = await engine.transcribe(clip.samples);
    final analysis = analysisFromBasicPitch(
      notes,
      sampleRate: clip.sampleRate,
      durationSec: clip.durationSec,
    );
    final bpMelody = analysis.activeNotes.map((n) => n.midiRound).toList();
    final bpScore = melodyLcsRatio(bpMelody, kXiaoXingXingMelody);

    // 2) 内置纯 Dart 算法（同样开"歌曲主旋律模式"）作为对照
    final builtin = analyzeMelody(
      clip.samples,
      sampleRate: clip.sampleRate,
      options: const TranscribeOptions(mixMode: true),
    );
    final oldScore = melodyLcsRatio(builtin.activeNotes.map((n) => n.midiRound).toList(), kXiaoXingXingMelody);

    // ignore: avoid_print
    print('复调混音主旋律命中率：Basic Pitch ${(bpScore * 100).toStringAsFixed(1)}%'
        '（${analysis.activeNotes.length} 个音） vs 内置算法 ${(oldScore * 100).toStringAsFixed(1)}%'
        '（${builtin.activeNotes.length} 个音）');

    expect(bpScore, greaterThanOrEqualTo(0.85), reason: 'Basic Pitch 在有伴奏的混音里应稳定抓到主旋律');
    expect(bpScore, greaterThanOrEqualTo(oldScore), reason: 'Basic Pitch 不应比内置算法更差');

    // 3) 音频 → 音符 → 简谱 → MIDI / MusicXML 整条链路
    final quantized = quantizeToScore(analysis, options: const QuantizeOptions());
    expect(quantized.jianpu.trim(), isNotEmpty);
    final score = parseJianpu(quantized.jianpu);
    expect(score.noteCount, greaterThan(20));

    final midi = toMidi(score);
    expect(String.fromCharCodes(midi.sublist(0, 4)), 'MThd', reason: 'MIDI 头应为 MThd');
    expect(midi[7], 6, reason: 'MThd 之后应是长度 6 的头块');
    expect(String.fromCharCodes(midi.sublist(14, 18)), 'MTrk', reason: '头块之后应直接是 MTrk 轨道块');
    expect(midi.length, greaterThan(200));

    final xml = toMusicXML(score);
    expect(xml, startsWith('<?xml'));
    expect(xml, contains('<score-partwise'));
    expect(xml, contains('<divisions>'));
    expect(RegExp(r'<measure ').allMatches(xml).length, score.measures.length,
        reason: 'MusicXML 的小节数应与乐谱一致');
    // ignore: avoid_print
    print('导出校验：MIDI ${midi.length} 字节，MusicXML ${xml.length} 字节 / ${score.measures.length} 小节');

    // 4) 钢琴谱（大谱表）：右手高音谱 + 左手低音谱，保留和弦。
    //    注意要用"全部音符"（melodyOnly: false）——上面的 analysis 已经过滤成单声部了。
    final full = analysisFromBasicPitch(
      notes,
      sampleRate: clip.sampleRate,
      durationSec: clip.durationSec,
      melodyOnly: false,
    );
    final grand = quantizeToGrandStaff(full, options: const QuantizeOptions());
    final gs = grand.score;
    // ignore: avoid_print
    print('大谱表：高音谱 ${gs.measures.fold<int>(0, (a, m) => a + m.items.length)} 个事件 / '
        '低音谱 ${gs.measures.fold<int>(0, (a, m) => a + m.items2.length)} 个事件，'
        '和弦 ${gs.measures.expand((m) => [...m.items, ...m.items2]).whereType<NoteItem>().where((n) => n.isChord).length} 个');
    expect(gs.isGrandStaff, isTrue, reason: '带伴奏的混音应当拆成两行谱表：${grand.warnings}');
    expect(gs.measures.any((m) => m.items2.isNotEmpty), isTrue, reason: '低音谱要有内容');
    expect(gs.meta.clef, 'grand');
    final gxml = toMusicXML(gs);
    expect(gxml, contains('<staves>2</staves>'));
    expect(gxml, contains('<backup>'));
    expect(gxml, contains('<chord/>'), reason: '钢琴谱里应当有和弦');
    expect(quantizeGmOk(grand.jianpu), isTrue, reason: '大谱表简谱应能往返：\n${grand.jianpu}');

    await engine.dispose();
  });

  testWidgets('内置纯 Dart 算法仍可作为后备引擎', (tester) async {
    final data = ByteData.sublistView(File('test/fixtures/xiaoxingxing.wav').readAsBytesSync());
    final clip = prepareWavBytes(data.buffer.asUint8List(), '小星星');
    final analysis = analyzeMelody(clip.samples, sampleRate: clip.sampleRate);
    // ignore: avoid_print
    print('内置算法识别到 ${analysis.activeNotes.length} 个音，BPM ${analysis.bpm.round()}');
    expect(analysis.activeNotes.length, greaterThan(5));
  });

  testWidgets('App 内置示例（Merry Christmas 前 90 秒）能真的扒出谱子', (tester) async {
    // 这条守的是"示例按钮点下去有没有用"：包里的资源必须能解码、
    // 真机推理能出音符、量化能出小节。
    final file = File('assets/samples/merry_christmas.wav');
    expect(file.existsSync(), isTrue, reason: '缺少内置示例音频');
    final clip = prepareWavBytes(file.readAsBytesSync(), '示例');
    // ignore: avoid_print
    print('内置示例：${clip.durationSec.toStringAsFixed(1)} 秒 / ${clip.sampleRate}Hz');

    final engine = BasicPitchEngine();
    expect(await engine.ensureLoaded(), isTrue, reason: 'ONNX 模型应能加载：${engine.error}');
    final started = DateTime.now();
    final notes = await engine.transcribe(clip.samples);
    final secs = DateTime.now().difference(started).inMilliseconds / 1000;
    expect(notes, isNotEmpty, reason: '示例音频应当能识别出音符');
    // ignore: avoid_print
    print('推理 ${secs.toStringAsFixed(1)}s，原始音符 ${notes.length} 个');

    final analysis = analysisFromBasicPitch(
      notes,
      sampleRate: clip.sampleRate,
      durationSec: clip.durationSec,
    );
    // ignore: avoid_print
    print('调号估计 ${analysis.keyName}，BPM ${analysis.bpm.round()}，'
        '主旋律 ${analysis.activeNotes.length} 个音');

    final result = quantizeToScore(analysis, options: const QuantizeOptions(title: '示例'));
    // ignore: avoid_print
    print('量化结果：${result.score.measures.length} 小节，'
        '${result.score.pitchCount} 个音，告警 ${result.score.meta.warnings.length} 条');
    // ignore: avoid_print
    print('前两行简谱：\n${result.jianpu.split('\n').take(4).join('\n')}');

    expect(analysis.activeNotes.length, greaterThan(80), reason: '90 秒的钢琴曲应当有一大堆音');
    expect(result.score.measures.length, greaterThan(10), reason: '应当量化成十几个小节以上');
    expect(result.score.pitchCount, greaterThan(60));
    // 调号估计不能太离谱（钢琴曲一般是少数几个调）
    expect(analysis.keyName, isNotEmpty);
    expect(analysis.bpm, inInclusiveRange(40, 220), reason: '速度估计要在合理范围');
    await engine.dispose();
  });
}
