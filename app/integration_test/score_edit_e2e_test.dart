/// 端到端测试：**在真实 WebView 里用鼠标拖动音符改谱**。
///
/// 单元测试只能覆盖 Dart 那一半（AppState 的改谱 API），而"点音符 → 拖动 →
/// 松手 → 重排"这条链路全在 WebView 的 JS 里。这里 dispatch 真正的
/// PointerEvent，把整条链路走一遍：
///   命中音符 → 选中高亮 → 拖动预览 → 松手回传增量 → 改模型 → 重排
///   → 二次点击进时值模式 → 点"二分"改时值 → 撤销
///
/// 跑法（必须先建好插件 junction，见 tool/make-plugin-junctions.ps1）：
///   flutter test integration_test/score_edit_e2e_test.dart -d windows
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/musicxml.dart';
import 'package:jianpu_app/render/verovio_view.dart';
import 'package:jianpu_app/state.dart';
import 'package:jianpu_app/ui/score_view.dart';

/// 等到 [test] 为真或超时；返回是否等到了
Future<bool> waitFor(WidgetTester tester, bool Function() test,
    {Duration timeout = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return true;
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return test();
}

Future<String> js(VerovioController vrv, String source) async {
  final r = await vrv.web?.evaluateJavascript(source: source);
  return r?.toString() ?? '';
}

/// 页面里所有 `lipu-` 前缀的音符 id
Future<List<String>> noteIds(VerovioController vrv, String voice) async {
  final raw = await js(vrv,
      '''JSON.stringify(Array.prototype.map.call(document.querySelectorAll('g.note[id^="lipu-0-$voice-"]'), function (n) { return n.id; }))''');
  try {
    return (jsonDecode(raw) as List).cast<String>();
  } catch (_) {
    return const [];
  }
}

/// 反复取 id 直到非空（渲染是异步的，setText 之后不能只看一个瞬间）
Future<List<String>> waitIds(WidgetTester tester, VerovioController vrv, String voice,
    {Duration timeout = const Duration(seconds: 45)}) async {
  final deadline = DateTime.now().add(timeout);
  var last = <String>[];
  while (DateTime.now().isBefore(deadline)) {
    last = await noteIds(vrv, voice);
    if (last.isNotEmpty) return last;
    await tester.pump(const Duration(milliseconds: 120));
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
  return last;
}

/// 在音符中心"点一下"（按下即抬起、完全不移动）——手机上就是一次轻点
String tapJs(String id) => '''
(function () {
  var g = document.getElementById("$id");
  if (!g) { return JSON.stringify({ error: "no-note" }); }
  var head = g.querySelector("use, path, ellipse") || g;
  var r = head.getBoundingClientRect();
  var x = r.left + r.width / 2, y = r.top + r.height / 2;
  function mk(type) {
    return new PointerEvent(type, { clientX: x, clientY: y, bubbles: true,
      cancelable: true, pointerId: 1, pointerType: "touch", isPrimary: true, buttons: 1 });
  }
  g.dispatchEvent(mk("pointerdown"));
  g.dispatchEvent(mk("pointerup"));
  return JSON.stringify({ x: Math.round(x), y: Math.round(y) });
})();
''';

/// 用手指拖动（pointerType=touch）：验证"一级/一格"的触摸步长下限
String touchDragJs(String id, {required double dx, required double dy}) => '''
(function () {
  var g = document.getElementById("$id");
  if (!g) { return JSON.stringify({ error: "no-note" }); }
  var head = g.querySelector("use, path, ellipse") || g;
  var r = head.getBoundingClientRect();
  var x = r.left + r.width / 2, y = r.top + r.height / 2;
  function mk(type, xx, yy) {
    return new PointerEvent(type, { clientX: xx, clientY: yy, bubbles: true,
      cancelable: true, pointerId: 4, pointerType: "touch", isPrimary: true, buttons: 1 });
  }
  g.dispatchEvent(mk("pointerdown", x, y));
  g.dispatchEvent(mk("pointermove", x + $dx, y + $dy));
  g.dispatchEvent(mk("pointermove", x + $dx * 1.5, y + $dy * 1.5));
  var tipEl = document.querySelector("g.vrv-tip text");
  var text = tipEl ? tipEl.textContent : "";
  g.dispatchEvent(mk("pointerup", x + $dx * 1.5, y + $dy * 1.5));
  return JSON.stringify({ hint: text, tip: text });
})();
''';

/// 在右侧竖条上"上下滑"到某一档（按 data-t 找到那一行，滑过去再松手）
String slideDurJs(String dataT) => '''
(function () {
  var bar = document.getElementById("durbar");
  if (!bar) { return JSON.stringify({ error: "no-bar" }); }
  var rows = bar.querySelectorAll(".tick");
  var target = null;
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].getAttribute("data-t") === "$dataT") { target = rows[i]; }
  }
  if (!target) { return JSON.stringify({ error: "no-tick", rows: rows.length }); }
  var r = target.getBoundingClientRect();
  var x = r.left + r.width / 2, y = r.top + r.height / 2;
  function mk(type, yy) {
    return new PointerEvent(type, { clientX: x, clientY: yy, bubbles: true,
      cancelable: true, pointerId: 5, pointerType: "touch", isPrimary: true, buttons: 1 });
  }
  var top = bar.getBoundingClientRect().top + 6;
  bar.dispatchEvent(mk("pointerdown", top));
  bar.dispatchEvent(mk("pointermove", (top + y) / 2));
  bar.dispatchEvent(mk("pointermove", y));
  var hovered = bar.querySelectorAll(".tick.hover").length;
  // 真实浏览器：pointerup 落在手指底下的那一行上，再冒泡到 window
  target.dispatchEvent(mk("pointerup", y));
  return JSON.stringify({ y: Math.round(y), rows: rows.length, hovered: hovered });
})();
''';

/// 点气泡菜单里的某一项（按 data-act 或 data-acc 找）。
///
/// [via] 决定派发哪条事件链，默认 **pointer**（只发 pointerdown + pointerup，
/// **不发 click**）——安卓 WebView 上手势一多 click 就容易被吞掉，
/// 所以按钮必须不依赖 click 也能用。`touch` 走 touchstart + 容器 touchend 兜底，
/// `click` 是桌面鼠标那条路。
String bubblePickJs(String key, {bool acc = false, String via = 'pointer', int holdMs = 0}) => '''
(function () {
  var b = document.getElementById("bubble");
  if (!b || !b.classList.contains("show")) { return JSON.stringify({ error: "no-bubble" }); }
  var opts = b.querySelectorAll(".opt");
  var target = null;
  for (var i = 0; i < opts.length; i++) {
    if (opts[i].getAttribute("${acc ? 'data-acc' : 'data-act'}") === "$key") { target = opts[i]; }
  }
  if (!target) {
    return JSON.stringify({ error: "no-option", opts: Array.prototype.map.call(opts, function (o) {
      return o.getAttribute("data-act") + "/" + o.getAttribute("data-acc"); }) });
  }
  var r = target.getBoundingClientRect();
  var x = r.left + r.width / 2, y = r.top + r.height / 2;
  function pev(type) {
    return new PointerEvent(type, { clientX: x, clientY: y, bubbles: true,
      cancelable: true, pointerId: 11, pointerType: "touch", isPrimary: true, buttons: 1 });
  }
  var how = "$via";
  var hold = $holdMs;
  function finish() {
    if (how === "touch") {
      function tev(type, el) {
        var t = new Touch({ identifier: 1, target: el, clientX: x, clientY: y });
        el.dispatchEvent(new TouchEvent(type, {
          touches: type === "touchend" ? [] : [t], changedTouches: [t],
          bubbles: true, cancelable: true }));
      }
      tev("touchstart", target);
      tev("touchend", b);            // 容器兜底：按坐标找选项
    } else if (how === "pointer") {
      target.dispatchEvent(pev("pointerdown"));
      target.dispatchEvent(pev("pointerup"));
    } else {
      target.dispatchEvent(pev("pointerdown"));
      target.dispatchEvent(pev("pointerup"));
      target.dispatchEvent(new MouseEvent("click", { clientX: x, clientY: y, bubbles: true, cancelable: true }));
    }
  }
  if (hold > 0) {
    // 模拟"按久一点再松手"：手机上很常见，而且会暴露
    // "浮层标记有效期太短 → pointerup 被谱面收尾逻辑吃掉"的问题
    target.dispatchEvent(pev("pointerdown"));
    window.__holdFinish = finish;
    return JSON.stringify({ ok: true, via: how, holding: true });
  }
  finish();
  return JSON.stringify({ ok: true, via: how });
})();
''';

/// 结束上面那次"按住了"的点按
const String _kReleaseBubbleJs = '''
(function () {
  if (typeof window.__holdFinish === "function") {
    var f = window.__holdFinish;
    window.__holdFinish = null;
    f();
    return "released";
  }
  return "nothing";
})();
''';

/// 点气泡里的某个选项**之前**的选中状态（验证"按钮真的起作用了"）
String editModeJs() => 'window.vrvEditMode ? window.vrvEditMode() : ""';

/// 点音符旁边 [dx]px 处（验证命中容差 / 粘性）
String tapNearJs(String id, {required double dx, required double dy}) => '''
(function () {
  var g = document.getElementById("$id");
  if (!g) { return JSON.stringify({ error: "no-note" }); }
  var head = g.querySelector("use, path, ellipse") || g;
  var r = head.getBoundingClientRect();
  var x = r.left + r.width / 2 + $dx, y = r.top + r.height / 2 + $dy;
  function mk(type) {
    return new PointerEvent(type, { clientX: x, clientY: y, bubbles: true,
      cancelable: true, pointerId: 7, pointerType: "touch", isPrimary: true, buttons: 1 });
  }
  var target = document.elementFromPoint(x, y) || document.getElementById("paper");
  target.dispatchEvent(mk("pointerdown"));
  window.dispatchEvent(mk("pointerup"));
  return JSON.stringify({ x: Math.round(x), y: Math.round(y) });
})();
''';
/// 取页面可滚动性 + 纸张宽度（验证放大按钮真的放大且能滚过去看）
String metricsJs() => '''
(function () {
  var p = document.getElementById("paper");
  return JSON.stringify({
    paperW: Math.round(p.getBoundingClientRect().width),
    docW: document.documentElement.clientWidth,
    scrollW: document.documentElement.scrollWidth,
    canScroll: document.documentElement.scrollWidth > document.documentElement.clientWidth + 2
  });
})();
''';
/// [hold] = true 时不松手（停在拖动中，用来给"拖动反馈"截图）。
/// [mouse] = true 时只发 mousedown/mousemove/mouseup（模拟"WebView 只递鼠标事件"
/// 的环境）；默认发 PointerEvent。[missPx] > 0 时故意点在音符**旁边**，
/// 验证"点偏一点也能选中"。
String dragJs(String id,
        {required double rightBeats,
        required double upLevels,
        bool hold = false,
        bool mouse = false,
        double missPx = 0}) =>
    '''
(function () {
  var g = document.getElementById("$id");
  if (!g) { return JSON.stringify({ error: "no-note" }); }
  var head = g.querySelector("use, path, ellipse") || g;
  var r = head.getBoundingClientRect();
  var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  // 页面里量到的刻度都是**屏幕像素**（一个间多高、一拍多宽），直接照它拖
  var space = window.vrvSpace("$id");
  var beat = window.vrvBeatPx("$id") || 0;
  var dx = beat > 0 ? $rightBeats * beat : $rightBeats * 4 * space * 1.6;
  var dy = -$upLevels * (space / 2);
  var miss = $missPx;
  var useMouse = $mouse;
  function send(target, kind, x, y) {
    var type = useMouse
        ? (kind === 'down' ? 'mousedown' : kind === 'move' ? 'mousemove' : 'mouseup')
        : (kind === 'down' ? 'pointerdown' : kind === 'move' ? 'pointermove' : 'pointerup');
    var init = { clientX: x, clientY: y, bubbles: true, cancelable: true, buttons: 1 };
    if (!useMouse) {
      init.pointerId = 1; init.pointerType = 'mouse'; init.isPrimary = true;
    }
    // 点偏的时候把事件派发到纸张上（不是音符本身），逼页面自己去"找最近的符头"
    var t = (kind === 'down' && miss > 0) ? document.getElementById('paper') : target;
    t.dispatchEvent(useMouse ? new MouseEvent(type, init) : new PointerEvent(type, init));
  }
  var px = cx + miss, py = cy + (miss > 0 ? 6 : 0);
  send(g, 'down', px, py);
  var selected = document.querySelectorAll("g.note.vrv-selected").length;
  send(g, 'move', px + dx, py + dy);
  // 再往同一个方向多走 1px，确保越过死区、真的进入拖动
  var ex = px + dx + (dx >= 0 ? 1 : -1);
  var ey = py + dy + (dy <= 0 ? -1 : 1);
  send(g, 'move', ex, ey);
  var ghost = document.querySelectorAll(".vrv-ghost").length;
  var guide = document.querySelectorAll(".vrv-guide").length;
  var tipEl = document.querySelector("g.vrv-tip text");
  var hintText = tipEl ? tipEl.textContent : "";
  var ring = document.querySelector("g.vrv-hl .vrv-ring");
  var ringOnNote = false, ringBigger = false;
  if (ring) {
    var nr = head.getBoundingClientRect(), rr = ring.getBoundingClientRect();
    ringOnNote = rr.width > 0 && rr.height > 0;
    ringBigger = rr.width > nr.width && rr.height > nr.height;
  }
  window.__lastDrag = { cx: cx, cy: cy, dx: dx, dy: dy };
  if (!$hold) { send(window, 'up', ex, ey); }
  return JSON.stringify({
    cx: Math.round(cx), cy: Math.round(cy),
    space: Math.round(space * 100) / 100, beatPx: Math.round(beat * 100) / 100,
    dx: Math.round(dx * 100) / 100, dy: Math.round(dy * 100) / 100,
    selected: selected, ghost: ghost, guide: guide, hint: hintText, tip: hintText,
    ringOnNote: ringOnNote, ringBigger: ringBigger
  });
})();
''';

List<int> degreesOf(Score score) => [
      for (final it in score.measures[0].items)
        if (it is NoteItem) it.degree,
    ];

/// 小节里每个条目的起点（拍）
List<double> startsOf(Score score) {
  var t = 0.0;
  final out = <double>[];
  for (final it in score.measures[0].items) {
    out.add(t);
    t += it.ticks;
  }
  return out;
}

/// 找某个音级在哪个条目上（返回条目下标，找不到 -1）
int indexOfDegree(Score score, int degree) {
  final items = score.measures[0].items;
  for (var i = 0; i < items.length; i++) {
    if (items[i] is NoteItem && (items[i] as NoteItem).degree == degree) return i;
  }
  return -1;
}

/// 浮层交互（滑竖条/点气泡）之后等它"放开"谱面事件，再接下一步
Future<void> settle(WidgetTester tester, [int ms = 700]) async {
  await tester.pump(Duration(milliseconds: ms));
  await Future<void>.delayed(Duration(milliseconds: ms));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('在谱面上拖音符能真的改谱（音高 / 位置 / 时值 + 撤销）', (tester) async {
    final state = AppState();
    state.setText('1=C 4/4\n1 2 3 4 |]', immediate: true);
    final before = state.text;
    final vrv = VerovioController();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScoreView(state: state, controller: vrv)),
    ));

    final ready = await waitFor(tester, () => vrv.ready);
    if (!ready) {
      // ignore: avoid_print
      print('--- Verovio 诊断 ---');
      for (final d in vrv.diagnostics) {
        // ignore: avoid_print
        print('  $d');
      }
    }
    expect(ready, isTrue, reason: 'Verovio 没起来：${vrv.status.error}');
    expect(await waitFor(tester, () => !vrv.status.rendering && vrv.pages >= 1), isTrue,
        reason: '渲染超时：${vrv.status.error}');

    final ids = await waitIds(tester, vrv, '1');
    // ignore: avoid_print
    print('页面里的音符 id：$ids');
    expect(ids, contains('lipu-0-1-0-0-0'), reason: 'MusicXML 的 note id 没被 Verovio 保留');
    expect(ids.length, 4, reason: '4 个音符应该有 4 个可编辑的 id');

    // 页面结构诊断：拖动刻度全建立在"量得准"上面
    final probe = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('页面结构：$probe');
    // ignore: avoid_print
    print('第一个音符的属性：${await js(vrv, 'window.vrvAttr("lipu-0-1-0-0-0")')}');
    expect(probe['spaceSource'], 'pitch',
        reason: '必须能量到"一个间"（音高差 vs y 差），否则拖动刻度是错的：$probe');
    expect((probe['space'] as num).toDouble(), greaterThan(2));
    expect((probe['space'] as num).toDouble(), lessThan(60), reason: '一个间不可能这么大：$probe');
    // 交叉验证：符头高度本来就约等于一个间，两条互相独立的测量必须对得上
    // （差 2 倍这种错就是靠这条抓出来的）
    final headH = ((probe['headRect'] as List)[3] as num).toDouble();
    final spacePx = (probe['space'] as num).toDouble();
    expect(spacePx, greaterThan(headH * 0.6),
        reason: '量到的"间"($spacePx) 和符头高度($headH) 对不上：$probe');
    expect(spacePx, lessThan(headH * 1.6),
        reason: '量到的"间"($spacePx) 和符头高度($headH) 对不上：$probe');
    expect((probe['beatPx'] as num).toDouble(), greaterThan(0),
        reason: '量不到"每拍多宽"，横向拖动就不是所见即所得：$probe');
    expect(probe['measures'], greaterThanOrEqualTo(1), reason: 'Verovio 没输出 g.measure：$probe');
    // 交互层必须真的绑上了（"装了新版但点了没反应"就是这么来的：
    // 换了 harness 但 WebView 缓存了旧文件，或者事件没绑成功）
    expect(probe['editBound'], isTrue, reason: '谱面交互层没绑上，点了不会有任何反应：$probe');
    expect(vrv.editBound, isTrue, reason: 'Dart 侧也应当知道交互层已就绪');
    expect(probe['hasPointerEvent'], isTrue, reason: '桌面端 WebView 应当支持 PointerEvent：$probe');

    /* ---------- 0a) 只递鼠标事件的环境（不发 PointerEvent）也要能编辑 ---------- */
    // 这条覆盖"某些 WebView 只把 mousedown/mousemove 递进来"的情况：
    // 页面必须两套都监听。放在最前面跑，因为指针事件一旦出现过，
    // 页面就会优先用指针事件（避免一次点击被当成两下）。
    final mouseOnly =
        jsonDecode(await js(vrv, dragJs('lipu-0-1-3-0-0', rightBeats: 0, upLevels: 1, mouse: true)))
            as Map<String, dynamic>;
    // ignore: avoid_print
    print('只用鼠标事件拖动：$mouseOnly');
    expect(mouseOnly['error'], isNull, reason: '没找到音符：$mouseOnly');
    expect(mouseOnly['selected'], 1, reason: 'mousedown 也要能选中音符：$mouseOnly');
    expect(mouseOnly['ghost'], 1, reason: 'mousemove 也要能拖动：$mouseOnly');
    expect(await waitFor(tester, () => degreesOf(state.score!).last == 5,
            timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '只发鼠标事件时也应该改到谱：${state.text}');
    // ignore: avoid_print
    print('只用鼠标事件拖动后：${state.text.replaceAll('\n', ' ⏎ ')}');
    state.undo();
    expect(degreesOf(state.score!).last, 4);

    /* ---------- 0b) 点偏几像素（手指点不准）也要选中最近的音符 ---------- */
    final nearMiss = jsonDecode(
            await js(vrv, dragJs('lipu-0-1-2-0-0', rightBeats: 0, upLevels: 1, missPx: 7)))
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('点偏 7px 再拖：$nearMiss');
    expect(nearMiss['selected'], 1,
        reason: '点在音符旁边（符头只有 9px 宽）也应该选中最近的音符：$nearMiss');
    expect(await waitFor(tester, () => degreesOf(state.score!)[2] == 4,
            timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '点偏之后的拖动也要生效：${state.text}');
    state.undo();

    /* ---------- 0) 反馈要"一眼看得见"：选中光环 + 拖动预览 + 导引线 ---------- */
    final snapDir = Directory('build/snapshots');
    if (!snapDir.existsSync()) snapDir.createSync(recursive: true);
    final freshIds = await waitIds(tester, vrv, '1');
    // ignore: avoid_print
    print('这一步页面上的 id：$freshIds  当前选中=${vrv.selectedNoteId}');
    final found = await vrv.selectNote('lipu-0-1-0-0-0');
    expect(found, isTrue, reason: '页面上找不到 lipu-0-1-0-0-0（现有 $freshIds）');
    expect(await waitFor(tester, () => vrv.selectedNoteId == 'lipu-0-1-0-0-0',
            timeout: const Duration(seconds: 10)),
        isTrue,
        reason: '选中状态没报回来（当前 ${vrv.selectedNoteId}，页面 id $freshIds）');
    final sel = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('选中态：selected=${sel['selected']} hasRing=${sel['hasRing']} '
        'ringRect=${sel['ringRect']} noteRect=${sel['noteRect']} accent=${sel['accent']}');
    expect(sel['selected'], 1, reason: '点中的音符要真的带上选中 class：$sel');
    expect(sel['hasRing'], isTrue, reason: '选中要有外圈光环：$sel');
    // 符头本体必须真的变色（Verovio 的字形吃 currentColor/fill），不能只画个圈
    // ignore: avoid_print
    print('符头填色：未选中 ${probe['headFill']} → 选中 ${sel['headFill']}');
    expect(sel['headFill'], isNot(probe['headFill']),
        reason: '选中的符头本体应该被染色（${probe['headFill']} → ${sel['headFill']}）');
    final ringRect = sel['ringRect'] as List;
    final noteRect = sel['noteRect'] as List;
    expect((ringRect[2] as num).toDouble(), greaterThan((noteRect[2] as num).toDouble()),
        reason: '光环必须比符头大才看得见：ring=$ringRect note=$noteRect');
    expect((ringRect[3] as num).toDouble(), greaterThan((noteRect[3] as num).toDouble()),
        reason: '光环必须比符头大才看得见：ring=$ringRect note=$noteRect');
    // 光环至少要有 12px 宽（符头才 9px），否则就是"反馈不明显"
    expect((ringRect[2] as num).toDouble(), greaterThan(12),
        reason: '光环太小了，用户看不出来：ring=$ringRect');
    final selPng = await vrv.snapshot(factor: 3.0);
    if (selPng != null) {
      File('${snapDir.path}/edit_selected.png').writeAsBytesSync(selPng);
      // ignore: avoid_print
      print('选中态截图 build/snapshots/edit_selected.png ${selPng.length} 字节');
    }
    expect(selPng, isNotNull, reason: '当前画面截图失败');

    /* ---------- 0b) 拖到一半停住：预览符头 + 竖线导引 + 顶部提示 ---------- */
    final holding =
        jsonDecode(await js(vrv, dragJs('lipu-0-1-2-0-0', rightBeats: 1, upLevels: 1, hold: true)))
            as Map<String, dynamic>;
    // ignore: avoid_print
    print('拖动中：$holding');
    expect(holding['ghost'], 1, reason: '拖动时要有预览符头：$holding');
    expect(holding['guide'], 1, reason: '拖动时要有竖线导引：$holding');
    expect(holding['hint'], contains('音高 +1'), reason: '顶部提示要显示改动量：${holding['hint']}');
    expect(holding['ringBigger'], isTrue,
        reason: '选中光环应比符头大（要看得见）：${holding['ringOnNote']}/${holding['ringBigger']}');
    final during =
        jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    expect(during['hlDim'], isTrue, reason: '拖动时要给原位置加"压暗"状态：$during');
    // 透明度是 CSS 过渡出来的，等过渡走完再量（transition 120ms）
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final during2 =
        jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('拖动中透明度：选中图层 ${during['hlOpacity']} → ${during2['hlOpacity']}');
    expect(double.parse(during2['hlOpacity'] as String), lessThan(0.6),
        reason: '拖动时原位置要压暗，眼睛才跟得住预览符头：${during2['hlOpacity']}');
    final dragPng = await vrv.snapshot(factor: 3.0);
    if (dragPng != null) {
      File('${snapDir.path}/edit_dragging.png').writeAsBytesSync(dragPng);
      // ignore: avoid_print
      print('拖动中截图 build/snapshots/edit_dragging.png ${dragPng.length} 字节');
    }
    // 松手结束这次拖动（取消掉，别影响后面的用例）
    await js(vrv, 'window.__lastDrag && window.dispatchEvent(new PointerEvent("pointercancel",'
        '{bubbles:true, pointerId:1}));');
    await waitFor(tester, () => true, timeout: const Duration(milliseconds: 300));
    await js(vrv, 'window.vrvClearEdit();');
    expect(await waitFor(tester, () => vrv.selectedNoteId == null, timeout: const Duration(seconds: 5)),
        isTrue);

    /* ---------- 1) 只往上的拖动：一个间 = 一级 ---------- */
    final vOnly = jsonDecode(await js(vrv, dragJs('lipu-0-1-3-0-0', rightBeats: 0, upLevels: 1)))
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('纯上下拖动：$vOnly');
    expect(vOnly['hint'], contains('位置不变'), reason: '没横拖就不该动位置：${vOnly['hint']}');
    expect(vOnly['hint'], contains('音高 +1'), reason: '${vOnly['hint']}');
    expect(await waitFor(tester, () => degreesOf(state.score!).last == 5,
            timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '最后一个音 4 往上一个间应该是 5：${state.text}');
    // ignore: avoid_print
    print('纯上下拖动后：${state.text.replaceAll('\n', ' ⏎ ')}');
    state.undo();
    expect(degreesOf(state.score!).last, 4, reason: '撤销应该退回去');

    /* ---------- 2) 上下 + 左右一起拖：上 1 级 = 一个间，右 1 拍 = 一拍的宽度 ---------- */
    final raw = await js(vrv, dragJs('lipu-0-1-0-0-0', rightBeats: 1, upLevels: 1));
    final geo = jsonDecode(raw) as Map<String, dynamic>;
    // ignore: avoid_print
    print('拖动几何：$geo');
    expect(geo['error'], isNull, reason: '没找到音符：$geo');
    expect(geo['selected'], 1, reason: '按下后应该有选中高亮');
    expect(geo['ghost'], greaterThanOrEqualTo(1), reason: '拖动时应该有预览符头');
    expect(geo['hint'], contains('音高 +1'), reason: '拖动时要提示改了多少：${geo['hint']}');
    expect(geo['hint'], contains('位置 +4'), reason: '右拖一拍应该是 4 个十六分格：${geo['hint']}');

    expect(await waitFor(tester, () => state.text != before, timeout: const Duration(seconds: 20)),
        isTrue, reason: '拖动没有传给 Dart（onEdit 没接上）');
    // ignore: avoid_print
    print('拖动后简谱：${state.text.replaceAll('\n', ' ⏎ ')}');
    final score = state.score!;
    final degrees = degreesOf(score);
    final starts = startsOf(score);
    // ignore: avoid_print
    print('拖动后的音级：$degrees  起点：$starts');
    expect(degrees, contains(2), reason: '第一个音 1 往上 1 级应该是 2：${state.text}');
    expect(degrees, isNot(contains(1)), reason: '原来的 1 应该被改掉了');
    final movedAt = indexOfDegree(score, 2);
    expect(starts[movedAt], closeTo(1.0, 1e-6),
        reason: '右拖一拍应该正好落在第 1 拍上（所见即所得）：${state.text}');
    expect(score.measures[0].filled, 4, reason: '小节总时值必须还是 4 拍');
    expect(state.canUndo, isTrue);

    // 改完之后选中状态要跟着音符走（挪了位置 id 会变，不能就这么丢了）
    final expectedSel = AppState.withItem('lipu-0-1-0-0-0', movedAt);
    expect(
        await waitFor(tester, () => vrv.selectedNoteId == expectedSel,
            timeout: const Duration(seconds: 15)),
        isTrue,
        reason: '改完之后应该重新选中这个音（期望 $expectedSel，实际 ${vrv.selectedNoteId}）');
    // ignore: avoid_print
    print('改完后选中的音符：${vrv.selectedNoteId}');

    /* ---------- 2) 单指操作：轻点选中 → 按住拖 → 再轻点出时值条 ---------- */
    // 这一段守的是用户反馈的核心："手机上要两个指头才能改、几乎控制不住"。
    // 根因是"按下的瞬间就切换模式"，于是选中后再按住拖会被当成第二次点击。
    await js(vrv, 'window.vrvClearEdit();');
    final cur1 = (await noteIds(vrv, '1')).first;
    await js(vrv, tapJs(cur1));
    expect(await waitFor(tester, () => vrv.selectedNoteId == cur1, timeout: const Duration(seconds: 10)),
        isTrue, reason: '轻点一次要选中音符');
    expect(vrv.editMode, 'position', reason: '第一次轻点只选中，不进时值模式');
    // ignore: avoid_print
    print('轻点一次：选中 ${vrv.selectedNoteId}，模式 ${vrv.editMode}');

    // 命中范围要"小"（用户反馈：范围太大容易误触）。已选中的音符另有一段粘性：
    // 点在它旁边十几像素处仍然认它，不会跳到邻居音符上——这同时修掉了
    // "点了两下也出不来时值条"（第二下点偏就选到别的音了）。
    final near = jsonDecode(await js(vrv, tapNearJs(cur1, dx: 18, dy: 4))) as Map<String, dynamic>;
    // ignore: avoid_print
    print('点旁边 18px：$near → 选中 ${vrv.selectedNoteId}');
    expect(vrv.selectedNoteId, cur1, reason: '点在已选中的音符旁边应当继续认它（别跳邻居）');
    // 等重排后的"选中接回"跑完，再点空白处（否则会被它又选回来）
    await settle(tester, 400);
    final far = jsonDecode(await js(vrv, tapNearJs(cur1, dx: 320, dy: 420))) as Map<String, dynamic>;
    // ignore: avoid_print
    print('点空白处：$far → 选中 ${vrv.selectedNoteId}');
    expect(vrv.selectedNoteId, isNull, reason: '点空白处应当取消选中（不要乱抓一个音符）');
    // 重新选中，继续后面的用例
    await js(vrv, tapJs(cur1));
    await waitFor(tester, () => vrv.selectedNoteId == cur1, timeout: const Duration(seconds: 10));

    // 选中之后**同一根手指按住拖**必须能改谱（以前这里会被切成时值模式而失效）
    final beforeTouchDrag = state.text;
    final touchDrag =
        jsonDecode(await js(vrv, touchDragJs(cur1, dx: 0, dy: -12))) as Map<String, dynamic>;
    // ignore: avoid_print
    print('选中后按住拖：${touchDrag['hint']}');
    expect(touchDrag['hint'], contains('音高'), reason: '选中后按住拖必须直接改音高：$touchDrag');
    expect(await waitFor(tester, () => state.text != beforeTouchDrag,
            timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '选中后再按住拖没有生效（又变回"要两根手指"了）：${state.text}');
    expect(vrv.editMode, isNot('duration'), reason: '拖动不应该把模式切成时值');
    state.undo();

    // 触摸时"一级"要有步长下限：拖 12px 应该只走 1~2 级，而不是按 1:1 走 4 级
    final hintText = touchDrag['hint'] as String;
    final stepNum = int.tryParse(RegExp(r'音高 \+(\d+)').firstMatch(hintText)?.group(1) ?? '') ?? 99;
    // ignore: avoid_print
    print('触摸拖 12px → 音高 +$stepNum（步长下限 9px，所以应当是 1）');
    expect(stepNum, lessThanOrEqualTo(2), reason: '触摸步长必须有下限，否则手机上控制不住：$hintText');
    state.undo();

    // 再轻点同一个音符 → 气泡菜单（时值/连音/插入/升降调）
    // （先清干净再连点两次，避免受前面拖动/撤销导致的 id 变化影响）
    await js(vrv, 'window.vrvClearEdit();');
    final cur2 = (await noteIds(vrv, '1')).first;
    await js(vrv, tapJs(cur2));
    expect(await waitFor(tester, () => vrv.selectedNoteId == cur2, timeout: const Duration(seconds: 10)),
        isTrue, reason: '第一次轻点要选中 $cur2');
    await js(vrv, tapJs(cur2));
    expect(await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10)),
        isTrue,
        reason: '第二次轻点同一个音符要弹出气泡菜单（当前模式 ${vrv.editMode}，选中 ${vrv.selectedNoteId}）');
    final menu = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('气泡菜单：shown=${menu['bubbleShown']} 选项=${menu['bubbleOptions']}');
    expect(menu['bubbleShown'], isTrue, reason: '气泡菜单要显示出来：$menu');
    expect(menu['bubbleOptions'], 9,
        reason: '时值/八度+/八度−/连音/插入/升降调/和弦/删除/关闭：$menu');

    /* ---------- 3) 气泡里的各项功能（按真实手指顺序点） ---------- */
    // ① 时值 → 贴着音符弹出时值气泡，滑动选二分音符
    //    注意：这里只发 pointerdown + pointerup，**不发 click**
    //    （安卓上 click 可能压根不来，按钮必须照样能用）
    final howDur = jsonDecode(await js(vrv, bubblePickJs('duration'))) as Map<String, dynamic>;
    // ignore: avoid_print
    print('点"时值"（${howDur['via']}，不发 click）：${howDur['ok']}');
    expect(howDur['ok'], isTrue, reason: '气泡选项找得到：$howDur');
    expect(await waitFor(tester, () => vrv.editMode == 'duration', timeout: const Duration(seconds: 10)),
        isTrue,
        reason: '不发 click、只靠 pointerup 也要能点开时值气泡（${howDur['via']}）');
    final bar = jsonDecode(await js(vrv,
            '''JSON.stringify({ shown: document.getElementById("durbar").classList.contains("show"), ticks: document.querySelectorAll("#durbar .tick").length, cur: document.querySelectorAll("#durbar .tick.cur").length, foot: document.querySelectorAll("#durbar .foot button").length })'''))
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('时值气泡：$bar');
    expect(bar['shown'], isTrue, reason: '气泡里点"时值"要弹出时值气泡');
    expect(bar['ticks'], 6, reason: '6 档时值（全/二分/四分/八分/十六分/三十二分）');
    expect(bar['cur'], 1, reason: '当前时值那一档要标出来：$bar');
    expect(bar['foot'], 2, reason: '附点 + 完成');
    // 时值气泡是**竖排**的、而且贴着音符（不再固定贴在屏幕右侧）
    final barRect = jsonDecode(await js(vrv,
            '''(function(){var r=document.getElementById("durbar").getBoundingClientRect();var n=document.querySelector("g.note.vrv-selected");var nr=n?n.getBoundingClientRect():null;return JSON.stringify({w:Math.round(r.width),h:Math.round(r.height),noteX:nr?Math.round(nr.left):-1,d: nr?Math.round(Math.abs(r.left-nr.right)):-1});})()'''))
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('时值气泡位置：$barRect');
    expect((barRect['h'] as num).toDouble(), greaterThan((barRect['w'] as num).toDouble() * 1.5),
        reason: '时值气泡是竖排的（上下滑动调时长）：$barRect');
    expect((barRect['d'] as num).toDouble(), lessThan(220),
        reason: '时值气泡要贴着音符弹出：$barRect');
    final barPng = await vrv.snapshot(factor: 2.0);
    if (barPng != null) {
      File('${snapDir.path}/edit_duration_mode.png').writeAsBytesSync(barPng);
      // ignore: avoid_print
      print('时值模式截图 build/snapshots/edit_duration_mode.png ${barPng.length} 字节');
    }

    // 上下滑动竖条 → 二分音符
    final beforeDur = state.text;
    final slid = jsonDecode(await js(vrv, slideDurJs('2'))) as Map<String, dynamic>;
    // ignore: avoid_print
    print('滑动竖条到"二分"：$slid');
    expect(slid['error'], isNull, reason: '找不到那一档：$slid');
    expect(slid['hovered'], 1, reason: '滑动过程中要实时高亮指向的那一档：$slid');
    expect(await waitFor(tester, () => state.text != beforeDur, timeout: const Duration(seconds: 20)),
        isTrue, reason: '滑动竖条没有改到谱');
    // ignore: avoid_print
    print('改时值后简谱：${state.text.replaceAll('\n', ' ⏎ ')}');
    final firstItem = state.score!.measures[0].items.first;
    expect(firstItem, isA<NoteItem>(), reason: '第一个条目应该还是音符：${state.text}');
    expect(firstItem.ticks, 2, reason: '滑到"二分"应该变成二分音符：${state.text}');
    expect(state.score!.measures[0].filled, 4, reason: '小节总时值必须还是 4 拍');
    state.undo();
    // 浮层交互后谱面会短暂忽略点击（防止同一次手势被两边处理），等它放开再继续
    await settle(tester);

    /* ---------- 3b) 连音 / 插入 / 升降调 ---------- */
    await js(vrv, 'window.vrvClearEdit();');
    final cur3 = (await noteIds(vrv, '1')).first;
    await js(vrv, tapJs(cur3));
    await waitFor(tester, () => vrv.selectedNoteId == cur3, timeout: const Duration(seconds: 10));
    await js(vrv, tapJs(cur3));
    expect(await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10)), isTrue);

    // 升降调 → ♯
    await js(vrv, bubblePickJs('acc'));
    await settle(tester, 300);
    final subAcc = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('升降调二级选项：${subAcc['bubbleOptions']} 个');
    final beforeAcc = state.text;
    await js(vrv, bubblePickJs('#', acc: true));
    await settle(tester);
    expect(await waitFor(tester, () => state.text != beforeAcc, timeout: const Duration(seconds: 20)),
        isTrue, reason: '点"♯升"应该给音符加升号：${state.text}');
    // ignore: avoid_print
    print('加升号后：${state.text.replaceAll('\n', ' ⏎ ')}');
    final accNote = state.score!.measures[0].items.first as NoteItem;
    expect(accNote.accidental, '#', reason: '第一个音应该带升号');
    state.undo();
    await settle(tester);

    // 插入 → 音符：小节已经满了，所以是"插入一个同样的音、末尾被挤掉"，
    // 条目数不一定变，但内容必须变、小节长度必须不变
    await js(vrv, 'window.vrvClearEdit();');
    final cur4 = (await noteIds(vrv, '1')).first;
    await js(vrv, tapJs(cur4));
    await waitFor(tester, () => vrv.selectedNoteId == cur4, timeout: const Duration(seconds: 10));
    await js(vrv, tapJs(cur4));
    await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
    final beforeInsertText = state.text;
    await js(vrv, bubblePickJs('insert'));
    await settle(tester, 300);
    await js(vrv, bubblePickJs('insert-note'));
    expect(await waitFor(tester, () => state.text != beforeInsertText,
            timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '点"插入→音符"应该改到谱：$beforeInsertText → ${state.text}');
    // ignore: avoid_print
    print('插入后小节：${state.text.replaceAll('\n', ' ⏎ ')}');
    final ins = state.score!.measures[0].items;
    expect(ins[1], isA<NoteItem>(), reason: '第二个条目应当是插入进来的音符：${state.text}');
    expect((ins[1] as NoteItem).degree, (ins[0] as NoteItem).degree,
        reason: '插入的是同一个音（同音高同时值）：${state.text}');
    expect(state.score!.measures[0].filled, 4, reason: '插入后小节总时值必须还是 4 拍');
    state.undo();
    await settle(tester);

    // 连音 → 进入"选第二个音"模式，再点另一个音符就把两点连起来
    // （这是用户报的那条：轻点 → 再轻点 → 选"连音" → 点另一个音符）
    await js(vrv, 'window.vrvClearEdit();');
    await settle(tester);
    final ids1 = await noteIds(vrv, '1');
    final cur5 = ids1.first;
    final second = ids1[1];

    // ⚠️ 先做一次**没有实际改动**的操作（同一个升号再点一遍），
    // 这会在 Dart 侧留下一个"待恢复的选中"。真实使用里很常见，
    // 而进入"连音选点"模式时，这个待恢复项会把 JS 的模式重置成 position，
    // 表现就是用户说的"点另一个音符只是把它选中了、没有连音线"。
    await js(vrv, tapJs(cur5));
    await waitFor(tester, () => vrv.selectedNoteId == cur5, timeout: const Duration(seconds: 10));
    await js(vrv, tapJs(cur5));
    await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
    await js(vrv, bubblePickJs('acc'));
    await settle(tester, 250);
    await js(vrv, bubblePickJs('#', acc: true));
    await settle(tester);
    // 再来一次同样的升号（这次是空操作）
    await js(vrv, tapJs(cur5));
    await settle(tester, 250);
    await js(vrv, tapJs(cur5));
    await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
    await js(vrv, bubblePickJs('acc'));
    await settle(tester, 250);
    await js(vrv, bubblePickJs('#', acc: true));
    await settle(tester);
    // ignore: avoid_print
    print('（已埋下"空操作"）：${state.text.replaceAll('\n', ' ⏎ ')}');

    await js(vrv, 'window.vrvClearEdit();');
    await settle(tester);
    await js(vrv, tapJs(cur5));
    await waitFor(tester, () => vrv.selectedNoteId == cur5, timeout: const Duration(seconds: 10));
    await js(vrv, tapJs(cur5));
    await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
    final beforeTie = toMusicXML(state.score!, padIncompleteMeasures: true);
    // **按住 800ms 再松手**（手机上很常见）：以前浮层标记只有 500ms 有效期，
    // 松手时会被谱面收尾逻辑吃掉，连音模式当场被清掉。
    final holdRes = jsonDecode(await js(vrv, bubblePickJs('tie', holdMs: 800)))
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('按住"连音"：${holdRes['holding']}');
    await tester.pump(const Duration(milliseconds: 800));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    // ignore: avoid_print
    print('松手：${await js(vrv, _kReleaseBubbleJs)}');
    expect(await waitFor(tester, () => vrv.editMode == 'tiePick', timeout: const Duration(seconds: 10)),
        isTrue,
        reason: '按住一会儿再松手，也要进入"再点另一个音符"的模式（当前 ${vrv.editMode}）');
    final pickMode = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('连音选点模式：mode=${pickMode['mode']} from=${pickMode['tieFrom']}');
    expect(pickMode['mode'], 'tiePick');
    expect(pickMode['tieFrom'], cur5);
    await settle(tester, 400);
    // 停顿一下再确认模式还在（这一步就是抓"被陈旧的选中恢复冲掉"）
    final stillPick = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('等一会儿后模式：${stillPick['mode']}（应当还是 tiePick）');
    expect(stillPick['mode'], 'tiePick',
        reason: '进入连音选点后，模式不该被别的东西重置：$stillPick');
    // 再点第二个音符 → 两个音连起来
    await js(vrv, tapJs(second));
    final afterTie = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('点第二个音后：mode=${afterTie['mode']} 选中=${vrv.selectedNoteId} '
        '画面上连音线=${afterTie['ties']}/${afterTie['tiePaths']}');
    expect(
        await waitFor(tester, () {
          final it = state.score!.measures[0].items.first;
          return it is NoteItem && (it.tieToNext || it.slurToNext);
        }, timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '点第二个音符后，两个音应当被连起来（tie 或 slur）：${state.text}');
    final tiedXml = toMusicXML(state.score!, padIncompleteMeasures: true);
    final addedTie = RegExp(r'<tie type="start"/>').allMatches(tiedXml).length >
        RegExp(r'<tie type="start"/>').allMatches(beforeTie).length;
    final addedSlur = RegExp(r'<slur type="start"').allMatches(tiedXml).length >
        RegExp(r'<slur type="start"').allMatches(beforeTie).length;
    // ignore: avoid_print
    print('连音：加了 tie=$addedTie slur=$addedSlur'
        '（tie ${RegExp(r'<tie ').allMatches(beforeTie).length}→${RegExp(r'<tie ').allMatches(tiedXml).length}，'
        'slur ${RegExp(r'<slur ').allMatches(beforeTie).length}→${RegExp(r'<slur ').allMatches(tiedXml).length}）');
    // 音高相同且相邻 → tie；音高不同或不相邻 → slur。两种都是"连音记号"
    expect(addedTie || addedSlur, isTrue,
        reason: '连音必须写进 MusicXML（tie 或 slur）：${state.text}');
    // **谱面上必须真的出现连音记号**（用户说"有的音符连音之后没有连音号"）
    await waitFor(tester, () => !vrv.status.rendering, timeout: const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final drawn = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    final tiesDrawn = (drawn['ties'] as num).toInt() + (drawn['tiePaths'] as num).toInt();
    final slursDrawn = (drawn['slurs'] as num).toInt() + (drawn['slurPaths'] as num).toInt();
    // ignore: avoid_print
    print('重排后画面上连音记号：tie=$tiesDrawn slur=$slursDrawn');
    expect(tiesDrawn + slursDrawn, greaterThan(0),
        reason: 'MusicXML 里有连音记号，谱面上也必须画出来：$drawn');
    state.undo();
    await settle(tester);

    // 音高不同的两个音：应当写成圆滑线（slur），而且**也画得出来**
    // （这就是用户说的"有的音符连音之后没有连音号"：以前硬写成 tie，
    //   而 tie 只能连同音高，排版引擎直接不画）
    await js(vrv, 'window.vrvClearEdit();');
    await settle(tester);
    final idsSlur = await noteIds(vrv, '1');
    if (idsSlur.length >= 2) {
      await js(vrv, tapJs(idsSlur[0]));
      await waitFor(tester, () => vrv.selectedNoteId == idsSlur[0],
          timeout: const Duration(seconds: 10));
      await js(vrv, tapJs(idsSlur[0]));
      await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
      await js(vrv, bubblePickJs('tie'));
      await waitFor(tester, () => vrv.editMode == 'tiePick', timeout: const Duration(seconds: 10));
      await settle(tester, 350);
      await js(vrv, tapJs(idsSlur[1]));
      await waitFor(tester, () => !vrv.status.rendering, timeout: const Duration(seconds: 30));
      await tester.pump(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final second = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
      final xml2 = toMusicXML(state.score!, padIncompleteMeasures: true);
      final hasTie = xml2.contains('<tie type="start"/>');
      final hasSlur = xml2.contains('<slur type="start"');
      // ignore: avoid_print
      print('相邻两音连音：XML tie=$hasTie slur=$hasSlur；'
          '画面 tie=${second['ties']} slur=${second['slurs']}');
      if (hasSlur) {
        expect(((second['slurs'] as num) + (second['slurPaths'] as num)).toInt(),
            greaterThan(0),
            reason: '写成圆滑线就一定要画出来：$second');
      } else if (hasTie) {
        expect(((second['ties'] as num) + (second['tiePaths'] as num)).toInt(),
            greaterThan(0),
            reason: '写成连音线就一定要画出来：$second');
      }
      state.undo();
      await settle(tester);
    }

    // 同音高相邻的两个音 → 连音线（tie），也必须在画面上画出来
    state.setText('1=C 4/4\n1 1 3 4 |]', immediate: true);
    await settle(tester, 500);
    final idsTie = await noteIds(vrv, '1');
    await js(vrv, tapJs(idsTie[0]));
    await waitFor(tester, () => vrv.selectedNoteId == idsTie[0], timeout: const Duration(seconds: 10));
    await js(vrv, tapJs(idsTie[0]));
    await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
    await js(vrv, bubblePickJs('tie'));
    await waitFor(tester, () => vrv.editMode == 'tiePick', timeout: const Duration(seconds: 10));
    await settle(tester, 350);
    await js(vrv, tapJs(idsTie[1]));
    expect(
        await waitFor(tester, () {
          final it = state.score!.measures[0].items.first;
          return it is NoteItem && it.tieToNext;
        }, timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '同音高相邻应当写成 tie：${state.text}');
    await waitFor(tester, () => !vrv.status.rendering, timeout: const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final tieDrawn = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    final tieCount =
        (tieDrawn['ties'] as num).toInt() + (tieDrawn['tiePaths'] as num).toInt();
    // ignore: avoid_print
    print('同音高连音线：XML tie=${toMusicXML(state.score!).contains('<tie type="start"/>')} '
        '画面=$tieCount');
    expect(tieCount, greaterThan(0), reason: '同音高的连音线必须画出来：$tieDrawn');
    state.undo();
    await settle(tester);

    /* ---------- 3c) 和弦 / 删除 / 八度± ---------- */
    // 八度±：一键把一个音升降八度（八度点这种小记号模型读不准时的兜底手段）
    await js(vrv, 'window.vrvClearEdit();');
    await settle(tester);
    final curOct = (await noteIds(vrv, '1')).first;
    await js(vrv, tapJs(curOct));
    await waitFor(tester, () => vrv.selectedNoteId == curOct, timeout: const Duration(seconds: 10));
    await js(vrv, tapJs(curOct));
    await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
    final midiBefore = notePitches(
            state.score!.measures[0].items.whereType<NoteItem>().first, state.score!.key)
        .first
        .midi;
    await js(vrv, bubblePickJs('oct-up'));
    expect(
        await waitFor(tester, () {
          final it = state.score!.measures[0].items.whereType<NoteItem>().first;
          return notePitches(it, state.score!.key).first.midi == midiBefore + 12;
        }, timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '点"八度+"应该把这个音升一个八度：${state.text}');
    // ignore: avoid_print
    print('八度+ ：MIDI $midiBefore → 升高 12 成功，简谱「${state.text.split('\n').last}」');
    state.undo();
    await settle(tester);
    // 和弦：叠一个音（三度叠置），MusicXML 里应当出现 <chord/>
    // 这条**只用 touch 事件**（touchstart + 容器 touchend 兜底），验证不依赖 pointer/click
    await js(vrv, 'window.vrvClearEdit();');
    await settle(tester);
    final cur6 = (await noteIds(vrv, '1')).first;
    await js(vrv, tapJs(cur6));
    await waitFor(tester, () => vrv.selectedNoteId == cur6, timeout: const Duration(seconds: 10));
    await js(vrv, tapJs(cur6));
    await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
    final howChord = jsonDecode(await js(vrv, bubblePickJs('chord', via: 'touch')))
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('点"和弦"（${howChord['via']}）：${howChord['ok']}');
    expect(
        await waitFor(tester,
            () => state.score!.measures[0].items.first is NoteItem &&
                (state.score!.measures[0].items.first as NoteItem).isChord,
            timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '点"和弦"应该在选中的位置上叠一个和弦音：${state.text}');
    // ignore: avoid_print
    print('加和弦后：${state.text.replaceAll('\n', ' ⏎ ')}');
    expect(toMusicXML(state.score!, padIncompleteMeasures: true), contains('<chord/>'));
    state.undo();
    await settle(tester);

    // 删除：音符变成休止符，小节长度不变
    await js(vrv, 'window.vrvClearEdit();');
    await settle(tester);
    final cur7 = (await noteIds(vrv, '1')).first;
    await js(vrv, tapJs(cur7));
    await waitFor(tester, () => vrv.selectedNoteId == cur7, timeout: const Duration(seconds: 10));
    await js(vrv, tapJs(cur7));
    await waitFor(tester, () => vrv.editMode == 'menu', timeout: const Duration(seconds: 10));
    final filledBefore = state.score!.measures[0].filled;
    await js(vrv, bubblePickJs('delete'));
    expect(await waitFor(tester, () => state.score!.measures[0].items.first is RestItem,
            timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '点"删除"应该把音符去掉（位置留成休止符）：${state.text}');
    // ignore: avoid_print
    print('删除后：${state.text.replaceAll('\n', ' ⏎ ')}');
    expect(state.score!.measures[0].filled, closeTo(filledBefore, 1e-6),
        reason: '删音符不改小节长度');
    state.undo();
    await settle(tester);

    /* ---------- 4) 撤销已在上面的各步验证过 ---------- */

    /* ---------- 4b) 放大/缩小按钮：纸张要真的变宽，而且能滚过去看 ---------- */
    final m1 = jsonDecode(await js(vrv, metricsJs())) as Map<String, dynamic>;
    await vrv.setZoom(2.0);
    await waitFor(tester, () => vrv.zoom > 1.9, timeout: const Duration(seconds: 10));
    // 缩放是 CSS 宽度的变化，量它有延迟：轮询到"真的变宽"为止，别只等固定时间
    var m2 = jsonDecode(await js(vrv, metricsJs())) as Map<String, dynamic>;
    for (var i = 0;
        i < 20 && (m2['paperW'] as num).toDouble() <= (m1['paperW'] as num).toDouble() * 1.5;
        i++) {
      await tester.pump(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      m2 = jsonDecode(await js(vrv, metricsJs())) as Map<String, dynamic>;
    }
    // ignore: avoid_print
    print('缩放：1× → 纸张 ${m1['paperW']}px(视口 ${m1['docW']})，'
        '2× → 纸张 ${m2['paperW']}px，可横向滚动=${m2['canScroll']}');
    expect((m2['paperW'] as num).toDouble(), greaterThan((m1['paperW'] as num).toDouble() * 1.5),
        reason: '点放大后纸张必须真的变宽：$m1 → $m2');
    expect(m2['canScroll'], isTrue,
        reason: '放大后必须能滚动查看（以前 overflow-x:hidden 会把它裁掉，看着像"没反应"）：$m2');
    await vrv.setZoom(1.0);
    await tester.pump(const Duration(milliseconds: 200));

    /* ---------- 5) 大谱表（双手谱）的低音声部同样可编辑 ---------- */
    state.setText('1=C 4/4\n高音: 1 2 3 4 |\n低音: 1,, - - - |]', immediate: true);
    final bass = await waitIds(tester, vrv, '2');
    // ignore: avoid_print
    print('低音声部 id：$bass');
    expect(bass, isNotEmpty, reason: '大谱表里低音声部也必须能编辑');

    /* ---------- 6) 一页多个系统 / 大谱表时，两个"尺子"必须还是准的 ---------- */
    // （拟合必须只用"被拖的那个音符所在的那一行谱"，否则不同系统的 y 原点、
    //   大谱表两个谱号的偏移都会把斜率带偏）
    final longText = StringBuffer('标题：多系统\n1=C 4/4 ♩=96\n');
    for (var i = 0; i < 20; i++) {
      longText.writeln('高音: 1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |');
      longText.writeln('低音: 1,, - - - | 4,, - - - | 5,, - - - | 1,, - - - |');
    }
    state.setText(longText.toString(), immediate: true);
    final longIds = await waitIds(tester, vrv, '2');
    expect(longIds, isNotEmpty, reason: '长谱没渲染出低音声部');
    final probe2 = jsonDecode(await js(vrv, 'window.vrvProbe()')) as Map<String, dynamic>;
    // ignore: avoid_print
    print('长谱结构：systems=${probe2['systems']} staffs=${probe2['staffs']} '
        'space=${probe2['space']} src=${probe2['spaceSource']} beatPx=${probe2['beatPx']}');
    expect(probe2['systems'], greaterThan(1), reason: '这份长谱应该排成多个系统：$probe2');
    final headH2 = ((probe2['headRect'] as List)[3] as num).toDouble();
    final space2 = (probe2['space'] as num).toDouble();
    expect(space2, greaterThan(headH2 * 0.6),
        reason: '多系统页上量到的"间"($space2) 和符头高度($headH2) 对不上：$probe2');
    expect(space2, lessThan(headH2 * 1.6),
        reason: '多系统页上量到的"间"($space2) 和符头高度($headH2) 对不上：$probe2');
    // 大谱表两个谱表量出来的"间"必须一样（同一个谱号偏移不该影响斜率）
    final trebleSpace = jsonDecode(
            await js(vrv, '''JSON.stringify({ s: window.vrvSpace("${(await waitIds(tester, vrv, '1')).first}") })'''))
        as Map<String, dynamic>;
    final bassSpace = jsonDecode(
            await js(vrv, '''JSON.stringify({ s: window.vrvSpace("${longIds.first}") })'''))
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('高音谱量到 ${trebleSpace['s']}  低音谱量到 ${bassSpace['s']}');
    expect((trebleSpace['s'] as num).toDouble(),
        closeTo((bassSpace['s'] as num).toDouble(), (space2 * 0.35).abs()),
        reason: '两个谱表量出来的间应该基本一致');

    final dir = Directory('build/snapshots');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final png = await vrv.exportPng(1, factor: 2.0);
    if (png != null) {
      File('${dir.path}/score_edit_after.png').writeAsBytesSync(png);
      // ignore: avoid_print
      print('导出 build/snapshots/score_edit_after.png  ${png.length} 字节');
    }
  });
}
