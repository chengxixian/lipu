/// 谱面直接编辑：拖音符改音高 / 改位置 / 改时值 + 撤销，以及 MusicXML 的 id 映射
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/state.dart';

/// 声部里第 [index] 个音符的起点（ticks）
double startOf(List<Item> items, int index) {
  var t = 0.0;
  for (var i = 0; i < index; i++) {
    t += items[i].ticks;
  }
  return t;
}

int pitchAt(List<Item> items, int index, KeyInfo ki) {
  final n = items[index] as NoteItem;
  return notePitches(n, ki).first.midi;
}

void main() {
  group('音符 id 映射', () {
    test('id 能解析回 小节/声部/条目/音', () {
      final ref = AppState.parseNoteId('lipu-3-2-7-1-0');
      expect(ref, isNotNull);
      expect(ref!.measure, 3);
      expect(ref.voice, 2);
      expect(ref.item, 7);
      expect(ref.tone, 1);
      expect(AppState.parseNoteId('nonsense'), isNull);
      expect(AppState.parseNoteId('lipu-1-1-1'), isNull);
    });

    test('生成的 MusicXML 里每个音都带 id，且能对上结构', () {
      final score = parseJianpu('1=C 4/4\n[1 3 5] 2 3 4 |]');
      final xml = toMusicXML(score);
      // 第 0 小节、声部 1、第 0 个条目（和弦，3 个音）、音序号 0/1/2
      expect(xml, contains('id="lipu-0-1-0-0-0"'));
      expect(xml, contains('id="lipu-0-1-0-1-0"'));
      expect(xml, contains('id="lipu-0-1-0-2-0"'));
      // 第 3 个条目是第 4 个音
      expect(xml, contains('id="lipu-0-1-3-0-0"'));
      // 大谱表第二声部用 voice=2
      final grand = parseJianpu('1=C 4/4\n高音: 1 2 3 4 |\n低音: 1,, - - - |');
      expect(toMusicXML(grand), contains('id="lipu-0-2-0-0-0"'));
    });
  });

  group('拖动改音高', () {
    test('单个音改音级/八度', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      expect(pitchAt(state.score!.measures[0].items, 1, state.score!.key), 62); // 2 = D4

      state.moveNotePitch('lipu-0-1-1-0-0', 5, 0, ''); // 改成 5 = G4
      expect(pitchAt(state.score!.measures[0].items, 1, state.score!.key), 67);
      expect(state.text, contains('1 5 3 4'));
      expect(state.canUndo, isTrue);
    });

    test('和弦里可以只改一个音，其它音不动', () {
      final state = AppState();
      state.setText('1=C 4/4\n[1 3 5] 0 0 0 |]', immediate: true);
      final item = state.score!.measures[0].items.first as NoteItem;
      expect(notePitches(item, state.score!.key).map((p) => p.midi).toList(), [60, 64, 67]);

      // 把中间那个音（3=E4）改成 6=A4
      state.moveNotePitch('lipu-0-1-0-1-0', 6, 0, '');
      final after = state.score!.measures[0].items.first as NoteItem;
      expect(notePitches(after, state.score!.key).map((p) => p.midi).toList(), [60, 67, 69],
          reason: 'C4 / G4 / A4，主音仍是最低的 C4');
      expect(after.degree, 1, reason: '主音不变');
    });

    test('越界 id 不会崩', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.moveNotePitch('lipu-99-1-0-0-0', 5, 0, '');
      state.moveNotePitch('lipu-0-9-0-0-0', 5, 0, '');
      state.moveNotePitch('garbage', 5, 0, '');
      expect(state.score!.measures[0].items.length, 4);
    });
  });

  group('拖动改位置', () {
    test('往后挪一格会补出休止符，小节总时值不变', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      final before = state.score!.measures[0].filled;
      expect(before, 4);

      // 第一个音（四分音符）往后挪一拍 = 4 个十六分网格
      state.moveNoteStart('lipu-0-1-0-0-0', 4);
      final items = state.score!.measures[0].items;
      expect(state.score!.measures[0].filled, 4, reason: '小节总时值必须保持 4');
      expect(items.first, isA<RestItem>(), reason: '空出来的位置补休止符');
      expect(startOf(items, 1), 1.0);
      expect(pitchAt(items, 1, state.score!.key), 60, reason: '音高不变');
    });

    test('往前挪：被压到的内容被截断，小节长度不变', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      // 把第 3 个音（index 2，起点 2 拍）往前挪到 1 拍的位置
      state.moveNoteStart('lipu-0-1-2-0-0', -4);
      final items = state.score!.measures[0].items;
      expect(state.score!.measures[0].filled, 4, reason: '总时值不变');
      expect(startOf(items, 1), 1.0);
      expect(pitchAt(items, 1, state.score!.key), 64, reason: '被挪的是原来第 3 个音（3=E4）');
      // 原来第 2 个音（2=D4，占 1~2 拍）被压掉
      final pitches = [
        for (var i = 0; i < items.length; i++)
          if (items[i] is NoteItem) pitchAt(items, i, state.score!.key),
      ];
      expect(pitches, isNot(contains(62)), reason: '被覆盖的 D4 应当被吃掉');
    });

    test('挪到负数/超出都会被夹住，小节长度不变', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.moveNoteStart('lipu-0-1-0-0-0', -99);
      expect(state.score!.measures[0].filled, 4);
      final items = state.score!.measures[0].items;
      expect(pitchAt(items, 0, state.score!.key), 60, reason: '已经在开头就不再前移');

      state.moveNoteStart('lipu-0-1-3-0-0', 99);
      expect(state.score!.measures[0].filled, 4);
    });
  });

  group('改时值（几分音符）', () {
    test('变短会补休止符，小节总时值不变', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.setNoteDuration('lipu-0-1-0-0-0', 0.5); // 四分 -> 八分
      final items = state.score!.measures[0].items;
      expect(state.score!.measures[0].filled, 4);
      expect(items[0].ticks, 0.5);
      expect(items[1], isA<RestItem>());
      expect(items[1].ticks, 0.5);
      expect(state.text, contains('1/'));
    });

    test('变长会吃掉后面的音，小节总时值不变', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.setNoteDuration('lipu-0-1-0-0-0', 2); // 四分 -> 二分
      final items = state.score!.measures[0].items;
      expect(state.score!.measures[0].filled, 4);
      expect(items[0].ticks, 2);
      // 第二个音（1 拍）被整个吃掉
      expect(items.length, 3, reason: '原来 4 个音：第 1 个变 2 拍，吃掉第 2 个，剩 3 个');
      expect(pitchAt(items, 1, state.score!.key), 64, reason: '接着是原来的第 3 个音（3）');
    });

    test('超出小节剩余空间会被夹住', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.setNoteDuration('lipu-0-1-3-0-0', 8); // 最后一个音想变全音符
      expect(state.score!.measures[0].filled, 4);
      expect(state.score!.measures[0].items.last.ticks, 1, reason: '只到小节末尾');
    });
  });

  group('撤销', () {
    test('撤销能回到上一步，并且模型与文本都回退', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      final before = state.text;

      state.moveNotePitch('lipu-0-1-0-0-0', 5, 0, '');
      expect(state.text, isNot(before));

      state.undo();
      expect(state.text, before);
      expect(pitchAt(state.score!.measures[0].items, 0, state.score!.key), 60);
      expect(state.canUndo, isFalse);
    });

    test('连续多次编辑可以逐步撤销', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      final t0 = state.text;
      state.moveNotePitch('lipu-0-1-0-0-0', 5, 0, '');
      final t1 = state.text;
      state.setNoteDuration('lipu-0-1-1-0-0', 2);
      final t2 = state.text;
      expect(t1, isNot(t0));
      expect(t2, isNot(t1));

      state.undo();
      expect(state.text, t1);
      state.undo();
      expect(state.text, t0);
    });
  });

  group('拖动一步到位（nudgeNote）', () {
    test('同时改音高和位置只压一次撤销', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      final t0 = state.text;

      // 往上两级（2 → 4），往右一格
      state.nudgeNote('lipu-0-1-1-0-0', stepDelta: 2, gridDelta: 1);
      final items = state.score!.measures[0].items;
      final midis = <int>[];
      for (var i = 0; i < items.length; i++) {
        if (items[i] is NoteItem) midis.add(pitchAt(items, i, state.score!.key));
      }
      expect(midis, contains(65), reason: '2 升两级 = 4(F4)：${state.text}');
      expect(state.canUndo, isTrue);

      state.undo();
      expect(state.text, t0);
      expect(state.canUndo, isFalse, reason: '一次拖动只应该是一步撤销');
    });

    test('音级跨八度：7 再往上要进八度、1 再往下要退八度', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      // 第 3 个音是 4，往上 4 级 → 7 再 +1 就是高八度的 1
      state.nudgeNote('lipu-0-1-3-0-0', stepDelta: 4);
      final up = state.score!.measures[0].items[3] as NoteItem;
      expect(up.degree, 1);
      expect(up.octave, 1, reason: '4 往上 4 级 = 高八度的 1');
      expect(pitchAt(state.score!.measures[0].items, 3, state.score!.key), 72);

      final state2 = AppState();
      state2.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state2.nudgeNote('lipu-0-1-0-0-0', stepDelta: -1);
      final down = state2.score!.measures[0].items[0] as NoteItem;
      expect(down.degree, 7);
      expect(down.octave, -1, reason: '1 往下 1 级 = 低八度的 7');
    });

    test('和弦里只拖某一个音，其它音不动', () {
      final state = AppState();
      state.setText('1=C 4/4\n[1 3 5] 0 0 0 |]', immediate: true);
      state.nudgeNote('lipu-0-1-0-1-0', stepDelta: 1); // 中间那个 3 → 4
      final item = state.score!.measures[0].items.first as NoteItem;
      expect(notePitches(item, state.score!.key).map((p) => p.midi).toList(), [60, 65, 67]);
    });

    test('位置拖出小节范围时会被夹住，不产生时值告警', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.nudgeNote('lipu-0-1-0-0-0', gridDelta: -40);
      state.nudgeNote('lipu-0-1-3-0-0', gridDelta: 40);
      final score = state.score!;
      expect(score.measures[0].filled, 4);
      expect(score.meta.warnings.where((w) => w.contains('时值')), isEmpty,
          reason: '${score.meta.warnings}');
    });

    test('拖到没动（增量都是 0）不该污染撤销栈', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.nudgeNote('lipu-0-1-0-0-0');
      expect(state.canUndo, isFalse);
    });
  });

  group('气泡菜单里的四项功能', () {
    test('连音：连到下一个音，两端都要写进 MusicXML', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      final before = toMusicXML(state.score!);
      expect(RegExp(r'<tie ').allMatches(before).length, 0);

      final keep = state.toggleTie('lipu-0-1-0-0-0');
      expect(keep, 'lipu-0-1-0-0-0');
      final items = state.score!.measures[0].items;
      expect((items[0] as NoteItem).tieToNext, isTrue);
      expect((items[1] as NoteItem).tieToPrev, isTrue,
          reason: '下一个音要标上"从前面连过来"');
      final xml = toMusicXML(state.score!);
      // 一个 start 一个 stop：少写哪个谱面上都画不出连音线
      expect(RegExp(r'<tie type="start"/>').allMatches(xml).length, 1);
      expect(RegExp(r'<tie type="stop"/>').allMatches(xml).length, 1);

      state.toggleTie('lipu-0-1-0-0-0');
      expect((state.score!.measures[0].items[0] as NoteItem).tieToNext, isFalse,
          reason: '再点一次取消');
      expect((state.score!.measures[0].items[1] as NoteItem).tieToPrev, isFalse);
    });

    test('插入：在音符后面插一个同样的音，小节长度不变（末尾被挤掉）', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      final id = state.insertAfter('lipu-0-1-0-0-0');
      expect(id, isNotNull);
      final items = state.score!.measures[0].items;
      expect(items.length, 4, reason: '小节满了：插一个就挤掉末尾一个');
      expect((items[0] as NoteItem).degree, 1);
      expect((items[1] as NoteItem).degree, 1, reason: '插入的是同一个音');
      expect((items[2] as NoteItem).degree, 2);
      expect(state.score!.measures[0].filled, 4);
      expect(state.text, contains('1 1 2 3'));
      expect(id, 'lipu-0-1-1-0-0', reason: '新条目在第二个位置');
    });

    test('插入休止符：占掉后面的位置', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.insertAfter('lipu-0-1-0-0-0', asRest: true);
      final items = state.score!.measures[0].items;
      expect(items[1], isA<RestItem>());
      expect(state.score!.measures[0].filled, 4);
    });

    test('插入：小节没满时只是变长，总时值增加', () {
      final state = AppState();
      // 4/4 里只有两个四分音符 = 小节没满
      state.setText('1=C 4/4\n1 2 |]', immediate: true);
      final before = state.score!.measures[0].filled;
      expect(before, closeTo(2.0, 1e-6));
      state.insertAfter('lipu-0-1-0-0-0');
      expect(state.score!.measures[0].filled, closeTo(before + 1.0, 1e-6),
          reason: '没满的时候插入应该让小节变长');
      expect((state.score!.measures[0].items[1] as NoteItem).degree, 1);
    });

    test('升降调：♯ / ♭ / 还原（符号写在音符前面，并写进 MusicXML）', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.setToneAccidental('lipu-0-1-0-0-0', '#');
      expect((state.score!.measures[0].items[0] as NoteItem).accidental, '#');
      expect(state.text, contains('#1'), reason: '简谱文本里升号写在数字前面');
      final xml = toMusicXML(state.score!);
      expect(xml, contains('<accidental>sharp</accidental>'),
          reason: 'MusicXML 要有升号，谱面上才画得出 ♯');
      state.setToneAccidental('lipu-0-1-0-0-0', 'b');
      expect((state.score!.measures[0].items[0] as NoteItem).accidental, 'b');
      state.setToneAccidental('lipu-0-1-0-0-0', '');
      expect((state.score!.measures[0].items[0] as NoteItem).accidental, '');
      // 音高确实变了（#1 比 1 高半音）
      state.setToneAccidental('lipu-0-1-0-0-0', '#');
      expect(pitchAt(state.score!.measures[0].items, 0, state.score!.key), 61);
      expect(state.canUndo, isTrue);
    });

    test('和弦：反复点会按三度叠置往上加音', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.addChordTone('lipu-0-1-0-0-0');
      var item = state.score!.measures[0].items[0] as NoteItem;
      expect(item.isChord, isTrue);
      expect(notePitches(item, state.score!.key).map((p) => p.midi).toList(), [60, 64],
          reason: '1 上面加三度 = 3（E4）');
      state.addChordTone('lipu-0-1-0-0-0');
      item = state.score!.measures[0].items[0] as NoteItem;
      expect(notePitches(item, state.score!.key).map((p) => p.midi).toList(), [60, 64, 67],
          reason: '再点一次得到 1-3-5');
      expect(state.text, contains('[1 3 5]'));
      expect(toMusicXML(state.score!), contains('<chord/>'));
      // 重复点不会加出重复音
      final before = notePitches(item, state.score!.key).length;
      state.addChordTone('lipu-0-1-0-0-0');
      state.addChordTone('lipu-0-1-0-0-0');
      expect(notePitches(state.score!.measures[0].items[0] as NoteItem, state.score!.key).length,
          lessThanOrEqualTo(before + 2));
    });

    test('删除：音符变成休止符，小节长度不变', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      final before = state.score!.measures[0].filled;
      final keep = state.deleteNote('lipu-0-1-1-0-0');
      expect(keep, isNull, reason: '音符没了，不该再选中什么');
      final items = state.score!.measures[0].items;
      expect(items[1], isA<RestItem>(), reason: '被删的位置留成休止符');
      expect(items[1].ticks, 1.0);
      expect(state.score!.measures[0].filled, closeTo(before, 1e-6));
      expect(state.text, contains('0'), reason: '简谱文本里应当是休止符');
      state.undo();
      expect(state.score!.measures[0].items[1], isA<NoteItem>(), reason: '撤销要能还原');
    });

    test('连音选两个音：同音高相邻 → 连音线（tie）', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 1 3 4 |]', immediate: true);
      final keep = state.tieBetween('lipu-0-1-0-0-0', 'lipu-0-1-1-0-0');
      expect(keep, 'lipu-0-1-1-0-0', reason: '连完选中终点，方便接着改');
      final items = state.score!.measures[0].items;
      expect((items[0] as NoteItem).tieToNext, isTrue);
      expect((items[1] as NoteItem).tieToPrev, isTrue);
      expect((items[0] as NoteItem).slurToNext, isFalse);
      final xml = toMusicXML(state.score!);
      expect(RegExp(r'<tie type="start"/>').allMatches(xml).length, 1);
      expect(RegExp(r'<tie type="stop"/>').allMatches(xml).length, 1);
    });

    test('连音选两个音：音高不同 → 圆滑线（slur），也必须画得出来', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      state.tieBetween('lipu-0-1-0-0-0', 'lipu-0-1-1-0-0'); // 1 和 2，音高不同
      final items = state.score!.measures[0].items;
      expect((items[0] as NoteItem).tieToNext, isFalse,
          reason: '音高不同不能写成 tie（无效，排版引擎不会画）');
      expect((items[0] as NoteItem).slurToNext, isTrue);
      expect((items[1] as NoteItem).slurToPrev, isTrue);
      final xml = toMusicXML(state.score!);
      expect(xml, contains('<slur type="start" number="1"/>'));
      expect(xml, contains('<slur type="stop" number="1"/>'));
      expect(RegExp(r'<tie ').allMatches(xml).length, 0);
    });

    test('连音选两个音：同音高但中间隔着别的音 → 圆滑线', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 3 1 4 |]', immediate: true);
      state.tieBetween('lipu-0-1-0-0-0', 'lipu-0-1-2-0-0'); // 两个 1，但中间有个 3
      final items = state.score!.measures[0].items;
      expect((items[0] as NoteItem).slurToNext, isTrue,
          reason: '中间隔着音，tie 排不出来，要用圆滑线');
      expect(toMusicXML(state.score!), contains('<slur type="start" number="1"/>'));
    });

    test('跨小节的同音相连 → 仍然是连音线（tie）', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 | 1 2 3 4 |]', immediate: true);
      // 第一小节最后一个音是 4，第二小节第一个音是 1：音高不同 → 圆滑线
      state.tieBetween('lipu-0-1-3-0-0', 'lipu-1-1-0-0-0');
      expect((state.score!.measures[0].items[3] as NoteItem).slurToNext, isTrue);
      state.undo();
      // 把第一小节末尾改成 1，再和第二小节开头的 1 连（同音高、跨小节相邻）
      state.setText('1=C 4/4\n1 2 3 1 | 1 2 3 4 |]', immediate: true);
      state.tieBetween('lipu-0-1-3-0-0', 'lipu-1-1-0-0-0');
      expect((state.score!.measures[0].items[3] as NoteItem).tieToNext, isTrue,
          reason: '跨小节相邻的同音应当写成 tie');
      expect((state.score!.measures[1].items[0] as NoteItem).tieToPrev, isTrue);
    });

    test('三项操作都能撤销', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
      final t0 = state.text;
      state.toggleTie('lipu-0-1-0-0-0');
      final t1 = state.text;
      state.insertAfter('lipu-0-1-0-0-0');
      final t2 = state.text;
      state.setToneAccidental('lipu-0-1-0-0-0', '#');
      expect(state.text, isNot(t2));
      state.undo();
      expect(state.text, t2);
      state.undo();
      expect(state.text, t1);
      state.undo();
      expect(state.text, t0);
    });
  });

  group('编辑后仍然是一份能用的乐谱', () {
    test('改完能导出 MusicXML / 简谱往返，小节时值自洽', () {
      final state = AppState();
      state.setText('1=C 4/4\n1 2 3 4 | 5 5 5 5 |]', immediate: true);
      state.moveNotePitch('lipu-0-1-0-0-0', 3, 0, '');
      state.setNoteDuration('lipu-0-1-1-0-0', 2);
      state.moveNoteStart('lipu-1-1-0-0-0', 2);

      final score = state.score!;
      expect(score.meta.warnings.where((w) => w.contains('时值')), isEmpty,
          reason: '编辑不应该产生小节时值问题：${score.meta.warnings}');
      final xml = toMusicXML(score);
      expect(xml, contains('<score-partwise'));
      final again = parseJianpu(state.text);
      expect(again.pitchCount, score.pitchCount);
    });
  });
}
