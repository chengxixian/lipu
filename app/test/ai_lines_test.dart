/// 分行并发识谱的单元测试：切行几何、提示词、按小节拼接
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/omr/ai_lines.dart';
import 'package:jianpu_app/omr/ai_notes.dart';
import 'package:jianpu_app/omr/omr.dart';
import 'package:jianpu_app/omr/omr_core.dart';
import 'package:jianpu_app/omr/omr_service.dart';

AiNotesScore scoreOf(List<List<double>> notes, {String key = 'C', int beats = 4}) {
  const offsets = [0, 2, 4, 5, 7, 9, 11];
  final out = <AiNoteEvent>[];
  for (final n in notes) {
    final degree = n[0].round();
    final octave = n[1].round();
    final start = n[2];
    final dur = n[3];
    final staff = n.length > 4 ? n[4].round() : 1;
    final midi = 60 + 12 * octave + offsets[(degree - 1).clamp(0, 6)];
    out.add(AiNoteEvent(
      staff: staff,
      midi: midi,
      start: start,
      dur: dur,
      degree: degree,
      octave: octave,
      accidental: '',
    ));
  }
  return AiNotesScore(keyName: key, beats: beats, notes: out);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('按小节拼接', () {
    test('每段的音按"前面各段的小节数"整体后移', () {
      // 第 1 段：4 拍 = 1 小节；第 2 段：8 拍 = 2 小节
      final a = scoreOf([
        [1, 0, 0, 2],
        [2, 0, 2, 2],
      ]);
      final b = scoreOf([
        [3, 0, 0, 4],
        [5, 0, 4, 4],
      ]);
      final r = assembleLineParts(
        parts: [a, b],
        title: 't',
        keyName: 'C',
        beats: 4,
        beatType: 4,
        tempo: 96,
      );
      expect(r.measuresPerSystem, [1, 2]);
      expect(r.score.notes.length, 4);
      // 第二段整体后移 4 拍
      expect(r.score.notes[2].start, 4);
      expect(r.score.notes[3].start, 8);
      // 音频总长 = 3 小节
      var end = 0.0;
      for (final n in r.score.notes) {
        end = math.max(end, n.start + n.dur);
      }
      expect(end, 12);
    });

    test('段尾多出的一点点（模型多写半拍）按最近小节吸附', () {
      final a = scoreOf([
        [1, 0, 0, 4],
        [2, 0, 4, 0.4], // 实际 4.4 拍 → 吸附成 1 小节
      ]);
      final b = scoreOf([
        [3, 0, 0, 2],
      ]);
      final r = assembleLineParts(
        parts: [a, b],
        title: 't',
        keyName: 'C',
        beats: 4,
        beatType: 4,
        tempo: 96,
      );
      expect(r.measuresPerSystem, [1, 1]);
      expect(r.score.notes.last.start, 4);
    });

    test('3/4 拍号按 3 拍一小节折算', () {
      final a = scoreOf([
        [1, 0, 0, 3],
      ], beats: 3);
      final b = scoreOf([
        [2, 0, 0, 6],
      ], beats: 3);
      final r = assembleLineParts(
        parts: [a, b],
        title: 't',
        keyName: 'C',
        beats: 3,
        beatType: 4,
        tempo: 96,
      );
      expect(r.measuresPerSystem, [1, 2]);
      expect(r.score.notes.last.start, 3);
    });

    test('空段被跳过，不产生偏移', () {
      final a = scoreOf([
        [1, 0, 0, 4],
      ]);
      final empty = AiNotesScore(keyName: 'C', beats: 4, notes: const []);
      final b = scoreOf([
        [2, 0, 0, 4],
      ]);
      final r = assembleLineParts(
        parts: [a, empty, b],
        title: 't',
        keyName: 'C',
        beats: 4,
        beatType: 4,
        tempo: 96,
      );
      expect(r.measuresPerSystem, [1, 0, 1]);
      expect(r.score.notes.last.start, 4);
    });

    test('两个声部一起顺接（低音声部也跟着偏移）', () {
      final a = scoreOf([
        [1, 0, 0, 4, 1],
        [1, -1, 0, 4, 2],
      ]);
      final b = scoreOf([
        [2, 0, 0, 4, 1],
        [5, -1, 0, 4, 2],
      ]);
      final r = assembleLineParts(
        parts: [a, b],
        title: 't',
        keyName: 'C',
        beats: 4,
        beatType: 4,
        tempo: 96,
      );
      final v2 = r.score.notes.where((n) => n.staff == 2).toList();
      expect(v2.length, 2);
      expect(v2.first.start, 0);
      expect(v2.last.start, 4);
    });
  });

  group('页眉解析', () {
    test('正常 JSON', () {
      final h = AiPageHeader.fromRaw('{"title":"春风吹","key":"1=C","beats":4,"beatType":4,"tempo":60}');
      expect(h.title, '春风吹');
      expect(h.keyRaw, '1=C');
      expect(h.beats, 4);
      expect(h.tempo, 60);
    });

    test('曲名清洗：书名号剥掉，"简谱/未命名/纯数字"不算曲名', () {
      expect(AiPageHeader.fromRaw('{"title":"《茉莉花》"}').title, '茉莉花');
      expect(AiPageHeader.fromRaw('{"title":"简谱"}').title, '');
      expect(AiPageHeader.fromRaw('{"title":"未命名"}').title, '');
      expect(AiPageHeader.fromRaw('{"title":"1 2 3 4"}').title, '');
      expect(AiPageHeader.fromRaw('{"title":""}').title, '');
    });

    test('字段缺失时给安全默认值', () {
      final h = AiPageHeader.fromRaw('{"title":"x"}');
      expect(h.beats, 4);
      expect(h.beatType, 4);
      expect(h.tempo, 0);
      expect(h.keyRaw, '');
    });

    test('返回的不是 JSON 时不崩', () {
      final h = AiPageHeader.fromRaw('看不懂的内容');
      expect(h.title, '');
      expect(h.beats, 4);
    });
  });

  group('分段提示词', () {
    test('告诉模型是第几段、start 从 0 开始、已知调号要照抄', () {
      final p = aiLinePrompt(
        index: 1,
        total: 6,
        layout: ScoreLayoutMode.grandStaff,
        knownTitle: '春风吹',
        knownKey: '1=C',
        beats: 4,
        beatType: 4,
        tempo: 60,
      );
      expect(p, contains('第 2 段'));
      expect(p, contains('共 6 段'));
      expect(p, contains('start = 0'));
      expect(p, contains('调号=1=C'));
      expect(p, contains('曲名=春风吹'));
      expect(p, contains('拍号=4/4'));
      expect(p, contains('钢琴双行谱'));
      // 通用提示词（节奏/八度那两节）必须还在
      expect(p, contains('减时线'));
      expect(p, contains('八度'));
    });

    test('单行旋律谱：明确说歌词不是音符、只输出 v1', () {
      final p = aiLinePrompt(index: 0, total: 3, layout: ScoreLayoutMode.singleLine);
      expect(p, contains('单行旋律谱'));
      expect(p, contains('歌词'));
      expect(p, contains('只输出 v1'));
      expect(p, contains('绝对不要输出 v2'));
    });

    test('没有页眉信息时不写"已知信息"那句', () {
      final p = aiLinePrompt(index: 0, total: 3, layout: ScoreLayoutMode.singleLine);
      expect(p, isNot(contains('本曲已知信息')));
    });
  });

  group('切行（版面分析）', () {
    /// 造一张"三行简谱 + 标题"的假谱页：每行数字很大，行间距也大
    GrayImage syntheticPage() {
      const w = 700, h = 900;
      final d = Uint8List(w * h)..fillRange(0, w * h, 255);
      void rect(int x0, int y0, int cw, int ch) {
        for (var y = y0; y < y0 + ch && y < h; y++) {
          for (var x = x0; x < x0 + cw && x < w; x++) {
            d[y * w + x] = 0;
          }
        }
      }

      // 标题（细窄的一小条）
      rect(250, 40, 200, 26);
      // 三行"数字"：每行 8 个方块，行间留足空白
      for (var row = 0; row < 3; row++) {
        final y = 180 + row * 220;
        for (var i = 0; i < 8; i++) {
          rect(60 + i * 76, y, 34, 48);
        }
      }
      return GrayImage(w, h, d);
    }

    test('切成标题区 + 3 组谱行，且每段都带在整页里的 y 范围', () {
      final gray = syntheticPage();
      final split = splitPageStrips(gray);
      expect(split.systemCount, 3, reason: '应当认出 3 组谱行');
      expect(split.strips.where((s) => s.header).length, 1, reason: '顶部标题区应当单独一张');
      final systems = split.strips.where((s) => !s.header).toList();
      expect(systems.length, 3);
      // y 递增
      for (var i = 1; i < systems.length; i++) {
        expect(systems[i].y0, greaterThan(systems[i - 1].y1));
      }
      // 每张图都是有内容的（二值图里必须有黑点）
      for (final s in systems) {
        final ink = s.bin.d.where((v) => v != 0).length;
        expect(ink, greaterThan(200), reason: '第 ${s.groupIndex} 段不该是空图');
        expect(s.bin.h, greaterThan(20));
      }
    });

    test('单行谱只切出一组（调用方会因此退回整页识别）', () {
      const w = 400, h = 200;
      final d = Uint8List(w * h)..fillRange(0, w * h, 255);
      for (var y = 80; y < 128; y++) {
        for (var x = 40; x < 360; x++) {
          d[y * w + x] = 0;
        }
      }
      final split = splitPageStrips(GrayImage(w, h, d));
      expect(split.systemCount, 1);
      expect(split.strips.where((s) => !s.header).length, 1);
    });

    test('切出来的图能编码成 PNG（发给模型的那一步）', () async {
      final split = splitPageStrips(syntheticPage());
      final png = await binToPng(split.strips.first.bin);
      expect(png.length, greaterThan(100));
      // PNG magic
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, split.strips.first.bin.w);
      expect(frame.image.height, split.strips.first.bin.h);
    });
  });

  group('AI 判版面（结构解析与吸附）', () {
    test('解析 layout / systems / 曲名 / 调号', () {
      final st = AiPageStructure.fromRaw(
        '{"title":"二十二","key":"1=F","layout":"single",'
        '"systems":[{"rows":1,"y0":0.05,"y1":0.13},{"rows":1,"y0":0.16,"y1":0.24}]}',
      );
      expect(st.layout, 'single');
      expect(st.title, '二十二');
      expect(st.keyRaw, '1=F');
      expect(st.systems.length, 2);
      expect(st.systems.first.rows, 1);
      expect(st.dominantMode, ScoreLayoutMode.singleLine);
    });

    test('双行谱：rows=2 判成钢琴谱', () {
      final st = AiPageStructure.fromRaw(
        '{"layout":"grand","systems":[{"rows":2,"y0":0.3,"y1":0.45},{"rows":2,"y0":0.5,"y1":0.65}]}',
      );
      expect(st.dominantMode, ScoreLayoutMode.grandStaff);
    });

    test('坐标给成 0~100 也能吃（自动除以 100）', () {
      final st = AiPageStructure.fromRaw('{"systems":[{"rows":1,"y0":5,"y1":13}]}');
      expect(st.systems.single.y0, closeTo(0.05, 1e-9));
      expect(st.systems.single.y1, closeTo(0.13, 1e-9));
    });

    test('乱七八糟的返回不会崩，也不会造出空结构之外的东西', () {
      expect(AiPageStructure.fromRaw('不是 JSON').isEmpty, isTrue);
      final st = AiPageStructure.fromRaw('{"systems":[{"rows":1}]}'); // 没有 y
      expect(st.isEmpty, isTrue);
    });

    test('吸附：AI 说 2 行就取 2 行，剩下的行单独成段（一行都不能丢）', () {
      final rows = [
        AiStripImage(Uint8List.fromList([1]), false, 0, 100, 140), // 中心 120
        AiStripImage(Uint8List.fromList([1]), false, 1, 150, 300), // 中心 225
        AiStripImage(Uint8List.fromList([1]), false, 2, 400, 440), // 中心 420
        AiStripImage(Uint8List.fromList([1]), false, 3, 450, 600), // 中心 525
        AiStripImage(Uint8List.fromList([1]), false, 4, 700, 740), // 中心 720（没被认领）
      ];
      final split = AiPageSplit(rows, 3, const [],
          bands: [(100, 140), (150, 300), (400, 440), (450, 600), (700, 740)]);
      // 只认了前两组（每组 2 行），第 5 行没被认领
      final st = AiPageStructure.fromRaw(
        '{"layout":"grand","systems":[{"rows":2,"y0":0.13,"y1":0.40},{"rows":2,"y0":0.50,"y1":0.80}]}',
      );
      final segs = snapStructureToRows(st, split);
      expect(segs.length, 3, reason: '两组 + 一个没认领的行');
      expect(segs[0].length, 2);
      expect(segs[1].length, 2);
      expect(segs[2].length, 1);
      // 顺序必须还是从上到下
      expect(segs[0].first.y0, 100);
      expect(segs[2].first.y0, 700);
    });
  });

  group('调号与谱号', () {
    test('换调号重算音高（多页统一调号用）', () {
      final ai = parseAiNotes('{"key":"1=C","beats":4,"beatType":4,"v1":[[1,0,0,1],[5,0,1,1]]}')!;
      final c1 = ai.notes.first.midi;
      final f = rekeyAiScore(ai, '1=F');
      expect(f.keyName, 'F');
      // 1=C 的 do 到 1=F 的 do：正好高 5 个半音（C→F）
      expect(f.notes.first.midi - c1, 5);
    });

    test('单行旋律谱用中位音选谱号：一个跑偏的低音不会把整页翻成低音谱', () {
      // 大部分音在中央 C 一带，只有一个音被读低了两个八度
      final ai = parseAiNotes(
        '{"key":"1=C","beats":4,"beatType":4,"v1":[[1,0,0,1],[2,0,1,1],[3,0,2,1],[4,0,3,1],[1,-2,4,1]]}',
      )!;
      final single = scoreFromAiNotes(ai, singleLineLayout: true);
      expect(single.meta.clef, 'treble');
      // 不做版面判断时，老算法（最低+最高取中）会被那个低八度带成低音谱
      final unknown = scoreFromAiNotes(ai);
      expect(unknown.meta.clef, 'bass');
    });

    test('双行谱一定用大谱表', () {
      final ai = parseAiNotes(
        '{"key":"1=C","beats":4,"beatType":4,"v1":[[1,0,0,4]],"v2":[[1,-2,0,4]]}',
      )!;
      final score = scoreFromAiNotes(ai, singleLineLayout: false);
      expect(score.isGrandStaff, isTrue);
      expect(score.meta.clef, 'grand');
    });
  });

  group('并发工具', () {
    test('限量并发：结果顺序与输入一致，且确实并发过', () async {
      var running = 0;
      var maxRunning = 0;
      final out = await mapConcurrent<int, int>(
        List<int>.generate(10, (i) => i),
        3,
        (v, i) async {
          running++;
          maxRunning = math.max(maxRunning, running);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          running--;
          return v * 2;
        },
      );
      expect(out, List<int>.generate(10, (i) => i * 2));
      expect(maxRunning, lessThanOrEqualTo(3));
      expect(maxRunning, greaterThan(1), reason: '应当真的并发');
    });

    test('limit 大于任务数时不会卡住', () async {
      final out = await mapConcurrent<int, int>([1], 8, (v, i) async => v + 1);
      expect(out, [2]);
    });
  });
}
