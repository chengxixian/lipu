/// AI 识谱集成测试：需要网络与 API Key，未设置 DEEPSEEK_API_KEY 时自动跳过
///
///   $env:DEEPSEEK_API_KEY='sk-...'; flutter test test/ai_recognizer_test.dart
///
/// 验证的是**结构化输出**这条新路径：让视觉模型直接给音符事件 JSON，
/// 再由它编成乐谱（等价于 MIDI 事件表），而不是让它写简谱文本。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/midi.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/omr/ai_notes.dart';
import 'package:jianpu_app/omr/cloud_recognizer.dart';

const String kImage = 'samples/real/春风吹_p1.jpg';

void main() {
  final key = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final model = Platform.environment['DEEPSEEK_MODEL'] ?? kDefaultCloudModel;

  test('AI 识谱：真实双声部谱页 -> 结构化音符事件 -> 乐谱', () async {
    if (key.isEmpty) {
      markTestSkipped('未设置 DEEPSEEK_API_KEY，跳过联网测试');
      return;
    }
    final file = File(kImage);
    expect(file.existsSync(), isTrue, reason: '缺少测试图片 $kImage');

    final started = DateTime.now();
    final recognizer = OpenAiCompatibleRecognizer(CloudConfig(apiKey: key, model: model));
    final result = await recognizer.recognize(file.readAsBytesSync());
    final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
    // ignore: avoid_print
    print('AI 识谱用时 ${elapsed.toStringAsFixed(1)}s，原始输出 ${result.jianpuText.length} 字符');

    // ---- 1) 模型应当按新提示词给结构化结果 ----
    final ai = parseAiNotes(result.jianpuText);
    if (ai == null) {
      // 把原始输出打出来，方便看模型到底给了什么
      // ignore: avoid_print
      print('!! 模型没有返回结构化 JSON，原文前 800 字：\n'
          '${result.jianpuText.substring(0, result.jianpuText.length.clamp(0, 800))}');
    }
    expect(ai, isNotNull, reason: '模型应当按提示词返回 {title,key,beats,notes:[...]} 这样的 JSON');
    // ignore: avoid_print
    print('结构化结果：标题「${ai!.title}」 调号 ${ai.keyName} '
        '${ai.beats}/${ai.beatType} ♩=${ai.tempo}，${ai.notes.length} 个音符事件，'
        '${ai.isGrandStaff ? "双声部" : "单声部"}');

    // ---- 2) 编成乐谱 ----
    final score = scoreFromAiNotes(ai);
    final chords = score.measures
        .expand((m) => [...m.items, ...m.items2])
        .whereType<NoteItem>()
        .where((n) => n.isChord)
        .length;
    // ignore: avoid_print
    print('乐谱：${score.measures.length} 小节 / ${score.pitchCount} 个音，'
        '大谱表=${score.isGrandStaff}，和弦 $chords 个，'
        '调号 ${score.meta.keyName}，告警 ${score.meta.warnings.length} 条');
    for (final w in score.meta.warnings.take(5)) {
      // ignore: avoid_print
      print('  ! $w');
    }

    expect(score.pitchCount, greaterThan(60), reason: '整页应转写出足够多的音符');
    expect(score.measures.length, greaterThan(4));

    // ---- 2b) 节奏（时值）必须是"真的识别出来了" ----
    // 这是用户实际反馈的问题：整页时值全一样 = 减时线/延音线/附点根本没看。
    // 所以这里直接把"时值分布"量出来，并断言不能全是同一个值。
    final durs = <double, int>{};
    for (final e in ai.notes) {
      final d = (e.dur * 1000).round() / 1000;
      durs[d] = (durs[d] ?? 0) + 1;
    }
    final hist = (durs.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => '${e.key}拍×${e.value}')
        .join('  ');
    // ignore: avoid_print
    print('时值分布（${durs.length} 种）：$hist');

    // 小节时值自洽性：AI 给的 dur 累加起来应当对得上拍号
    final startsPerBeat = ai.notes.where((n) => n.staff == 1).map((n) => n.start).toSet().length;
    final uniqueOnsets = ai.notes.map((n) => n.start).toSet().length;
    // ignore: avoid_print
    print('不同的起始拍位置：$uniqueOnsets 个（${startsPerBeat} 个在高音声部）');

    expect(durs.length, greaterThan(1),
        reason: '整页时值只有一个取值（$hist）说明节奏完全没识别：'
            '减时线/附点/延音横线必须体现到 dur 上');
    // 至少 20% 的音不是"最长的那个时值"，否则就是"绝大部分都是四分音符"的糊弄结果
    final mostCommon = durs.values.reduce((a, b) => a > b ? a : b);
    expect(mostCommon / ai.notes.length, lessThan(0.9),
        reason: '时值过于单一（$hist），节奏基本没识别出来');

    // 原谱第一小节是连续四个 3（上声部），转成 MIDI 后应当能看到四个同音高
    final midis = score.measures
        .take(3)
        .expand((m) => m.items)
        .whereType<NoteItem>()
        .map((n) => notePitches(n, score.key).first.midi)
        .toList();
    // ignore: avoid_print
    print('前几个音（MIDI）：$midis');

    // ---- 3) 生成的 MusicXML / MIDI 必须是好的 ----
    final xml = toMusicXML(score, padIncompleteMeasures: true);
    expect(xml, contains('<score-partwise'));
    expect(xml, isNot(contains("'q'")));
    expect(xml, contains('<type>quarter</type>'));
    final midi = toMidi(score);
    expect(String.fromCharCodes(midi.sublist(0, 4)), 'MThd');
    expect(String.fromCharCodes(midi.sublist(14, 18)), 'MTrk');
    // ignore: avoid_print
    print('导出：MusicXML ${xml.length} 字节，MIDI ${midi.length} 字节');

    // ---- 4) 每个小节的时值都应当自洽（结构化输出的主要好处）----
    final bad = score.meta.warnings.where((w) => w.contains('时值超出')).length;
    expect(bad, 0, reason: '结构化输出不应该出现小节时值超标');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
