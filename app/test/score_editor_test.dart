/// 乐谱页内嵌编辑器：改动要能即时重排五线谱
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/state.dart';
import 'package:jianpu_app/ui/score_editor.dart';

Future<void> pumpEditor(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: ScoreEditorPanel(state: state, onClose: () {})),
  ));
  await tester.pump(const Duration(milliseconds: 400)); // 让 AppState 的防抖解析跑完
}

void main() {
  testWidgets('改文本会重新解析成乐谱（防抖后）', (tester) async {
    final state = AppState();
    await pumpEditor(tester, state);

    await tester.enterText(find.byType(TextField), '1=C 4/4\n1 2 3 4 |]');
    await tester.pump(const Duration(milliseconds: 500));

    expect(state.text, '1=C 4/4\n1 2 3 4 |]');
    expect(state.score, isNotNull);
    expect(state.score!.measures.length, 1);
    expect(state.score!.pitchCount, 4);
  });

  testWidgets('能和弦与两个声部一起编辑', (tester) async {
    final state = AppState();
    await pumpEditor(tester, state);

    await tester.enterText(
      find.byType(TextField),
      "1=C 4/4\n高音: [1 3 5] [4 6 1'] [5 7 2'] [1 3 5] |\n低音: 1,, - - - |",
    );
    await tester.pump(const Duration(milliseconds: 500));

    final score = state.score!;
    expect(score.isGrandStaff, isTrue, reason: '两个声部应当排成大谱表');
    expect(score.measures.first.items2, isNotEmpty, reason: '低音谱要有内容');
    final chord = score.measures.first.items.whereType<Object>().isNotEmpty;
    expect(chord, isTrue);
    expect(score.pitchCount, greaterThan(10));
  });

  testWidgets('示例按钮会把示例谱子填进来', (tester) async {
    final state = AppState();
    await pumpEditor(tester, state);

    await tester.enterText(find.byType(TextField), '1=C 4/4\n5 5 5 5 |]');
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.text, contains('5 5 5 5'));

    await tester.tap(find.text('示例：小星星'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.text, contains('小星星'));
    expect(state.score!.measures.length, greaterThan(4));

    await tester.tap(find.text('示例：茉莉花'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.text, contains('茉莉花'));
  });

  testWidgets('语法速查可以展开收起', (tester) async {
    final state = AppState();
    await pumpEditor(tester, state);

    expect(find.textContaining('减时线'), findsNothing);
    await tester.tap(find.widgetWithText(ActionChip, '语法'), warnIfMissed: false);
    await tester.pump();
    expect(find.textContaining('减时线'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, '语法'), warnIfMissed: false);
    await tester.pump();
    expect(find.textContaining('减时线'), findsNothing);
  });

  testWidgets('外部改了谱子（比如重新识谱）会把编辑器同步过去', (tester) async {
    final state = AppState();
    await pumpEditor(tester, state);

    state.setText('1=D 3/4\n3 3 5 | 6 - - |]', immediate: true);
    await tester.pump(const Duration(milliseconds: 100));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, contains('1=D 3/4'));
    expect(state.score!.meta.beats, 3);
  });
}
