/// 节奏（时值）识别相关的回归测试。
///
/// 背景：用户反馈"简谱识别没有调整音符的时间长短，所有音符的时长都一样，节奏也没注意"。
/// 这里守住三件事：
///   1. 内置提示词必须把**减时线 / 附点 / 延音横线 / 每小节时值自检**写清楚；
///   2. 有一个**确定性判据**能发现"整页时值都一样"（`looksLikeFlatRhythm`）；
///   3. 发现之后会**带补救提示词再问一次**，并且只在结果确实更丰富时才采用。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/omr/ai_notes.dart';
import 'package:jianpu_app/omr/cloud_recognizer.dart';
import 'package:jianpu_app/state.dart';

/// 造一份结构化输出：[durs] 依次给每个音的时值
String aiJson(List<double> durs, {int beats = 4}) {
  final notes = <String>[];
  var start = 0.0;
  for (final d in durs) {
    notes.add('[1,0,${start.toStringAsFixed(2)},$d]');
    start += d;
  }
  return '{"title":"t","key":"1=C","beats":$beats,"beatType":4,"tempo":96,'
      '"v1":[${notes.join(',')}]}';
}

void main() {
  group('内置提示词必须强调节奏', () {
    test('讲清减时线/附点/延音横线，并要求逐小节自检', () {
      const p = kDefaultCloudPrompt;
      // 减时线：一条/两条/三条分别对应几拍
      expect(p, contains('减时线'));
      expect(p, contains('0.5'));
      expect(p, contains('0.25'));
      // 附点
      expect(p, contains('附点'));
      expect(p, contains('1.5'));
      // 延音横线：每条 +1 拍
      expect(p, contains('延音'));
      // 休止符
      expect(p, contains('休止符'));
      // 每小节时值之和 = 拍号（模型能自己算的硬性自检）
      expect(p, contains('正好等于'));
      // 明确禁止"整页都写 1"
      expect(p, contains('绝不能因为看不清楚就全都写 1'));
      // 至少 3 种时值
      expect(p, contains('至少有 3 种'));
    });

    test('示例本身就是混合节奏，模型可以照抄格式', () {
      const p = kDefaultCloudPrompt;
      final sample = RegExp(r'\{"title".*?\}').firstMatch(p)?.group(0) ?? '';
      expect(sample, isNotEmpty);
      // 示例里的时值不能全都是 1
      final durs = RegExp(r'\[(\d+),(-?\d+),([\d.]+),([\d.]+)\]')
          .allMatches(sample)
          .map((m) => m.group(4))
          .toSet();
      expect(durs.length, greaterThan(1), reason: '示例应含多种时值：$sample');
    });

    test('补救提示词会点出上次的时值和一个都不许少', () {
      final p = rhythmRepairPrompt(noteCount: 180, flatDur: 1);
      expect(p, contains('上一次'));
      expect(p, contains('180'));
      expect(p, contains('减时线'));
      // 仍然带上完整规则，避免模型只看到"你错了"却不知道规则
      expect(p, contains('延音'));
      expect(p, contains(kDefaultCloudPrompt));
    });
  });

  group('节奏是否"平"的判据', () {
    test('整页同一个时值 = 平（这就是用户遇到的情况）', () {
      final ai = parseAiNotes(aiJson(List.filled(16, 1)))!;
      expect(looksLikeFlatRhythm(ai), isTrue);
      expect(dominantDuration(ai), 1);
      expect(durationHistogram(ai.notes).length, 1);
    });

    test('超过九成是同一个时值 = 平', () {
      final durs = <double>[...List.filled(19, 1), 0.5];
      final ai = parseAiNotes(aiJson(durs))!;
      expect(looksLikeFlatRhythm(ai), isTrue);
    });

    test('有四种时值 = 不平', () {
      final durs = <double>[
        ...List.filled(6, 1),
        ...List.filled(6, 0.5),
        ...List.filled(4, 0.25),
        ...List.filled(2, 2),
      ];
      final ai = parseAiNotes(aiJson(durs))!;
      expect(looksLikeFlatRhythm(ai), isFalse);
      expect(dominantDuration(ai), 1);
      expect(durationHistogram(ai.notes).length, 4);
    });

    test('音符太少时不判（短练习曲本来就可能全是四分音符）', () {
      final ai = parseAiNotes(aiJson(List.filled(6, 1)))!;
      expect(looksLikeFlatRhythm(ai), isFalse);
    });
  });

  group('发现节奏缺失后自动重问一次', () {
    test('第一次全 1 拍 → 第二次换提示词重问，采用更丰富的结果', () async {
      final prompts = <String?>[];
      var call = 0;
      final raw = await AppState.recognizeWithRhythmCheck((p, {effort}) async {
        prompts.add(p);
        call++;
        if (call == 1) return aiJson(List.filled(16, 1));
        return aiJson(<double>[
          ...List.filled(6, 1),
          ...List.filled(6, 0.5),
          ...List.filled(4, 0.25),
        ]);
      });

      expect(prompts.length, 2, reason: '应当重问一次');
      expect(prompts.first, isNull, reason: '第一次用默认提示词');
      expect(prompts.last, contains('上一次'));
      expect(prompts.last, contains('减时线'));
      final ai = parseAiNotes(raw)!;
      expect(durationHistogram(ai.notes).length, 3, reason: '应当采用重问后的结果');
      expect(looksLikeFlatRhythm(ai), isFalse);
    });

    test('节奏本来就正常 → 只问一次，不浪费一次请求', () async {
      final prompts = <String?>[];
      final raw = await AppState.recognizeWithRhythmCheck((p, {effort}) async {
        prompts.add(p);
        return aiJson(<double>[
          ...List.filled(6, 1),
          ...List.filled(6, 0.5),
          ...List.filled(4, 2),
        ]);
      });
      expect(prompts.length, 1);
      expect(parseAiNotes(raw), isNotNull);
    });

    test('重问仍然"平"且没有更丰富 → 保留第一次的结果，也不会无限重问', () async {
      final prompts = <String?>[];
      final raw = await AppState.recognizeWithRhythmCheck((p, {effort}) async {
        prompts.add(p);
        return aiJson(List.filled(16, 1));
      });
      expect(prompts.length, 2, reason: '只补救一次');
      expect(parseAiNotes(raw)!.notes.length, 16);
    });

    test('模型没给结构化 JSON（走文本兜底）→ 会要求重新输出 JSON', () async {
      final prompts = <String?>[];
      final raw = await AppState.recognizeWithRhythmCheck((p, {effort}) async {
        prompts.add(p);
        return '1=C 4/4\n1 2 3 4 |]';
      });
      expect(prompts.length, 2, reason: '格式不对要重问一次');
      expect(prompts.last, contains('JSON'));
      expect(raw, contains('1 2 3 4'), reason: '仍拿不到 JSON 时要保留文本给兜底路径');
    });

    test('补救时的状态文字会告诉用户在做什么', () async {
      final stages = <String>[];
      await AppState.recognizeWithRhythmCheck(
        (p, {effort}) async =>
            p == null ? aiJson(List.filled(16, 1)) : aiJson(List.filled(16, 0.5)),
        onStage: stages.add,
      );
      expect(stages, isNotEmpty);
      expect(stages.first, contains('节奏'));
    });

    test('模型返回的是简谱文本（没走结构化）时，格式和节奏都要补救', () async {
      final prompts = <String?>[];
      var call = 0;
      final flatText = '1=C 4/4\n${List.filled(16, '1').join(' ')} |]';
      final mixedText =
          '1=C 4/4\n1/ 1/ 1 1 - | 1// 1// 1 1 - | 1/ 1/ 1 1 - | 1// 1// 1 1 - |]';
      final raw = await AppState.recognizeWithRhythmCheck((p, {effort}) async {
        prompts.add(p);
        call++;
        // 第一次给"平的"文本；后面无论问什么，都给节奏正确但仍是文本的结果
        return call == 1 ? flatText : mixedText;
      });
      // 第 1 次：默认提示；第 2 次：格式重问（要 JSON）；第 3 次：节奏重问
      expect(prompts.length, 3, reason: '格式和节奏各补救一次：$prompts');
      expect(prompts[1], contains('JSON'), reason: '先要求结构化格式');
      expect(prompts.last, contains('减时线'), reason: '再要求重看节奏');
      expect(raw, contains('1/'), reason: '应当采用补救后的文本');
    });

    test('补救那一遍会提高推理强度（让它真的重看一遍）', () async {
      final efforts = <String?>[];
      await AppState.recognizeWithRhythmCheck(
        (p, {effort}) async {
          efforts.add(effort);
          return p == null ? aiJson(List.filled(16, 1)) : aiJson(List.filled(16, 0.5));
        },
      );
      expect(efforts.length, 2);
      expect(efforts.first, isNull, reason: '第一次用默认推理强度');
      expect(efforts.last, 'medium');
    });

    test('补救请求失败时不能把整次识别搞崩', () async {
      final raw = await AppState.recognizeWithRhythmCheck((p, {effort}) async {
        if (p != null) throw StateError('网络抖了一下');
        return aiJson(List.filled(16, 1));
      });
      expect(parseAiNotes(raw), isNotNull, reason: '应当保留第一次的结果');
    });
  });

  group('标题：用谱面上的曲名，不拿拍照文件名凑数', () {
    test('拍照/截图/时间戳文件名不算曲名', () {
      final state = AppState();
      for (final junk in [
        '7281',
        'IMG_20240924_210806',
        'Screenshot_2026-09-24-21-08-06-842',
        'mmexport1699000000000',
        'wx_camera_1699000000000',
        'DSC01234',
        '20240924',
      ]) {
        expect(state.looksLikeSongName(junk), isFalse, reason: '$junk 不该当曲名');
      }
      for (final ok in ['女儿情', '春风吹_p1', 'Merry Christmas', '茉莉花', 'song-01']) {
        expect(state.looksLikeSongName(ok), isTrue, reason: '$ok 可以当曲名');
      }
    });

    test('提示词要求抄谱面上的曲名，并明确不要写数字', () {
      const p = kDefaultCloudPrompt;
      expect(p, contains('曲名 title'));
      expect(p, contains('谱面上印的曲名'));
      expect(p, contains('不要写数字'));
    });
  });

  group('配置里存的旧提示词不能挡住新提示词', () {
    test('老配置（没有 promptCustom 字段）读回来要用当前内置提示词', () {
      // 这就是用户"改了提示词却没效果"的原因：设置面板把提示词正文一起存进了
      // ai_recognizer.json，升级后读回来的还是旧版本那份。
      final legacy = <String, dynamic>{
        'endpoint': kDefaultCloudEndpoint,
        'apiKey': 'sk-test',
        'model': kDefaultCloudModel,
        'prompt': '你是简谱识谱专家。请把图片里的简谱识别成**音符事件表**，用 JSON 输出。\n'
            '（这是 build 8 的老提示词，只提了一句"时值以四分音符为 1"）',
        'reasoningEffort': 'low',
        'maxTokens': 16000,
      };
      final cfg = CloudConfig.fromJson(legacy);
      expect(cfg.prompt, kDefaultCloudPrompt, reason: '必须是当前内置的那份');
      expect(cfg.prompt, contains('减时线'), reason: '新提示词才有的节奏规则');
      expect(cfg.prompt, contains('曲名 title'));
      expect(cfg.promptCustom, isFalse);
      expect(cfg.maxTokens, greaterThanOrEqualTo(65536), reason: '旧的 16000 会截断长输出');
      // Key / 地址 / 模型这些用户填的必须原样保留
      expect(cfg.apiKey, 'sk-test');
      expect(cfg.model, kDefaultCloudModel);
    });

    test('用户自己改过的提示词要保留', () {
      final cfg = CloudConfig.fromJson({
        'prompt': '我自己写的提示词',
        'promptCustom': true,
        'maxTokens': 40000,
      });
      expect(cfg.prompt, '我自己写的提示词');
      expect(cfg.promptCustom, isTrue);
      expect(cfg.maxTokens, 40000);
    });

    test('存下来的配置带版本号，再读回来还是当前提示词', () {
      final cfg = const CloudConfig(apiKey: 'sk-test');
      final back = CloudConfig.fromJson(jsonDecode(jsonEncode(cfg.toJson())) as Map<String, dynamic>);
      expect(back.prompt, kDefaultCloudPrompt);
      expect(back.apiKey, 'sk-test');
      expect(back.promptRev, kPromptRev);
    });
  });

  group('休止符（停顿）', () {
    test('AI 给的空档要变成休止符，并写进 MusicXML', () {
      // 第一小节前 2.5 拍是空档（春风吹开头就是「0 0 0 712」这种）
      final json = '{"title":"t","key":"1=C","beats":4,"beatType":4,"tempo":96,'
          '"v1":[[7,0,2.5,0.5],[1,0,3,0.5],[2,0,3.5,0.5]]}';
      final score = scoreFromAiNotes(parseAiNotes(json)!);
      final items = score.measures.first.items;
      expect(items.first, isA<RestItem>(), reason: '开头空档必须补成休止符');
      expect(items.first.ticks, closeTo(2.5, 1e-6));
      final xml = toMusicXML(score, padIncompleteMeasures: true);
      expect(xml, contains('<rest/>'));
    });

    test('三连音的浮点误差不能变成"0.001 拍的休止符"', () {
      // 0.333+0.333+0.334 = 1.0（差一点点），不吸附就会冒出一个垃圾休止符
      final json = '{"title":"t","key":"1=C","beats":4,"beatType":4,"tempo":96,'
          '"v1":[[7,0,0,0.333],[1,0,0.333,0.333],[2,0,0.667,0.334],[5,0,1,3]]}';
      final score = scoreFromAiNotes(parseAiNotes(json)!);
      final items = score.measures.first.items;
      final microRests = items.whereType<RestItem>().where((r) => r.ticks < kFineGrid - kEps);
      expect(microRests, isEmpty, reason: '不该有比细网格还小的休止符：$items');
      // 三连音时值本身要保住（吸附到 1/48 网格后仍是 16/48）
      final durs = items.whereType<NoteItem>().map((n) => (n.ticks * 1000).round() / 1000).toList();
      expect(durs.where((d) => (d - 0.333).abs() < 0.005).length, 3, reason: '$durs');
    });

    test('小节末尾不足的空间要补休止符（不能靠"拉长最后一个音"）', () {
      final json = '{"title":"t","key":"1=C","beats":4,"beatType":4,"tempo":96,'
          '"v1":[[1,0,0,1],[3,0,1,1]]}';
      final score = scoreFromAiNotes(parseAiNotes(json)!);
      final xml = toMusicXML(score, padIncompleteMeasures: true);
      expect(score.measures.first.filled + kEps, greaterThanOrEqualTo(2));
      expect(RegExp(r'<rest/>').allMatches(xml), isNotEmpty, reason: '缺的拍子要补休止符');
    });
  });

  group('模型写成简谱文本时要重新要一次 JSON', () {
    test('第一次返回文本 → 换"只输出 JSON"的提示再要一次，采用 JSON', () async {
      final prompts = <String?>[];
      var call = 0;
      final mixed = aiJson(<double>[
        ...List.filled(6, 1),
        ...List.filled(6, 0.5),
        ...List.filled(4, 0.25),
      ]);
      final raw = await AppState.recognizeWithRhythmCheck((p, {effort}) async {
        prompts.add(p);
        call++;
        return call == 1 ? '1=C 4/4\n1 2 3 4 |]' : mixed;
      });
      expect(prompts.length, 2, reason: '格式不对必须重问一次');
      expect(prompts.last, contains('JSON'), reason: '重问要明确"只输出 JSON"');
      expect(parseAiNotes(raw), isNotNull);
      expect(AppState.rhythmOf(raw)!.count, greaterThan(10), reason: '应当采用音数更多的结构化结果');
    });

    test('两次都只给文本 → 保留文本，交给兜底路径，不会崩', () async {
      final raw = await AppState.recognizeWithRhythmCheck(
        (p, {effort}) async => '1=C 4/4\n1 2 3 4 |]',
      );
      expect(raw, contains('1 2 3 4'));
    });

    test('第一次就是结构化 JSON → 不触发格式重问（不浪费请求）', () async {
      var calls = 0;
      await AppState.recognizeWithRhythmCheck((p, {effort}) async {
        calls++;
        return aiJson(<double>[
          ...List.filled(6, 1),
          ...List.filled(6, 0.5),
          ...List.filled(4, 2),
        ]);
      });
      expect(calls, 1);
    });
  });

  group('识别结果不能再被"文本往返"抹平节奏', () {
    /// 走完整的识谱流程（用 debug hook 喂结构化 JSON）
    Future<Score> recognize(String raw) async {
      final state = AppState();
      state.debugRecognizeHook = (input) async => raw;
      await state.recognizeImages([
        RecognizeInput('示范.jpg', Uint8List.fromList(const [1, 2, 3])),
      ]);
      return state.score!;
    }

    List<double> dursOf(Score s) => s.measures
        .expand((m) => [...m.items, ...m.items2])
        .whereType<NoteItem>()
        .map((n) => (n.ticks * 1000).round() / 1000)
        .toList();

    test('三连音（1/3 拍）必须活到乐谱里', () async {
      // 简谱文本语法表达不了 1/3 拍：一旦"成谱→简谱文本→再解析"，就会被抹成 1 拍
      final score = await recognize(
        '{"title":"t","key":"1=C","beats":4,"beatType":4,"tempo":96,'
        '"v1":[[7,0,0,0.333],[1,0,0.333,0.333],[2,0,0.667,0.334],[5,0,1,3]]}',
      );
      final durs = dursOf(score);
      // ignore: avoid_print
      print('三连音成谱：$durs   简谱文本：${score.meta.title}');
      expect(durs.where((d) => (d - 0.333).abs() < 0.02).length, 3,
          reason: '三个三连音都要保留 1/3 拍，实际：$durs');
      expect(score.measures.first.filled, closeTo(4.0, 0.02));
    });

    test('常见时值组合都能原样保留', () async {
      final score = await recognize(
        '{"title":"t","key":"1=C","beats":4,"beatType":4,"tempo":96,'
        '"v1":[[1,0,0,0.5],[2,0,0.5,0.25],[3,0,0.75,0.75],[5,0,1.5,2.5]]}',
      );
      final durs = dursOf(score);
      // ignore: avoid_print
      print('时值组合成谱：$durs');
      expect(durs, containsAll(<double>[0.5, 0.25, 0.75, 2.5]));
    });

    test('多页时在乐谱层面拼接，时值一样不会被抹平', () async {
      final state = AppState();
      var call = 0;
      state.debugRecognizeHook = (input) async {
        call++;
        return call == 1
            ? '{"title":"t","key":"1=C","beats":4,"beatType":4,"tempo":96,'
                '"v1":[[7,0,0,0.333],[1,0,0.333,0.333],[2,0,0.667,0.334],[5,0,1,3]]}'
            : '{"title":"t","key":"1=C","beats":4,"beatType":4,"tempo":96,'
                '"v1":[[1,0,0,0.25],[2,0,0.25,0.25],[3,0,0.5,3.5]]}';
      };
      await state.recognizeImages([
        RecognizeInput('a.jpg', Uint8List.fromList(const [1])),
        RecognizeInput('b.jpg', Uint8List.fromList(const [2])),
      ]);
      final score = state.score!;
      final durs = dursOf(score);
      // ignore: avoid_print
      print('两页拼接：${score.measures.length} 小节  时值 $durs');
      expect(score.measures.length, greaterThanOrEqualTo(2));
      expect(durs.where((d) => (d - 0.333).abs() < 0.02).length, 3, reason: '$durs');
      expect(durs.where((d) => (d - 0.25).abs() < 0.02).length, 2, reason: '$durs');
    });
  });
}
