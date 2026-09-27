/// 乐谱渲染：在 WebView 里跑 **Verovio**（JS/WASM）把 MusicXML 排成专业级 SVG。
///
/// 为什么这么绕：Verovio 是 C++/WASM 的排版引擎（Web 生态里最成熟的开源方案），
/// 没有 Dart 绑定；用它最稳的方式就是塞进一个 WebView。好处是**一套代码两端都能用**
/// （Android 用系统 WebView，Windows 用 WebView2），而且不用背 Python/MuseScore。
///
/// 资源落地方式：Verovio 那个自包含的 JS（内嵌 WASM + 字形，约 7MB）从 assets
/// 解压到临时目录，和 index.html / harness.js 一起放到同一个文件夹，
/// WebView 直接以 `file://` 打开——同源、无 CORS、也不用往 WebView 里塞巨大字符串。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/app_paths.dart';

/// Verovio 的 asset 路径
const String kVerovioAsset = 'assets/verovio/verovio-toolkit-wasm.js';

/// A4 页面尺寸（Verovio 单位：1 = 0.1mm）；2100 × 2970 就是 A4
const int kVerovioPageWidth = 2100;
const int kVerovioPageHeight = 2970;

/// 渲染状态
class VerovioStatus {
  final bool ready;
  final bool rendering;
  final int pages;
  final int page;
  final String? error;
  const VerovioStatus({
    this.ready = false,
    this.rendering = false,
    this.pages = 1,
    this.page = 1,
    this.error,
  });

  VerovioStatus copyWith({bool? ready, bool? rendering, int? pages, int? page, String? error, bool clearError = false}) =>
      VerovioStatus(
        ready: ready ?? this.ready,
        rendering: rendering ?? this.rendering,
        pages: pages ?? this.pages,
        page: page ?? this.page,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 谱面上直接操作音符时，WebView 递回来的一次编辑请求
class ScoreEditRequest {
  const ScoreEditRequest({
    required this.action,
    required this.id,
    this.step = 0,
    this.grid = 0,
    this.ticks = 0,
    this.accidental = '',
    this.asRest = false,
    this.fromId = '',
  });

  /// 'move' = 拖动（改音高 / 改位置），'duration' = 时值条，
  /// 'tie' = 连音线，'insert' = 在后面插入音符/休止符，'accidental' = 升降号，
  /// 'tieTo' = 连音的第二个音，'chord' = 叠一个和弦音，'delete' = 删除音符
  final String action;

  /// 音符 id（lipu-...），由 MusicXML 里的 id 保留下来
  final String id;

  /// 音高级数增量：+1 = 升高一级（简谱里的 1→2），-1 = 降低
  final int step;

  /// 位置格数增量：+1 = 右移一个十六分音符格
  final int grid;

  /// 时值（四分音符 = 1，附点 = 1.5）
  final double ticks;

  /// 变音记号（'' | '#' | 'b' | 'n'）
  final String accidental;

  /// 插入的是不是休止符
  final bool asRest;

  /// 「连音」的起点 id（action == 'tieTo' 时用）
  final String fromId;
}

/// 驱动 [VerovioScoreView] 的控制器
class VerovioController extends ChangeNotifier {
  InAppWebViewController? _web;
  VerovioStatus _status = const VerovioStatus();
  String? _pendingXml;
  bool _pendingHeader = true;
  final Map<int, Completer<Uint8List?>> _pngWaiters = {};
  bool _filesReady = false;
  double _zoom = 1;

  /// 页面上当前选中的音符 id / 编辑模式（none | position | duration）
  String? selectedNoteId;
  String editMode = 'none';

  /// 谱面交互层是否绑上了（没绑上就只能看不能改，界面会提示重载）
  bool _editBound = true;
  bool get editBound => _editBound;

  /// 重新加载排版引擎页面。
  ///
  /// 场景：升级后浏览器缓存了旧的 `harness.js`（"装了新版但点了没反应"），
  /// 重载一次就能拿到新资源（路径带内容指纹，见 [_harnessDirName]）。
  Future<void> reload() async {
    final w = _web;
    if (w == null) return;
    _filesReady = false;
    _editBound = true;
    final uri = await harnessUri();
    await w.loadUrl(urlRequest: URLRequest(url: uri));
  }

  /// 用户在谱面上拖了音符 / 点了时值时回调
  void Function(ScoreEditRequest request)? onEdit;

  /// 把选择状态交回给页面（重排之后重新选中同一个音符）。
  /// 返回页面上是否真的找到了这个音符（找不到说明 id 已经变了）。
  Future<bool> selectNote(String noteId, {String mode = 'position'}) async {
    if (_web == null || !_status.ready) return false;
    final r = await _web!.evaluateJavascript(
      source: 'window.vrvSelect(${jsonEncode(noteId)}, ${jsonEncode(mode)});',
    );
    return r == true;
  }

  /// 清掉页面上的选中高亮
  Future<void> clearSelection() async {
    if (_web == null || !_status.ready) return;
    await _web!.evaluateJavascript(source: 'window.vrvClearEdit();');
  }

  /// 当前缩放倍数（1 = 适配宽度）
  double get zoom => _zoom;

  /// 最近一次从页面量到的版面尺寸（测试用来断言 A4 比例）
  Map<String, dynamic> metrics = const {};

  Future<void> requestMetrics() async {
    if (_web == null || !_status.ready) return;
    await _web!.evaluateJavascript(source: 'window.vrvMetrics();');
  }

  VerovioStatus get status => _status;
  bool get ready => _status.ready;
  int get pages => _status.pages;
  int get page => _status.page;

  /// 底层 WebView 控制器（集成测试 / 诊断用）
  InAppWebViewController? get web => _web;

  /// WebView 创建后挂上来
  void attach(InAppWebViewController web) {
    _web = web;
    _web!.addJavaScriptHandler(
      handlerName: 'vrv',
      callback: (args) {
        if (args.isEmpty) return;
        _onMessage(args.first.toString());
      },
    );
  }

  void detach() {
    _web = null;
    _filesReady = false;
  }

  /// 外部（比如解压资源失败）报错时也走同一套状态
  void reportExternalError(String message) {
    _status = _status.copyWith(rendering: false, error: message);
    notifyListeners();
  }

  void _onMessage(String raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'ready':
        _status = _status.copyWith(ready: true, rendering: false, clearError: true);
        _editBound = msg['editBound'] != false;
        notifyListeners();
        final pending = _pendingXml;
        if (pending != null) {
          _pendingXml = null;
          render(pending, showHeader: _pendingHeader);
        }
        break;
      case 'rendered':
        _status = _status.copyWith(
          pages: (msg['pages'] as num?)?.toInt() ?? 1,
          page: 1,
          rendering: false,
          clearError: true,
        );
        notifyListeners();
        // 重排后把缩放重新应用上（draw() 换掉了内部 DOM）
        if ((_zoom - 1).abs() >= 0.01) {
          unawaited(_web?.evaluateJavascript(source: 'window.vrvZoom($_zoom);'));
        }
        break;
      case 'page':
        _status = _status.copyWith(
          page: (msg['page'] as num?)?.toInt() ?? 1,
          pages: (msg['pages'] as num?)?.toInt() ?? _status.pages,
        );
        notifyListeners();
        break;
      case 'zoom':
        _zoom = (msg['zoom'] as num?)?.toDouble() ?? 1;
        notifyListeners();
        break;
      case 'editSelect':
        selectedNoteId = msg['id']?.toString();
        editMode = msg['mode']?.toString() ?? 'none';
        notifyListeners();
        break;
      case 'edit':
        final req = ScoreEditRequest(
          action: msg['action']?.toString() ?? '',
          id: msg['id']?.toString() ?? '',
          step: (msg['step'] as num?)?.toInt() ?? 0,
          grid: (msg['grid'] as num?)?.toInt() ?? 0,
          ticks: (msg['ticks'] as num?)?.toDouble() ?? 0,
          accidental: msg['accidental']?.toString() ?? '',
          asRest: msg['rest'] == true,
          fromId: msg['from']?.toString() ?? '',
        );
        if (req.id.isNotEmpty) onEdit?.call(req);
        break;
      case 'metrics':
        metrics = msg;
        notifyListeners();
        break;
      case 'png':
        final page = (msg['page'] as num?)?.toInt() ?? 0;
        final data = msg['data'] as String?;
        _pngWaiters.remove(page)?.complete(_decodeDataUrl(data));
        break;
      case 'error':
        _status = _status.copyWith(rendering: false, error: msg['message']?.toString() ?? '未知错误');
        notifyListeners();
        break;
    }
  }

  static Uint8List? _decodeDataUrl(String? url) {
    if (url == null) return null;
    final i = url.indexOf(',');
    if (i < 0) return null;
    try {
      return base64Decode(url.substring(i + 1));
    } catch (_) {
      return null;
    }
  }

  /// harness 落地的目录名。
  ///
  /// **带上内容指纹**：WebView（Chromium/WebView2）会按 URL 缓存 `file://` 资源，
  /// 而 index.html / harness.js 的路径是固定的——升级后如果路径没变，浏览器
  /// 可能继续用旧的那份 harness.js，表现就是"新版本装了但点了完全没反应"。
  /// 指纹一变就是新 URL，缓存自然失效；旧目录顺手清掉。
  static String get _harnessDirName {
    final h = Object.hash(_kHarnessJs.length, _kHarnessJs.hashCode, kVerovioAsset.length);
    return 'lipu_verovio_${h.toUnsigned(32).toRadixString(16)}';
  }

  /// 让 WebView 打开本地 harness（只做一次）
  Future<void> _prepareFiles() async {
    if (_filesReady) return;
    final root = AppPaths.tempDir();
    final dir = Directory(AppPaths.join(root, _harnessDirName));
    final js = File(AppPaths.join(dir, 'verovio-toolkit-wasm.js'));
    final html = File(AppPaths.join(dir, 'index.html'));
    final harness = File(AppPaths.join(dir, 'harness.js'));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 清掉旧版本的 harness 目录（历史版本可能留有缓存文件，白占空间）
    try {
      for (final e in root.listSync()) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('lipu_verovio') && name != _harnessDirName) {
          try { e.deleteSync(recursive: true); } catch (_) {}
        }
      }
    } catch (_) {}

    // Verovio 的 JS 有 7MB，按大小判断是否已经解压过，避免每次启动都写
    if (!js.existsSync() || js.lengthSync() < 1000000) {
      final bytes = await rootBundle.load(kVerovioAsset);
      await js.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
    }
    await harness.writeAsString(_kHarnessJs, flush: true);
    await html.writeAsString(_kIndexHtml, flush: true);
    _filesReady = true;
  }

  Future<WebUri> harnessUri() async {
    await _prepareFiles();
    final dir = Directory(AppPaths.join(AppPaths.tempDir(), _harnessDirName));
    final html = AppPaths.join(dir, 'index.html');
    // 必须用 Uri.file 生成 file URI：Windows 上手写 'file://C:/...' 是错的
    // （要三个斜杠 file:///C:/...），WebView 会加载失败而且不给明确报错。
    return WebUri(Uri.file(html).toString());
  }

  /// 调试/诊断：把最近的控制台与加载错误留下来
  final List<String> diagnostics = [];

  void addDiagnostic(String line) {
    diagnostics.add(line);
    if (diagnostics.length > 60) diagnostics.removeAt(0);
  }

  /// 渲染一份 MusicXML；[showHeader] 控制是否显示标题/作者抬头
  Future<void> render(String musicXml, {bool showHeader = true}) async {
    if (_web == null || !_status.ready) {
      _pendingXml = musicXml;
      _pendingHeader = showHeader;
      return;
    }
    _status = _status.copyWith(rendering: true, clearError: true);
    notifyListeners();
    await _web!.evaluateJavascript(
      source: 'window.vrvRender(${jsonEncode(musicXml)}, ${jsonEncode({'header': showHeader ? 'auto' : 'none'})});',
    );
  }

  Future<void> gotoPage(int page) async {
    if (_web == null || !_status.ready) return;
    await _web!.evaluateJavascript(source: 'window.vrvPage($page);');
  }

  /// 缩放：1 = 适配宽度
  Future<void> setZoom(double mult) async {
    _zoom = mult.clamp(0.5, 6.0);
    notifyListeners();
    if (_web == null || !_status.ready) return;
    if ((_zoom - 1).abs() < 0.01) {
      await _web!.evaluateJavascript(source: 'window.vrvFit();');
    } else {
      await _web!.evaluateJavascript(source: 'window.vrvZoom($_zoom);');
    }
  }

  /// 导出某一页为 PNG（[factor] 是相对页面 CSS 像素的放大倍数）
  Future<Uint8List?> exportPng(int page, {double factor = 2.5}) async {
    if (_web == null || !_status.ready) return null;
    final completer = Completer<Uint8List?>();
    _pngWaiters[page] = completer;
    await _web!.evaluateJavascript(source: 'window.vrvExport($page, $factor);');
    return completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
      _pngWaiters.remove(page);
      return null;
    });
  }

  /// 给页面里的选中光环/拖动预览上色（跟着 Material You 动态色走）
  Future<void> setAccent(Color primary, Color tertiary) async {
    String hex(Color c) {
      int ch(double v) => (v * 255).round().clamp(0, 255);
      return '#${ch(c.r).toRadixString(16).padLeft(2, '0')}'
          '${ch(c.g).toRadixString(16).padLeft(2, '0')}'
          '${ch(c.b).toRadixString(16).padLeft(2, '0')}';
    }

    final a = hex(primary), b = hex(tertiary);
    if (a == _accentSent) return;
    _accentSent = a;
    if (_web == null || !_status.ready) return;
    await _web!.evaluateJavascript(source: 'window.vrvSetAccent(${jsonEncode(a)}, ${jsonEncode(b)});');
  }

  String? _accentSent;

  /// 把**当前画面**（含选中光环、拖动预览）导成 PNG——核对交互反馈用
  Future<Uint8List?> snapshot({double factor = 2.0}) async {
    if (_web == null || !_status.ready) return null;
    final page = _status.page;
    final completer = Completer<Uint8List?>();
    _pngWaiters[page] = completer;
    await _web!.evaluateJavascript(source: 'window.vrvSnap($factor);');
    return completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
      _pngWaiters.remove(page);
      return null;
    });
  }
}

/// 承载 Verovio 的 WebView
class VerovioScoreView extends StatefulWidget {
  final VerovioController controller;
  const VerovioScoreView({super.key, required this.controller});

  @override
  State<VerovioScoreView> createState() => _VerovioScoreViewState();
}

class _VerovioScoreViewState extends State<VerovioScoreView> {
  @override
  void dispose() {
    widget.controller.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: false,
        // 以 file:// 打开本地 harness，需要允许同源文件互相加载
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        // 布局视口就用设备宽度：宽视口模式会把 A4 纸张的 CSS 宽度算错
        useWideViewPort: false,
        loadWithOverviewMode: false,
        useHybridComposition: true,
        disableHorizontalScroll: false,
        disableVerticalScroll: false,
        // Windows / Android 都不需要联网
        cacheEnabled: false,
      ),
      onWebViewCreated: (controller) async {
        widget.controller.attach(controller);
        // 打开本地 harness（会把 7MB 的 Verovio 解压到临时目录，只做一次）
        try {
          final uri = await widget.controller.harnessUri();
          widget.controller.addDiagnostic('load: $uri');
          await controller.loadUrl(urlRequest: URLRequest(url: uri));
        } catch (e) {
          widget.controller.reportExternalError('准备排版引擎失败：$e');
        }
      },
      onLoadStop: (controller, url) async {
        widget.controller.addDiagnostic('loaded: $url');
      },
      onReceivedError: (controller, request, error) async {
        widget.controller.addDiagnostic('resource error: ${request.url} -> ${error.description}');
      },
      onLoadError: (controller, url, code, message) async {
        widget.controller.reportExternalError('harness 加载失败（$code $message）');
        widget.controller.addDiagnostic('load error: $url $code $message');
      },
      onConsoleMessage: (controller, message) {
        widget.controller.addDiagnostic('console: ${message.message}');
      },
    );
  }
}

/// 用**无头** WebView 跑一遍 Verovio，把每一页导出成 PNG。导出页用它，
/// 不用在界面上放可见的 WebView。失败（或返回空）时调用方可以退到内置引擎。
Future<List<Uint8List>> exportScorePngsHeadless(
  String musicXml, {
  bool showHeader = true,
  double factor = 2.5,
  Duration timeout = const Duration(seconds: 90),
}) async {
  final controller = VerovioController();
  HeadlessInAppWebView? headless;
  try {
    headless = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        cacheEnabled: false,
      ),
      onWebViewCreated: (web) async {
        controller.attach(web);
        try {
          final uri = await controller.harnessUri();
          await web.loadUrl(urlRequest: URLRequest(url: uri));
        } catch (e) {
          controller.reportExternalError('准备排版引擎失败：$e');
        }
      },
    );
    await headless.run();

    final deadline = DateTime.now().add(timeout);
    while (!controller.ready && controller.status.error == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!controller.ready) return const [];

    await controller.render(musicXml, showHeader: showHeader);
    while (controller.status.rendering && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (controller.status.error != null) return const [];

    final out = <Uint8List>[];
    for (var i = 1; i <= controller.pages; i++) {
      final png = await controller.exportPng(i, factor: factor);
      if (png != null) out.add(png);
    }
    return out;
  } catch (_) {
    return const [];
  } finally {
    controller.detach();
    try {
      await headless?.dispose();
    } catch (_) {
      // 无头视图已经关掉就忽略
    }
  }
}

/// index.html：只负责版面和把 7MB 的 verovio 引进来（同目录，同源）
const String _kIndexHtml = r'''<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=6.0, user-scalable=yes">
<style>
  /* 页面要**可滚动**：手机放大后纸张比屏幕宽，必须能横向滚过去看，
     所以这里不能用 overflow-x:hidden，也不要用 flex 居中
     （flex 居中 + 溢出会把左边裁掉，用户看着就像"放大没反应"）。 */
  html, body { margin: 0; padding: 0; background: #E7E0EC; }
  #wrap { padding: 8px; box-sizing: border-box; }
  /* A4 纸张：宽度跟随可用宽度，桌面端最宽就是 A4 的 794px */
  #paper {
    background: #FFFFFF;
    width: 100%;
    max-width: 794px;
    box-shadow: 0 2px 12px rgba(0,0,0,0.32);
    overflow: hidden;
  }
  #paper svg { display: block; width: 100% !important; height: auto !important; }
  #msg { padding: 28px 18px; color: #49454F; font: 15px/1.6 system-ui, sans-serif; text-align: center; }

  /* ================= 谱面直接编辑的反馈 =================
     反馈要"一眼能看见"，所以：选中的符头本体变色 + 外圈脉冲光环 + 光晕；
     拖动时预览符头带过渡滑动并逐格弹一下；改完落点再闪一下。
     颜色由 Dart 传进来（跟着 Material You 动态色走）。 */
  :root { --vrv-accent: #6750A4; --vrv-accent2: #E8710A; }
  /* Verovio 的字形用 currentColor 上色，所以改 color/fill 就能把符头染成主题色
     （!important 是为了压过 Verovio 自己写在元素上的样式） */
  g.note.vrv-selected, g.note.vrv-selected * { color: var(--vrv-accent) !important; }
  g.note.vrv-selected .notehead, g.note.vrv-selected .notehead *,
  g.note.vrv-selected .stem, g.note.vrv-selected .stem * { fill: var(--vrv-accent) !important; }
  /* 拖动时把"原来的位置"压暗（opacity 是属性，CSS 只负责过渡动画） */
  g.vrv-hl { transition: opacity 120ms ease; }
  .vrv-ring { transform-box: fill-box; transform-origin: center;
              animation: vrvAppear 200ms cubic-bezier(.2,.9,.3,1) both,
                         vrvPulse 1.6s ease-in-out 200ms infinite; }
  .vrv-flash { transform-box: fill-box; transform-origin: center;
               animation: vrvFlash 700ms ease-out both; }
  /* 预览符头：位置变化靠 transform 过渡"滑"过去，逐格还有一次弹跳 */
  .vrv-ghost { transition: transform 110ms cubic-bezier(.2,.8,.3,1); }
  .vrv-ghost .pop { transform-box: fill-box; transform-origin: center; }
  .vrv-ghost.vrv-pop .pop { animation: vrvPop 200ms ease-out; }
  .vrv-guide { transition: transform 110ms cubic-bezier(.2,.8,.3,1); }
  @keyframes vrvAppear { from { opacity: 0; transform: scale(1.8); } to { opacity: 1; transform: scale(1); } }
  @keyframes vrvPulse { 0%, 100% { opacity: .95; transform: scale(1); } 50% { opacity: .35; transform: scale(1.16); } }
  @keyframes vrvPop { 0% { transform: scale(1); } 45% { transform: scale(1.45); } 100% { transform: scale(1); } }
  @keyframes vrvFlash { 0% { opacity: .8; transform: scale(2.2); } 100% { opacity: 0; transform: scale(1); } }

  #hint {
    position: fixed; left: 50%; top: 8px; z-index: 30;
    background: #1C1B1F; color: #fff; border-radius: 16px; padding: 7px 16px;
    font: 600 14px/1.5 system-ui, sans-serif; pointer-events: none;
    white-space: nowrap; box-shadow: 0 4px 14px rgba(0,0,0,.3);
    opacity: 0; visibility: hidden;
    transform: translateX(-50%) translateY(-10px) scale(.96);
    transition: opacity 130ms ease, transform 130ms cubic-bezier(.2,.9,.3,1), visibility 130ms;
  }
  #hint.show { opacity: 1; visibility: visible; transform: translateX(-50%) translateY(0) scale(1); }
  #hint b { color: #D0BCFF; }

  /* 第二次轻点音符弹出的**气泡菜单**（时值/连音/插入/升降调） */
  #bubble {
    position: fixed; z-index: 32; visibility: hidden; opacity: 0;
    transform: translateY(6px) scale(.94);
    background: rgba(28,27,31,.95); color: #fff; border-radius: 16px;
    padding: 6px; box-shadow: 0 8px 26px rgba(0,0,0,.42);
    display: flex; gap: 4px; align-items: center;
    font: 12.5px/1.3 system-ui, sans-serif;
    transition: opacity 130ms ease, transform 130ms cubic-bezier(.2,.9,.3,1), visibility 130ms;
    touch-action: none; user-select: none; -webkit-user-select: none;
  }
  #bubble.show { visibility: visible; opacity: 1; transform: translateY(0) scale(1); }
  #bubble .opt {
    padding: 9px 8px; border-radius: 12px; text-align: center; white-space: nowrap;
    background: rgba(255,255,255,.08); min-width: 56px;
  }
  #bubble .opt:active { background: rgba(255,255,255,.24); }
  #bubble .opt.on { background: var(--vrv-accent); }
  #bubble .opt.danger { color: #FFB4AB; }
  #bubble .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 4px; }
  #bubble .sub { display: flex; gap: 4px; margin-top: 4px; }
  #bubble .sub .opt { font-size: 11.5px; padding: 7px 6px; }
  #bubble .col { display: flex; flex-direction: column; }
  #bubble .grp { display: flex; gap: 4px; }
  /* 气泡尾巴（指向音符） */
  #bubble .tail {
    position: absolute; left: 50%; bottom: -6px; width: 12px; height: 12px;
    margin-left: -6px; background: rgba(28,27,31,.95); transform: rotate(45deg);
    border-radius: 2px;
  }
  /* 时值条：屏幕右侧一根**竖条**，上下滑动挑几分音符（上=更长）。
     为什么不做成一排按钮：手机上横排按钮既占地方、又不适合大拇指，
     用户明确要"上下滑动调时长"。 */
  #durbar {
    position: fixed; right: 10px; top: 50%; z-index: 31;
    transform: translateY(-50%) scale(.9);
    background: rgba(28,27,31,.92); color: #fff; border-radius: 18px;
    padding: 10px 8px; font: 13px/1.3 system-ui, sans-serif;
    box-shadow: 0 6px 22px rgba(0,0,0,.38);
    visibility: hidden; opacity: 0;
    transition: opacity 160ms ease, transform 160ms cubic-bezier(.2,.9,.3,1), visibility 160ms;
    touch-action: none; user-select: none; -webkit-user-select: none;
  }
  #durbar.show { visibility: visible; opacity: 1; transform: translateY(-50%) scale(1); }
  #durbar .head { text-align: center; font-weight: 700; font-size: 12px; color: #D0BCFF; margin-bottom: 6px; }
  #durbar .tick {
    padding: 9px 12px; border-radius: 12px; text-align: center; white-space: nowrap;
    transition: background 110ms, transform 110ms; position: relative;
  }
  #durbar .tick .lbl { font-size: 12px; opacity: .85; }
  #durbar .tick.cur { background: var(--vrv-accent); transform: scale(1.06); }
  #durbar .tick.cur .lbl { opacity: 1; font-weight: 700; }
  #durbar .tick.hover { background: rgba(255,255,255,.16); }
  #durbar .foot { display: flex; gap: 6px; margin-top: 6px; }
  #durbar .foot button {
    flex: 1; border: 1px solid rgba(255,255,255,.4); background: transparent; color: #fff;
    border-radius: 10px; padding: 5px 4px; font-size: 11.5px;
  }
  #durbar .foot button.on { background: var(--vrv-accent); border-color: var(--vrv-accent); }
  /* 选中音符后禁掉浏览器自己的平移手势，否则触摸拖动会被当成滚动吃掉 */
  #paper.vrv-editing { touch-action: none; }
  /* 关掉"双击缩放"：手机上连点两次音符会被浏览器当成双击放大，
     结果第二次轻点根本到不了页面（用户反馈"点两次出不来时值条"）。 */
  html, body, #wrap { touch-action: manipulation; }
</style>
</head>
<body>
<div id="wrap"><div id="paper"><div id="msg">正在加载排版引擎…</div></div></div>
<div id="hint"></div>
<div id="bubble"></div>
<div id="durbar"></div>
<script src="verovio-toolkit-wasm.js"></script>
<script src="harness.js"></script>
</body>
</html>
''';

/// harness.js：Dart <-> Verovio 的桥
const String _kHarnessJs = r'''
(function () {
  var tk = null;
  var ready = false;
  var state = { pages: 0, page: 1 };
  var PAGE_W = 2100, PAGE_H = 2970, SCALE = 38;

  // 给集成测试 / 诊断留一份消息记录
  window.__vrvLog = [];

  function post(m) {
    try {
      if (window.__vrvLog.length > 240) { window.__vrvLog.shift(); }
      window.__vrvLog.push(m);
    } catch (e) {}
    try { window.flutter_inappwebview.callHandler('vrv', JSON.stringify(m)); } catch (e) {}
  }
  function paper() { return document.getElementById('paper'); }
  function msg(t) { paper().innerHTML = '<div id="msg">' + t + '</div>'; }

  function options() {
    return {
      pageWidth: PAGE_W,
      pageHeight: PAGE_H,
      scale: SCALE,
      adjustPageHeight: false,
      breaks: 'auto',
      footer: 'none',
      header: 'none',
      svgViewType: 'default',
      openControlEvents: false
    };
  }

  function draw() {
    var keep = ED.id, keepMode = ED.mode, keepDot = ED.dot;
    clearEdit();
    ED.dot = keepDot;
    var svg = tk.renderToSVG(state.page);
    paper().innerHTML = svg;
    var el = paper().querySelector('svg');
    if (el) {
      // 关键：Verovio 输出的 <svg> **没有 viewBox**，只带 width/height 属性。
      // 直接删掉这两个属性再 width:100% 会让浏览器失去宽高比，
      // 元素塌成默认的 ~150px 高，谱面就被横向拉宽 + 纵向裁掉了。
      // 先把尺寸转成 viewBox，再让宽度自适应。
      var w = parseFloat(el.getAttribute('width')) || 794;
      var h = parseFloat(el.getAttribute('height')) || 1123;
      el.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
      el.setAttribute('preserveAspectRatio', 'xMidYMid meet');
      el.removeAttribute('width');
      el.removeAttribute('height');
      el.style.width = '100%';
      el.style.height = 'auto';
      el.style.display = 'block';
    }
    // 重排后把选中状态接回来（同一个音符 id 仍然有效）
    if (keep) {
      var again = document.getElementById(keep);
      if (again) { selectNote(again, keepMode === 'duration' ? 'duration' : 'position'); }
    }
  }

  function baseWidth() {
    var vw = document.documentElement.clientWidth || 800;
    return Math.min(vw - 16, 794);
  }

  /// 缩放：mult = 1 表示"适配宽度"
  window.vrvZoom = function (mult) {
    var p = paper();
    var w = Math.round(baseWidth() * mult);
    p.style.maxWidth = 'none';
    p.style.width = w + 'px';
    post({ type: 'zoom', zoom: mult });
  };

  window.vrvFit = function () {
    var p = paper();
    p.style.maxWidth = '794px';
    p.style.width = '100%';
    post({ type: 'zoom', zoom: 1 });
  };

  /// 把"纸张的实测尺寸"报回去，用来断言版面真的是 A4 比例
  window.vrvMetrics = function () {
    var p = paper();
    var el = p.querySelector('svg');
    var r = p.getBoundingClientRect();
    var sr = el ? el.getBoundingClientRect() : { width: 0, height: 0 };
    post({
      type: 'metrics',
      paperW: Math.round(r.width * 100) / 100,
      paperH: Math.round(r.height * 100) / 100,
      svgW: Math.round(sr.width * 100) / 100,
      svgH: Math.round(sr.height * 100) / 100,
      viewBox: el ? el.getAttribute('viewBox') : null,
      viewportW: document.documentElement.clientWidth
    });
  };

  window.vrvInit = function () {
    try {
      tk = new verovio.toolkit();
      tk.setOptions(options());
      ready = true;
      bindEdit();
      post({ type: 'ready', editBound: !!paper().__vrvBound });
    } catch (e) {
      post({ type: 'error', message: 'Verovio 初始化失败: ' + e });
    }
  };

  window.vrvRender = function (xml, opts) {
    if (!ready) { post({ type: 'error', message: 'Verovio 还没准备好' }); return; }
    try {
      var o = options();
      if (opts && opts.header) { o.header = opts.header; }
      tk.setOptions(o);
      if (!tk.loadData(xml)) {
        post({ type: 'error', message: 'Verovio 无法解析这份 MusicXML' });
        return;
      }
      state.pages = tk.getPageCount();
      state.page = 1;
      draw();
      post({ type: 'rendered', pages: state.pages });
    } catch (e) {
      post({ type: 'error', message: String(e) });
    }
  };

  window.vrvPage = function (n) {
    if (!ready || !state.pages) return;
    state.page = Math.max(1, Math.min(state.pages, n));
    draw();
    post({ type: 'page', page: state.page, pages: state.pages });
  };

  window.vrvExport = function (n, factor) {
    if (!ready || !state.pages) { post({ type: 'png', page: n, data: null }); return; }
    try {
      var page = Math.max(1, Math.min(state.pages, n));
      var svg = tk.renderToSVG(page);
      var blob = new Blob([svg], { type: 'image/svg+xml;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var img = new Image();
      img.onload = function () {
        var c = document.createElement('canvas');
        c.width = Math.round(img.width * factor);
        c.height = Math.round(img.height * factor);
        var ctx = c.getContext('2d');
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(0, 0, c.width, c.height);
        ctx.drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url);
        post({ type: 'png', page: page, data: c.toDataURL('image/png') });
      };
      img.onerror = function () {
        URL.revokeObjectURL(url);
        post({ type: 'error', message: '把 SVG 转成 PNG 失败' });
      };
      img.src = url;
    } catch (e) {
      post({ type: 'error', message: String(e) });
    }
  };

  /* ================= 谱面直接编辑（鼠标/手指拖动） =================
     约定（用户定的交互）：
       · 第一次点音符 → 位置模式：上下拖 = 改音高（一级 = 一条线/间），
         左右拖 = 改位置（一格 = 十六分音符）
       · 再点同一个音符 → 时值模式：底部弹出一条时值条，点哪个就是几分音符
       · 和弦里每个符头都是独立 id，可以单独拖某个音
     拖动过程中不重排（那会卡），只画一个半透明预览符头 + 数值提示，
     松手才把增量交给 Dart：{ type:'edit', action:'move', id, step, grid }。
  ================================================================ */
  var NS = 'http://www.w3.org/2000/svg';
  var DUR_BEATS = { '0': 8, '1': 4, '2': 2, '4': 1, '8': 0.5, '16': 0.25, '32': 0.125, '64': 0.0625 };
  var ACCENT = '#6750A4', ACCENT2 = '#E8710A';
  var ED = {
    id: null, mode: 'none', dragging: false,
    sx: 0, sy: 0, step: 0, grid: 0,
    hl: null, hlRing: null, ghost: null, ghostPop: null, guide: null, tip: null,
    spacePx: 10, localPerPx: 1, gridPx: 20, dot: false,
    anchor: null, halfW: 4, halfH: 3, staffTop: 0, staffBottom: 0,
    flashUntil: 0, lastStep: 0, lastGrid: 0, tied: false
  };
  var DURS = [
    { t: 4, label: '全' }, { t: 2, label: '二分' }, { t: 1, label: '四分' },
    { t: 0.5, label: '八分' }, { t: 0.25, label: '十六分' }, { t: 0.125, label: '三十二分' }
  ];

  /// 主题色（Material You 动态色从 Dart 传进来）
  window.vrvSetAccent = function (primary, tertiary) {
    if (primary) { ACCENT = primary; document.documentElement.style.setProperty('--vrv-accent', primary); }
    if (tertiary) { ACCENT2 = tertiary; document.documentElement.style.setProperty('--vrv-accent2', tertiary); }
    return true;
  };

  function el(tag, attrs) {
    var e = document.createElementNS(NS, tag);
    for (var k in attrs) {
      if (attrs[k] !== null && attrs[k] !== undefined) { e.setAttribute(k, attrs[k]); }
    }
    return e;
  }

  /// 重新触发一次性动画（去掉 class → 强制重排 → 加回来）
  function replay(node, cls) {
    if (!node) { return; }
    node.classList.remove(cls);
    try { node.getBoundingClientRect(); } catch (e) {}
    node.classList.add(cls);
  }

  /// 交互事件计数（诊断用：判断"点了没反应"到底卡在哪一步）
  var EVCOUNT = { down: 0, miss: 0, move: 0, up: 0, edge: 'none' };
  var SAW_POINTER = false;
  // 最近一次按下：用来区分"点一下"和"按住拖"（见 onDown/onUp）
  var CLICK = { id: null, wasSelected: false, moved: false };
  function noteEvent(kind) {
    if (EVCOUNT[kind] === undefined) { EVCOUNT[kind] = 0; }
    EVCOUNT[kind]++;
  }

  function svgRoot() { var p = paper(); return p ? p.querySelector('svg') : null; }
  function hintEl() { return document.getElementById('hint'); }
  function durBarEl() { return document.getElementById('durbar'); }
  function bubbleEl() { return document.getElementById('bubble'); }

  /* ---------------- 气泡菜单（第二次轻点音符时弹出） ----------------
     选项：时值 / 连音 / 插入 / 升降调。
     「时值」打开右侧竖条；「插入」和「升降调」展开二级选项。 */
  var BUBBLE = { sub: '', lastFire: 0 };

  function hideBubble() {
    var e = bubbleEl();
    if (e) { e.classList.remove('show'); }
    BUBBLE.sub = '';
  }

  function renderBubble() {
    var e = bubbleEl();
    if (!e) { return; }
    var html = '<div class="tail"></div>';
    if (BUBBLE.sub === 'insert') {
      html += '<div class="col"><div class="grp">' +
          '<div class="opt" data-act="insert-note">音符</div>' +
          '<div class="opt" data-act="insert-rest">休止符</div>' +
          '<div class="opt" data-act="back">返回</div></div></div>';
    } else if (BUBBLE.sub === 'acc') {
      html += '<div class="col"><div class="grp">' +
          '<div class="opt" data-acc="#">♯ 升</div>' +
          '<div class="opt" data-acc="b">♭ 降</div>' +
          '<div class="opt" data-acc="">♮ 还原</div>' +
          '<div class="opt" data-act="back">返回</div></div></div>';
    } else {
      // 两行三列，手机上好点
      html += '<div class="grid">' +
          '<div class="opt" data-act="duration">时值</div>' +
          '<div class="opt" data-act="oct-up">八度+</div>' +
          '<div class="opt" data-act="oct-down">八度−</div>' +
          '<div class="opt' + (ED.tied ? ' on' : '') + '" data-act="tie">连音</div>' +
          '<div class="opt" data-act="insert">插入</div>' +
          '<div class="opt" data-act="acc">升降调</div>' +
          '<div class="opt" data-act="chord">和弦</div>' +
          '<div class="opt danger" data-act="delete">删除</div>' +
          '</div>' +
          '<div class="sub"><div class="opt" data-act="close">✕ 关闭</div></div>';
    }
    e.innerHTML = html;
    var opts = e.querySelectorAll('.opt');
    for (var i = 0; i < opts.length; i++) { bindBubbleOption(opts[i]); }
  }

  /// 气泡选项的点击派发。
  ///
  /// **不能只依赖 `click`**：安卓 WebView 上手势一多，click 很容易被吞掉；
  /// 而 `preventDefault()` 更是会直接把 click 干掉（上一版在 touchstart 里
  /// preventDefault，结果安卓上四个按钮彻底没反应）。
  /// 现在的做法：
  ///   · pointerdown/touchstart 只用来声明"这一下是浮层的"，**绝不 preventDefault**
  ///   · 动作在 pointerup / touchend / mouseup / click 里执行，用时间戳**去重**，
  ///     哪条先到都生效，且同一次点只执行一次
  function bindBubbleOption(node) {
    function fire(ev) { bindFire(node, ev); }
    node.addEventListener('click', fire);
    node.addEventListener('pointerup', fire);
    node.addEventListener('touchend', fire);
    node.addEventListener('mouseup', fire);
  }

  /// 气泡放在音符**上方**，横向尽量对齐音符中心
  function placeBubble(g) {
    var e = bubbleEl();
    if (!e || !g) { return; }
    var head = headOf(g);
    var r = head.getBoundingClientRect();
    var vw = document.documentElement.clientWidth;
    var vh = document.documentElement.clientHeight;
    var w = e.offsetWidth || 260, h = e.offsetHeight || 44;
    var left = Math.min(Math.max(8, r.left + r.width / 2 - w / 2), vw - w - 8);
    var top = r.top - h - 10;
    if (top < 8) { top = r.bottom + 10; } // 上面放不下就放下面
    e.style.left = Math.round(left) + 'px';
    e.style.top = Math.round(top) + 'px';
  }

  function showBubble(g) {
    BUBBLE.sub = '';
    renderBubble();
    var e = bubbleEl();
    if (!e) { return; }
    // 先显示再量尺寸，位置才准
    e.classList.add('show');
    placeBubble(g);
  }

  /// 气泡菜单的选项被点中
  function onBubblePick(ev) {
    var b = ev.currentTarget;
    var act = b.getAttribute('data-act');
    var acc = b.getAttribute('data-acc');
    var g = ED.id ? document.getElementById(ED.id) : null;
    if (acc !== null && acc !== undefined) {
      markOverlay();
      post({ type: 'edit', action: 'accidental', id: ED.id, accidental: acc });
      hideBubble();
      return;
    }
    if (act === 'duration') {
      hideBubble();
      renderDurBar();
      showDurBar();
      placeDurBar(g); // 时值气泡贴着音符弹出来（不再固定贴在屏幕右侧）
      ED.mode = 'duration';
      post({ type: 'editSelect', id: ED.id, mode: 'duration' });
      return;
    }
    if (act === 'tie') {
      // 连音：进入"选另一个音符"模式，下一次点到别的音符就把两点连起来
      hideBubble();
      ED.mode = 'tiePick';
      TIE.from = ED.id;
      showTip((ED.anchor ? ED.anchor.x : 0), (ED.anchor ? ED.anchor.y : 0) - (ED.halfH || 6) * 3.2,
          '再点另一个音符，把它和这个音连起来', ED.localPerPx || 1,
          Math.max(9, (ED.spacePx || 10) * 1.05));
      post({ type: 'editSelect', id: ED.id, mode: 'tiePick' });
      return;
    }
    if (act === 'oct-up' || act === 'oct-down') {
      markOverlay();
      post({ type: 'edit', action: 'octave', id: ED.id, step: act === 'oct-up' ? 1 : -1 });
      hideBubble();
      return;
    }
    if (act === 'chord') {
      markOverlay();
      post({ type: 'edit', action: 'chord', id: ED.id });
      hideBubble();
      return;
    }
    if (act === 'delete') {
      markOverlay();
      post({ type: 'edit', action: 'delete', id: ED.id });
      hideBubble();
      return;
    }
    if (act === 'insert') { BUBBLE.sub = 'insert'; renderBubble(); placeBubble(g); return; }
    if (act === 'acc') { BUBBLE.sub = 'acc'; renderBubble(); placeBubble(g); return; }
    if (act === 'insert-note' || act === 'insert-rest') {
      markOverlay();
      post({
        type: 'edit', action: 'insert', id: ED.id,
        rest: act === 'insert-rest'
      });
      hideBubble();
      return;
    }
    if (act === 'back') { BUBBLE.sub = ''; renderBubble(); placeBubble(g); return; }
    if (act === 'close') { hideBubble(); return; }
  }

  /// 点/滑的是浮层（时值条、气泡）而不是谱面：让谱面的收尾逻辑别插手，
  /// 否则一次上滑/点按会被谱面当成"又轻点了一下"而直接关掉编辑状态。
  ///
  /// 有效期不能太短：手机上一次有意的点按常常要几百毫秒，
  /// 加上 WebView 主线程忙（7MB 的 WASM 引擎），500ms 很容易不够
  /// —— 标记一过期，pointerup 就会被谱面收尾逻辑吃掉，
  /// "连音选点"模式当场被清掉（用户反馈的正是这个）。
  var OVERLAY = { busy: false, at: 0, timer: null };
  function markOverlay() {
    OVERLAY.busy = true;
    OVERLAY.at = Date.now();
    if (OVERLAY.timer) { clearTimeout(OVERLAY.timer); }
    OVERLAY.timer = setTimeout(function () { OVERLAY.busy = false; }, 2500);
  }
  /// 手指回到谱面上按下 = 上一个浮层手势结束了
  function releaseOverlay() {
    if (OVERLAY.timer) { clearTimeout(OVERLAY.timer); }
    OVERLAY.busy = false;
  }

  function showHint(t) { var e = hintEl(); if (e) { e.innerHTML = t; e.classList.add('show'); } }
  function hideHint() { var e = hintEl(); if (e) { e.classList.remove('show'); } }
  function showDurBar() { var e = durBarEl(); if (e) { e.classList.add('show'); } }
  function hideDurBar() { var e = durBarEl(); if (e) { e.classList.remove('show'); } }
  function hintShown() { var e = hintEl(); return !!(e && e.classList.contains('show')); }

  /// 拖动时贴在音符**上方**的提示（用 SVG 画，跟着谱面一起缩放；
  /// 用户反馈"固定大小的顶部文字"不对，应该跟音符走）。
  function showTip(ax, ay, text, localPerPx, fontLocal) {
    removeTip();
    var svg = svgRoot();
    if (!svg) { return; }
    var g = el('g', { 'class': 'vrv-tip', 'pointer-events': 'none' });
    var pad = fontLocal * 0.5;
    var w = fontLocal * 0.62 * text.length + pad * 2;
    var h = fontLocal * 1.75;
    var x = ax - w / 2, y = ay - h;
    g.appendChild(el('rect', {
      x: x, y: y, width: w, height: h, rx: h * 0.28,
      fill: '#1C1B1F', opacity: '0.92'
    }));
    var t = el('text', {
      x: ax, y: y + h * 0.71, fill: '#FFFFFF', 'font-size': fontLocal,
      'text-anchor': 'middle', 'font-family': 'system-ui, sans-serif'
    });
    t.textContent = text;
    g.appendChild(t);
    // 挂在音符所在图层里，坐标系和音符一致
    var host = (ED.hl && ED.hl.parentNode) || svg;
    host.appendChild(g);
    ED.tip = g;
  }

  function removeTip() {
    if (ED.tip && ED.tip.parentNode) { ED.tip.parentNode.removeChild(ED.tip); }
    ED.tip = null;
  }

  /// 从事件目标往上找 <g class="note" id="lipu-...">
  function noteAt(target) {
    var n = target;
    while (n && n.nodeType === 1) {
      if (n.tagName && n.tagName.toLowerCase() === 'g' && n.id && n.id.indexOf('lipu-') === 0 &&
          n.classList && n.classList.contains('note')) { return n; }
      n = n.parentNode;
    }
    return null;
  }

  /// 命中测试：优先精确命中，其次找最近的符头。
  ///
  /// 容差**不能大**（用户反馈"判断范围太大容易误触"），而且有选中时
  /// **先偏向已经选中的那个音符**——否则第二次轻点常常落到旁边音符上，
  /// 表现为"点了两下也不出时值条"。
  function pickNote(target, clientX, clientY, maxPx, noSticky) {
    var direct = noteAt(target);
    if (direct) { return direct; }
    var p = paper();
    if (!p || clientX === undefined) { return null; }
    var sel = ED.id ? document.getElementById(ED.id) : null;
    var best = null, bestD = maxPx, bestSelD = 1e9;
    var notes = p.querySelectorAll('g.note[id^="lipu-"]');
    for (var i = 0; i < notes.length; i++) {
      var head = headOf(notes[i]);
      var r = head.getBoundingClientRect();
      if (r.width <= 0) { continue; }
      var dx = Math.max(r.left - clientX, 0, clientX - r.right);
      var dy = Math.max(r.top - clientY, 0, clientY - r.bottom);
      var d = Math.sqrt(dx * dx + dy * dy);
      if (notes[i] === sel) { bestSelD = d; }
      if (d < bestD) { bestD = d; best = notes[i]; }
    }
    // 已选中的音符在旁边（比一般容差宽一点）→ 就认它，避免误选邻居。
    // 但"连音选点"时明确是要点**别的**音符，所以那时不做粘性。
    if (!noSticky && sel && bestSelD < maxPx * 1.6 && best !== sel) { return sel; }
    return best;
  }

  /// 一个"间"（谱表相邻两线的距离）= 一级音高，单位是**屏幕像素**。
  ///
  /// 别按 Verovio 的组结构量：实测 `<g class="staff">` 里没有 `.staffline`，
  /// 它的 bbox 也不止 5 条线（量出来 300 多，真值 10 出头）。
  /// 所以改成用**音高差 vs 屏幕 y 差**做最小二乘——不依赖任何 class 名，
  /// 音符本来就知道自己是什么音（getElementAttr 里有 pname/oct）。
  ///
  /// 必须**只用被拖的那个音符所在谱表里**的音：一页上有多个系统时，
  /// 每个系统的 y 原点都不一样，混在一起拟合就废了；
  /// 大谱表的两个谱表之间还差一个谱号偏移，所以范围收到 `g.staff`（= 一行谱）。
  function staffSpacePx(anchor) {
    var p = paper();
    if (!p) return 0;
    var scope = null;
    if (anchor && anchor.closest) { scope = anchor.closest('g.staff'); }
    if (!scope) {
      var f = p.querySelector('g.note[id^="lipu-"]');
      scope = (f && f.closest) ? f.closest('g.staff') : null;
    }
    if (!scope) { scope = p; }
    var notes = scope.querySelectorAll('g.note[id^="lipu-"]');
    var pts = [];
    for (var i = 0; i < notes.length && pts.length < 60; i++) {
      var a = null;
      try { a = tk.getElementAttr(notes[i].id); } catch (e) {}
      if (!a || a.pname === undefined || a.oct === undefined) { continue; }
      var li = PITCH_LETTERS[String(a.pname).toLowerCase()];
      if (li === undefined) { continue; }
      var oct = parseInt(a.oct, 10);
      if (!isFinite(oct)) { continue; }
      var head = headOf(notes[i]);
      var r = head.getBoundingClientRect();
      pts.push({ s: oct * 7 + li, y: r.top + r.height / 2 });
    }
    // y = k*s + b：相邻音级差**半个间**，所以斜率 k = -space/2 → space = -2k
    var n = pts.length;
    if (n >= 2) {
      var sx = 0, sy = 0, sxx = 0, sxy = 0;
      for (var j = 0; j < n; j++) {
        sx += pts[j].s; sy += pts[j].y; sxx += pts[j].s * pts[j].s; sxy += pts[j].s * pts[j].y;
      }
      var den = n * sxx - sx * sx;
      if (Math.abs(den) > 1e-6) {
        var space = -2 * (n * sxy - sx * sy) / den;
        if (space > 1.5 && space < 120) { return space; }
      }
    }
    // 退路：符头高度差不多就是一个间
    var fh = scope.querySelector('g.note[id^="lipu-"] use, g.note[id^="lipu-"] path');
    if (fh) {
      var b = fh.getBoundingClientRect();
      if (b.height > 1.5) { return b.height; }
    }
    return 0;
  }

  var PITCH_LETTERS = { c: 0, d: 1, e: 2, f: 3, g: 4, a: 5, b: 6 };

  /// 是哪种办法量出来的（诊断用）
  function spaceSource(anchor) {
    var p = paper();
    if (!p) return 'none';
    var scope = (anchor && anchor.closest) ? anchor.closest('g.staff') : null;
    if (!scope) {
      var f = p.querySelector('g.note[id^="lipu-"]');
      scope = (f && f.closest) ? f.closest('g.staff') : p;
    }
    if (scope.querySelectorAll('g.note[id^="lipu-"]').length >= 2) return 'pitch';
    return scope.querySelector('g.note[id^="lipu-"] use, g.note[id^="lipu-"] path') ? 'head' : 'none';
  }

  /// 屏幕像素 → 某个元素所在坐标系（Verovio 的组上带 scale/translate，
  /// 不能拿 viewBox 硬算）。用 getScreenCTM 才是准的。
  function localPerPx(el) {
    var p = (el && el.parentNode) || el;
    try {
      var m = p.getScreenCTM ? p.getScreenCTM() : null;
      if (m) {
        var s = Math.sqrt(m.a * m.a + m.b * m.b);
        if (s > 0.0001) { return 1 / s; }
      }
    } catch (e) {}
    return 1;
  }

  /// 屏幕像素/拍：用同一小节同谱表里各音符的 (x, 起点拍) 拟合斜率。
  ///
  /// 有了它，横向拖动才是**所见即所得**的——把音符拖到下一个音符的位置，
  /// 它就真的落在那个音的拍点上（而不是"拖多远算多远"）。
  function beatPx(g) {
    try {
      var measure = g;
      while (measure && !(measure.classList && measure.classList.contains('measure'))) {
        measure = measure.parentNode;
      }
      if (!measure) { return 0; }
      var staff = g;
      while (staff && !(staff.classList && staff.classList.contains('staff'))) { staff = staff.parentNode; }
      var notes = measure.querySelectorAll('g.note[id^="lipu-"]');
      var xs = [], bs = [], start = 0, lastX = null;
      for (var i = 0; i < notes.length; i++) {
        if (staff && notes[i].closest && notes[i].closest('g.staff') !== staff) { continue; }
        var a = tk.getElementAttr(notes[i].id) || {};
        var dur = DUR_BEATS[String(a.dur || '')];
        if (dur === undefined) { continue; }
        var dots = parseInt(a.dots || '0', 10) || 0;
        if (dots === 1) { dur = dur * 1.5; } else if (dots === 2) { dur = dur * 1.75; }
        var head = headOf(notes[i]);
        var r = head.getBoundingClientRect();
        var x = r.left + r.width / 2;
        if (lastX === null || Math.abs(x - lastX) > 0.5) {
          xs.push(x); bs.push(start); lastX = x;
        }
        start += dur;
      }
      if (xs.length < 2) { return 0; }
      var dx = xs[xs.length - 1] - xs[0];
      var db = bs[bs.length - 1] - bs[0];
      if (db <= 0 || dx <= 0) { return 0; }
      return dx / db;
    } catch (e) { return 0; }
  }

  window.vrvBeatPx = function (id) {
    var g = document.getElementById(id);
    return g ? beatPx(g) : 0;
  };

  /// 量出来的"一个间"（诊断 / 测试要按同样的刻度来拖）
  window.vrvSpace = function (id) {
    var g = id ? document.getElementById(id) : null;
    return staffSpacePx(g);
  };

  window.vrvAttr = function (id) {
    try { return JSON.stringify(tk.getElementAttr(id) || null); } catch (e) { return 'null'; }
  };

  /// 把**当前画面**（含选中光环、拖动预览、导引线）导成 PNG。
  /// 和 [vrvExport] 的区别：那个是重新排版出来的一张干净谱子，
  /// 这个是"截图"，用来核对交互反馈到底长什么样。
  window.vrvSnap = function (factor) {
    var svg = svgRoot();
    if (!svg) { post({ type: 'png', page: 0, data: null }); return; }
    try {
      var vb = (svg.getAttribute('viewBox') || '0 0 794 1123').split(/\s+/);
      var w = parseFloat(vb[2]) || 794, h = parseFloat(vb[3]) || 1123;
      var clone = svg.cloneNode(true);
      clone.setAttribute('xmlns', NS);
      clone.setAttribute('xmlns:xlink', 'http://www.w3.org/1999/xlink');
      clone.setAttribute('width', w);
      clone.setAttribute('height', h);
      var text = new XMLSerializer().serializeToString(clone);
      var blob = new Blob([text], { type: 'image/svg+xml;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var img = new Image();
      img.onload = function () {
        var f = factor || 2;
        var c = document.createElement('canvas');
        c.width = Math.round(w * f);
        c.height = Math.round(h * f);
        var ctx = c.getContext('2d');
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(0, 0, c.width, c.height);
        ctx.drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url);
        post({ type: 'png', page: state.page, data: c.toDataURL('image/png') });
      };
      img.onerror = function () {
        URL.revokeObjectURL(url);
        post({ type: 'error', message: '导出当前画面失败' });
      };
      img.src = url;
    } catch (e) {
      post({ type: 'error', message: String(e) });
    }
  };

  /// 结构诊断：版面结构 + 量出来的刻度（拖动的准头全靠它们）
  window.vrvProbe = function () {
    var p = paper();
    var svg = svgRoot();
    function rectOf(el) {
      if (!el) { return null; }
      var r = el.getBoundingClientRect();
      return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
    }
    var first = p ? p.querySelector('g.note[id^="lipu-"]') : null;
    var hl = p ? p.querySelector('g.vrv-hl') : null;
    var out = {
      notes: p ? p.querySelectorAll('g.note[id^="lipu-"]').length : 0,
      measures: p ? p.querySelectorAll('g.measure').length : 0,
      staffs: p ? p.querySelectorAll('g.staff').length : 0,
      systems: p ? p.querySelectorAll('g.system').length : 0,
      stafflines: p ? p.querySelectorAll('.staffline').length : 0,
      space: staffSpacePx(first),
      spaceSource: spaceSource(first),
      selected: p ? p.querySelectorAll('g.note.vrv-selected').length : 0,
      hasRing: !!(hl && hl.querySelector('.vrv-ring')),
      ringRect: hl ? rectOf(hl.querySelector('.vrv-ring')) : null,
      noteRect: first ? rectOf(headOf(first)) : null,
      // 选中时符头本体要真的被"染色"（不只画个圈）
      headFill: first ? getComputedStyle(headOf(first)).fill : null,
      hlOpacity: hl ? getComputedStyle(hl).opacity : null,
      hlDim: !!(hl && hl.getAttribute('opacity')),
      ghost: p ? p.querySelectorAll('.vrv-ghost').length : 0,
      guide: p ? p.querySelectorAll('.vrv-guide').length : 0,
      hintShown: hintShown(),
      durBarShown: !!(durBarEl() && durBarEl().classList.contains('show')),
      accent: ACCENT,
      editBound: !!p.__vrvBound,
      events: EVCOUNT,
      hasPointerEvent: !!window.PointerEvent,
      // 休止符有没有真的画出来（AI 识谱结果里带停顿，这里是"看得见"的验证）
      rests: p ? p.querySelectorAll('g.rest').length : 0,
      noteheads: p ? p.querySelectorAll('g.notehead').length : 0,
      // 连音记号有没有画出来（tie = 同音高相邻；slur = 音高不同/不相邻）
      ties: p ? p.querySelectorAll('.tie').length : 0,
      tiePaths: p ? p.querySelectorAll('path[class*="tie"], g[class*="tie"]').length : 0,
      slurs: p ? p.querySelectorAll('.slur').length : 0,
      slurPaths: p ? p.querySelectorAll('path[class*="slur"], g[class*="slur"]').length : 0,
      mode: ED.mode,
      tieFrom: TIE.from,
      // 气泡菜单 / 拖动提示（都跟着音符走，不是固定横幅）
      bubbleShown: !!(bubbleEl() && bubbleEl().classList.contains('show')),
      bubbleOptions: bubbleEl() ? bubbleEl().querySelectorAll('.opt').length : 0,
      tipCount: p ? p.querySelectorAll('g.vrv-tip').length : 0,
      tipText: (p && p.querySelector('g.vrv-tip text')) ? p.querySelector('g.vrv-tip text').textContent : null,
      tipFont: (p && p.querySelector('g.vrv-tip text')) ? p.querySelector('g.vrv-tip text').getAttribute('font-size') : null,
      svgAttrs: svg ? {
        width: svg.getAttribute('width'), height: svg.getAttribute('height'),
        viewBox: svg.getAttribute('viewBox')
      } : null,
      paperRect: rectOf(p), svgRect: rectOf(svg),
      chain: [], classes: []
    };
    if (first) {
      out.beatPx = beatPx(first);
      var head = headOf(first);
      out.headRect = rectOf(head);
      out.localPerPx = localPerPx(head);
      try {
        var m = head.getScreenCTM();
        out.headCtm = [m.a, m.b, m.c, m.d, m.e, m.f].map(function (v) { return Math.round(v * 1000) / 1000; });
      } catch (e) {}
      var n = first;
      while (n && n !== document.documentElement && out.chain.length < 12) {
        var t = n.getAttribute ? (n.getAttribute('transform') || '') : '';
        out.chain.push((n.tagName || '?') + '.' + ((n.getAttribute && n.getAttribute('class')) || '') +
            (t ? ' [' + t + ']' : ''));
        n = n.parentNode;
      }
    }
    var seen = {}, all = p ? p.querySelectorAll('svg *') : [];
    for (var i = 0; i < all.length && out.classes.length < 28; i++) {
      var k = all[i].tagName + '.' + (all[i].getAttribute('class') || '');
      if (!seen[k]) { seen[k] = 1; out.classes.push(k); }
    }
    return JSON.stringify(out);
  };

  /// 客户端坐标 → 某元素父节点的局部坐标（Verovio 的组带 translate，不能直接用 getBBox）
  function toLocal(el, clientX, clientY) {
    var parent = el.parentNode || el;
    try {
      var m = parent.getScreenCTM();
      if (m && m.inverse) {
        if (window.DOMPoint) {
          var pt = new DOMPoint(clientX, clientY).matrixTransform(m.inverse());
          return { x: pt.x, y: pt.y };
        }
        var svg = svgRoot();
        if (svg && svg.createSVGPoint) {
          var q = svg.createSVGPoint();
          q.x = clientX; q.y = clientY;
          q = q.matrixTransform(m.inverse());
          return { x: q.x, y: q.y };
        }
      }
    } catch (e) {}
    return { x: clientX, y: clientY };
  }

  /// 符头元素（高亮和预览都按它算，别用整个 <g>：里面还有符干）。
  /// **必须跳过我们自己叠上去的 vrv-* 图层**，否则量到的是光环、越点越大。
  function headOf(g) {
    var kids = g.querySelectorAll('use, path, ellipse');
    for (var i = 0; i < kids.length; i++) {
      var own = kids[i];
      if (own.closest && own.closest('.vrv-hl, .vrv-ghost, .vrv-guide')) { continue; }
      return own;
    }
    return g;
  }

  function removeHl() {
    if (ED.hl && ED.hl.parentNode) { ED.hl.parentNode.removeChild(ED.hl); }
    ED.hl = null; ED.hlRing = null;
    if (ED.ghost && ED.ghost.parentNode) { ED.ghost.parentNode.removeChild(ED.ghost); }
    ED.ghost = null; ED.ghostPop = null;
    if (ED.guide && ED.guide.parentNode) { ED.guide.parentNode.removeChild(ED.guide); }
    ED.guide = null;
    removeTip();
    var p = paper();
    var sel = p ? p.querySelector('g.note.vrv-selected') : null;
    if (sel) { sel.classList.remove('vrv-selected'); }
    if (p) { p.classList.remove('vrv-editing'); }
  }

  function clearEdit() {
    var had = ED.id;
    removeHl();
    hideBubble();
    ED.id = null; ED.mode = 'none'; ED.dragging = false; ED.step = 0; ED.grid = 0;
    ED.tied = false;
    TIE.from = null;
    hideHint(); hideDurBar();
    if (had) { post({ type: 'editSelect', id: null, mode: 'none' }); }
  }
  window.vrvClearEdit = clearEdit;

  /// 选中：符头本体染色 + 光晕 + 脉冲光环（进入/改完还各带一次一次性动画）
  function selectNote(g, mode) {
    removeHl();
    hideBubble();
    ED.id = g.id; ED.mode = mode; ED.dragging = false; ED.step = 0; ED.grid = 0;
    g.classList.add('vrv-selected');
    var p = paper();
    if (p) { p.classList.add('vrv-editing'); }

    var head = headOf(g);
    var hr = head.getBoundingClientRect();
    var lp = ED.localPerPx || localPerPx(head);
    var c = toLocal(head, hr.left + hr.width / 2, hr.top + hr.height / 2);
    var hw = (hr.width / 2) * lp, hh = (hr.height / 2) * lp;
    ED.anchor = c; ED.halfW = hw; ED.halfH = hh; ED.localPerPx = lp;
    var accent = (mode === 'duration') ? ACCENT2 : ACCENT;

    // 竖线导引：目标拍位（想改位置时最有用）
    var st = g.closest ? g.closest('g.staff') : null;
    if (st) {
      var sr = st.getBoundingClientRect();
      var t = toLocal(head, hr.left + hr.width / 2, sr.top);
      var b2 = toLocal(head, hr.left + hr.width / 2, sr.bottom);
      ED.staffTop = t.y; ED.staffBottom = b2.y;
    } else {
      ED.staffTop = c.y - 40; ED.staffBottom = c.y + 40;
    }

    var wrap = el('g', { 'class': 'vrv-hl', 'pointer-events': 'none' });
    // 光晕
    wrap.appendChild(el('ellipse', {
      cx: c.x, cy: c.y, rx: hw * 2.3, ry: hh * 2.6,
      fill: accent, opacity: '0.22'
    }));
    // 外圈（脉冲 + 出现动画）
    var ring = el('ellipse', {
      cx: c.x, cy: c.y, rx: hw * 1.8, ry: hh * 2.1,
      fill: 'none', stroke: accent, 'stroke-width': Math.max(1.8, 2.4 * lp),
      'class': 'vrv-ring'
    });
    wrap.appendChild(ring);
    ED.hl = wrap; ED.hlRing = ring;
    // 插在音符**后面**：插在前面会让 headOf() 先找到光环，越点越大
    if (head.parentNode === g) { g.appendChild(wrap); }
    else if (head.parentNode) { head.parentNode.insertBefore(wrap, head.nextSibling); }

    // 刚改完（重排后接回选中）：再闪一下，指明"就是它变了"
    if (Date.now() < ED.flashUntil) {
      ED.flashUntil = 0;
      wrap.appendChild(el('ellipse', {
        cx: c.x, cy: c.y, rx: hw * 2.0, ry: hh * 2.3,
        fill: 'none', stroke: accent, 'stroke-width': Math.max(1.5, 2.2 * lp),
        'class': 'vrv-flash'
      }));
    }

    if (mode === 'duration') { renderDurBar(); showDurBar(); } else { hideDurBar(); }
    post({ type: 'editSelect', id: ED.id, mode: mode });
  }

  /// 外部（Dart）指定选中哪个音符
  window.vrvSelect = function (id, mode) {
    var g = document.getElementById(id);
    if (!g) { return false; }
    measureScales(g);
    selectNote(g, mode === 'duration' ? 'duration' : 'position');
    return true;
  };

  /// 拖动预览：一个跟着鼠标"滑"过去的半透明符头 + 竖线导引。
  /// 只改 transform，所以 CSS 过渡能让它逐格滑过去而不是瞬移。
  /// [stepPx]/[gridPx] 是本次拖动实际用的步长（触摸时有下限），
  /// 预览必须按同一步长走，否则"看到的落点"和"实际落点"会对不上。
  function showGhost(g, step, grid, stepPx, gridPx) {
    var head = headOf(g);
    var hr = head.getBoundingClientRect();
    var lp = ED.localPerPx || localPerPx(head);
    var c = ED.anchor || toLocal(head, hr.left + hr.width / 2, hr.top + hr.height / 2);
    var hw = ED.halfW || (hr.width / 2) * lp, hh = ED.halfH || (hr.height / 2) * lp;
    var sp = stepPx || (ED.spacePx / 2);
    var gp = gridPx || ED.gridPx;

    if (!ED.ghost) {
      var wrap = el('g', { 'class': 'vrv-ghost', 'pointer-events': 'none' });
      wrap.appendChild(el('ellipse', {
        cx: c.x, cy: c.y, rx: hw * 1.15, ry: hh * 1.25,
        fill: ACCENT, opacity: '0.85'
      }));
      var pop = el('g', { 'class': 'pop' });
      pop.appendChild(el('ellipse', {
        cx: c.x, cy: c.y, rx: hw * 2.1, ry: hh * 2.4,
        fill: 'none', stroke: ACCENT, 'stroke-width': Math.max(1.6, 2 * lp)
      }));
      wrap.appendChild(pop);
      if (head.parentNode) { head.parentNode.appendChild(wrap); }
      ED.ghost = wrap; ED.ghostPop = pop;

      if (!ED.guide && head.parentNode) {
        ED.guide = el('line', {
          x1: c.x, y1: ED.staffTop, x2: c.x, y2: ED.staffBottom,
          stroke: ACCENT, 'stroke-width': Math.max(1, 1.4 * lp),
          'stroke-dasharray': (6 * lp) + ' ' + (5 * lp), opacity: '0.55',
          'class': 'vrv-guide', 'pointer-events': 'none'
        });
        head.parentNode.appendChild(ED.guide);
      }
    }

    var dx = grid * gp * lp;
    var dy = -step * sp * lp;
    ED.ghost.style.transform = 'translate(' + dx + 'px,' + dy + 'px)';
    if (ED.guide) { ED.guide.style.transform = 'translateX(' + dx + 'px)'; }
    // 拖动中把原来的位置压暗，视觉焦点留在预览符头上。
    // 用 opacity **属性**而不是纯 CSS class：这样静态导出（vrvSnap）里也能看到，
    // 而 CSS 那边仍然有过渡动画。
    if (ED.hl) { ED.hl.setAttribute('opacity', '0.3'); }
    // 每变一格弹一下，手感上能"数"出来改了几格
    if (step !== ED.lastStep || grid !== ED.lastGrid) {
      ED.lastStep = step; ED.lastGrid = grid;
      replay(ED.ghost, 'vrv-pop');
    }
  }

  /// 量好这个音符附近的三把尺子（都是**屏幕像素**）：
  /// 一个间多高、一拍多宽、屏幕上 1px 等于局部坐标多少
  function measureScales(g) {
    var head = headOf(g);
    var space = staffSpacePx(g);
    ED.spacePx = space > 0 ? space : 10;
    ED.localPerPx = localPerPx(head);
    var bp = beatPx(g);
    // 一格 = 十六分音符；量不到"每拍多宽"就退回固定手感（约 1.6 个间一格）
    ED.gridPx = bp > 0 ? bp * 0.25 : ED.spacePx * 1.6;
  }

  /// 开始一次可能的拖动：先量好页面刻度
  function beginDrag(g, ev) {
    measureScales(g);
    ED.sx = ev.clientX; ED.sy = ev.clientY;
    ED.dragging = false; ED.step = 0; ED.grid = 0;
    ED.lastStep = 0; ED.lastGrid = 0;
  }

  function onDown(ev) {
    var isPointer = ev.type.indexOf('pointer') === 0;
    if (isPointer) { SAW_POINTER = true; } else if (SAW_POINTER) { return; }
    // 手指重新落回谱面：上一段浮层手势已经结束
    releaseOverlay();
    // 命中测试容差**收紧**（用户反馈范围太大容易误触）：
    // 手指 12px、鼠标 8px；"连音选点"模式下放宽，方便点第二个音。
    var touch = ev.pointerType === 'touch' || ev.type.indexOf('touch') === 0;
    var tol = ED.mode === 'tiePick' ? 26 : (touch ? 12 : 8);
    var g = pickNote(ev.target, ev.clientX, ev.clientY, tol, ED.mode === 'tiePick');
    noteEvent(g ? 'down' : 'miss');
    if (!g) { if (ED.id) { clearEdit(); } return; }

    // 正在等"连音的另一个音符"：这一下点在别的音符上就直接连起来
    if (ED.mode === 'tiePick' && TIE.from && g.id !== TIE.from) {
      markOverlay();
      post({ type: 'edit', action: 'tieTo', id: g.id, from: TIE.from });
      TIE.from = null;
      removeTip();
      if (ev.preventDefault) { ev.preventDefault(); }
      return;
    }

    // 这一按到底是"点一下"还是"按住拖"——**按下时不做判断**。
    // 以前是按下就切换模式，于是"选中后再按住拖"会被当成第二次点击
    // 切成时值模式，拖动被吃掉，用户只能两个指头凑合（手机上的实际反馈）。
    // 现在：松手且没移动才算"点击"，移动了就是拖动。
    CLICK.id = g.id;
    CLICK.wasSelected = (ED.id === g.id);
    CLICK.moved = false;
    if (ED.id !== g.id) {
      beginDrag(g, ev);
      selectNote(g, 'position'); // 换音符：选中并允许同一次手势接着拖
    } else {
      beginDrag(g, ev);          // 同一个音符：先只准备拖动
    }
    if (ev.preventDefault) { ev.preventDefault(); }
  }

  function onMove(ev) {
    if (!ED.id || ED.mode !== 'position') { return; }
    if (ev.type.indexOf('pointer') !== 0 && SAW_POINTER) { return; }
    var dx = ev.clientX - ED.sx, dy = ev.clientY - ED.sy;
    // 死区要跟着刻度走：一个间本来就很小，死区比"一级"还大就拖不动了。
    // 触摸要留更大的余量，否则"点一下"会被当成拖动而误改谱。
    var touch = ev.pointerType === 'touch' || ev.type.indexOf('touch') === 0;
    var dead = touch
        ? Math.max(8, (ED.spacePx || 10) * 0.9)
        : Math.max(2, Math.min(3.5, (ED.spacePx || 10) * 0.45));
    if (!ED.dragging && (Math.abs(dx) + Math.abs(dy)) < dead) { return; }
    var g = document.getElementById(ED.id);
    if (!g) { return; }
    ED.dragging = true;
    CLICK.moved = true;
    noteEvent('move');
    // 一把尺子管上下（一个间 = 一级），一把管左右（一拍 = 4 格）。
    // 手机上"一个间"只有 3~5px，按 1:1 算会灵敏到没法控制，
    // 所以给一步设下限：触摸一级至少 9px、一格至少 22px。
    var stepPx = touch ? Math.max((ED.spacePx || 10) / 2, 9) : (ED.spacePx || 10) / 2;
    var gridPx = touch ? Math.max(ED.gridPx, 22) : ED.gridPx;
    var step = Math.round(-dy / stepPx);
    var grid = gridPx > 0 ? Math.round(dx / gridPx) : 0;
    ED.step = step; ED.grid = grid;
    showGhost(g, step, grid, stepPx, gridPx);
    // 提示贴在音符上方（跟着拖动一起移动、跟着谱面缩放），不再用固定大小的顶部横幅
    if (ED.ghost) {
      var ax = (ED.anchor ? ED.anchor.x : 0) + grid * gridPx * (ED.localPerPx || 1);
      var ay = (ED.anchor ? ED.anchor.y : 0) - step * stepPx * (ED.localPerPx || 1)
          - (ED.halfH || 6) * 2.6;
      showTip(ax, ay,
          (step === 0 ? '音高不变' : '音高 ' + (step > 0 ? '+' : '') + step + ' 级') +
          ' · ' +
          (grid === 0 ? '位置不变' : '位置 ' + (grid > 0 ? '+' : '') + grid + ' 格'),
          ED.localPerPx || 1, Math.max(9, (ED.spacePx || 10) * 1.15));
    }
    if (ev.preventDefault) { ev.preventDefault(); }
  }

  function onUp(ev) {
    // 刚才是点在/滑在浮层上（时值条、气泡）→ 谱面这边什么都不做
    if (OVERLAY.busy) { return; }
    if (ev && ev.type.indexOf('pointer') !== 0 && SAW_POINTER) { return; }
    var cancelled = !!(ev && (ev.type === 'pointercancel' || ev.type === 'touchcancel'));
    var wasDrag = ED.dragging, id = ED.id, step = ED.step, grid = ED.grid;
    var clickId = CLICK.id, clickWasSelected = CLICK.wasSelected;
    ED.dragging = false;
    if (ED.ghost && ED.ghost.parentNode) { ED.ghost.parentNode.removeChild(ED.ghost); }
    ED.ghost = null; ED.ghostPop = null;
    if (ED.guide && ED.guide.parentNode) { ED.guide.parentNode.removeChild(ED.guide); }
    ED.guide = null;
    removeTip();
    if (ED.hl) { ED.hl.removeAttribute('opacity'); }
    hideHint();
    // 手势被系统打断（pointercancel）就当没拖过，不改谱
    if (cancelled || !id) { return; }

    // 没有移动 = 一次真正的"点击"：
    //   · 点已选中的音符 → 弹出气泡菜单（时值/连音/插入/升降调）
    //   · 点别的音符时在 onDown 里已经选中了，这里不用再切
    if (!wasDrag) {
      var tg = clickId ? document.getElementById(clickId) : null;
      if (tg && clickWasSelected) {
        if (ED.mode === 'position') {
          ED.mode = 'menu';
          showBubble(tg);
          post({ type: 'editSelect', id: ED.id, mode: 'menu' });
        } else if (ED.mode === 'menu' || ED.mode === 'tiePick') {
          // 气泡开着 / 正在等连音的第二个音：这一下别把它清掉，
          // 让用户自己用 ✕ 或点空白处结束（手机上很容易误清）
        } else {
          clearEdit();
        }
      }
      return;
    }
    if (step === 0 && grid === 0) { return; }
    // 重排之后要闪一下：让用户看到"就是它被改了"
    ED.flashUntil = Date.now() + 1500;
    post({ type: 'edit', action: 'move', id: id, step: step, grid: grid });
  }

  /// 这个音符当前的时值（拍，附点算进去）
  function currentDur() {
    if (!ED.id) { return 0; }
    try {
      var a = tk.getElementAttr(ED.id) || {};
      var base = DUR_BEATS[String(a.dur || '')];
      if (base === undefined) { return 0; }
      var dots = parseInt(a.dots || '0', 10) || 0;
      if (dots === 1) { base = base * 1.5; } else if (dots === 2) { base = base * 1.75; }
      return base;
    } catch (e) { return 0; }
  }

  /// 竖排时值条：**上下滑动**选几分音符（上 = 更长），也可以直接点某一行。
  /// 拖动过程中只高亮，**松手才提交**——免得每挪一格就重排一次。
  /// 时值气泡：贴着音符弹出（和气泡菜单同一套定位逻辑）
  function placeDurBar(g) {
    var e = durBarEl();
    if (!e || !g) { return; }
    var head = headOf(g);
    var r = head.getBoundingClientRect();
    var vw = document.documentElement.clientWidth;
    var vh = document.documentElement.clientHeight;
    var w = e.offsetWidth || 120, h = e.offsetHeight || 300;
    var left = r.right + 10;
    if (left + w > vw - 8) { left = r.left - w - 10; }
    if (left < 8) { left = Math.min(Math.max(8, r.left + r.width / 2 - w / 2), vw - w - 8); }
    var top = r.top + r.height / 2 - h / 2;
    top = Math.min(Math.max(8, top), Math.max(8, vh - h - 8));
    e.style.left = Math.round(left) + 'px';
    e.style.top = Math.round(top) + 'px';
    e.style.right = 'auto';
  }

  /// 在时值条上"上下滑"到某一档（按 data-t 找到那一行，滑过去再松手）
  function renderDurBar() {
    var e = durBarEl();
    if (!e) { return; }
    var cur = currentDur();
    var hasDot = false;
    if (ED.id) {
      try { hasDot = (parseInt((tk.getElementAttr(ED.id) || {}).dots || '0', 10) || 0) > 0; } catch (err) {}
    }
    if (ED.id) { ED.dot = hasDot; }
    var html = '<div class="head">时值</div>';
    for (var i = 0; i < DURS.length; i++) {
      var cls = [];
      if (ED.dot && Math.abs(DURS[i].t * 1.5 - cur) < 1e-6) { cls.push('cur'); }
      if (!ED.dot && Math.abs(DURS[i].t - cur) < 1e-6) { cls.push('cur'); }
      html += '<div class="tick' + (cls.length ? ' ' + cls.join(' ') : '') +
          '" data-t="' + DURS[i].t + '"><span class="lbl">' + DURS[i].label + '</span></div>';
    }
    html += '<div class="foot"><button data-dot="1"' + (ED.dot ? ' class="on"' : '') +
        '>附点</button><button data-cancel="1">完成</button></div>';
    e.innerHTML = html;

    var ticks = e.querySelectorAll('.tick');
    for (var j = 0; j < ticks.length; j++) {
      ticks[j].addEventListener('click', onDurClick);
    }
    var foot = e.querySelectorAll('.foot button');
    for (var k = 0; k < foot.length; k++) { foot[k].addEventListener('click', onDurClick); }
  }

  /// 手指/鼠标落在哪一行上（竖条自己处理，页面不参与）
  function tickAt(clientY) {
    var e = durBarEl();
    if (!e) { return null; }
    var ticks = e.querySelectorAll('.tick');
    for (var i = 0; i < ticks.length; i++) {
      var r = ticks[i].getBoundingClientRect();
      if (clientY >= r.top && clientY <= r.bottom) { return ticks[i]; }
    }
    // 落在条子范围内的缝隙/边缘：取最近的一行
    var best = null, bestD = 1e9;
    for (var j = 0; j < ticks.length; j++) {
      var rr = ticks[j].getBoundingClientRect();
      var d = Math.abs(clientY - (rr.top + rr.height / 2));
      if (d < bestD) { bestD = d; best = ticks[j]; }
    }
    return best;
  }

  function highlightTick(node) {
    var e = durBarEl();
    if (!e || !node) { return; }
    var ticks = e.querySelectorAll('.tick');
    for (var i = 0; i < ticks.length; i++) {
      ticks[i].classList.toggle('hover', ticks[i] === node);
    }
  }

  /// 竖条上的拖动：按下开始、上下滑动换行、松手提交
  function durDown(ev) {
    if (!ED.id) { return; }
    markOverlay();
    DURDRAG.active = true;
    DURDRAG.applied = false;
    var t = tickAt(ev.clientY);
    if (t) { highlightTick(t); }
    if (ev.preventDefault) { ev.preventDefault(); }
  }

  function durMove(ev) {
    if (!DURDRAG.active) { return; }
    markOverlay();
    var t = tickAt(ev.clientY);
    if (t) { highlightTick(t); }
    if (ev.preventDefault) { ev.preventDefault(); }
  }

  function durUp(ev) {
    if (!DURDRAG.active) { return; }
    DURDRAG.active = false;
    markOverlay();
    var t = tickAt(ev.clientY);
    highlightTick(null);
    if (!t) { return; }
    var beats = parseFloat(t.getAttribute('data-t'));
    if (!beats || !ED.id) { return; }
    ED.flashUntil = Date.now() + 1500;
    post({ type: 'edit', action: 'duration', id: ED.id, ticks: beats * (ED.dot ? 1.5 : 1) });
  }

  function onDurClick(ev) {
    var b = ev.currentTarget;
    if (b.getAttribute && b.getAttribute('data-dot')) {
      ED.dot = !ED.dot;
      b.className = ED.dot ? 'on' : '';
      return;
    }
    if (b.getAttribute && b.getAttribute('data-cancel')) { clearEdit(); return; }
    var beats = parseFloat(b.getAttribute ? b.getAttribute('data-t') : '');
    if (!beats || !ED.id) { return; }
    ED.flashUntil = Date.now() + 1500;
    post({ type: 'edit', action: 'duration', id: ED.id, ticks: beats * (ED.dot ? 1.5 : 1) });
  }

  /// 时值条的拖动状态
  var DURDRAG = { active: false, applied: false };
  /// 「连音」等待点第二个音符
  var TIE = { from: null };

  function bindDurBar() {
    var e = durBarEl();
    if (!e || e.__vrvBound) { return; }
    e.__vrvBound = true;
    e.addEventListener('pointerdown', durDown, { passive: false });
    e.addEventListener('pointermove', durMove, { passive: false });
    window.addEventListener('pointerup', durUp);
    window.addEventListener('pointercancel', function () {
      if (DURDRAG.active) { DURDRAG.active = false; highlightTick(null); }
    });
    // 只有鼠标/触摸事件的 WebView 也照样能用
    e.addEventListener('mousedown', durDown);
    e.addEventListener('mousemove', durMove);
    window.addEventListener('mouseup', durUp);
    e.addEventListener('touchstart', function (ev) {
      if (ev.touches && ev.touches[0]) { durDown(ev.touches[0]); }
    }, { passive: false });
    e.addEventListener('touchmove', function (ev) {
      if (ev.touches && ev.touches[0]) { durMove(ev.touches[0]); }
    }, { passive: false });
    window.addEventListener('touchend', function (ev) {
      if (ev.changedTouches && ev.changedTouches[0]) {
        durUp(ev.changedTouches[0]);
      } else { durUp(ev); }
    });
  }

  /// 气泡必须**在 pointerdown 时就声明"这一下是我的"**。
  ///
  /// 手机上真实的手指是 pointerdown → pointerup → click：
  /// 如果不在 pointerdown 就拦下来，window 上的 pointerup 会先跑到谱面的收尾逻辑，
  /// 那里会把编辑状态清掉（`clearEdit()` 隐藏气泡、ED.id 置空），
  /// 等动作触发时 ED.id 已经没了 —— 按钮全部没反应。
  ///
  /// ⚠️ 这里**绝不能 preventDefault**：把 touchstart/pointerdown 取消掉，
  /// 浏览器就不再派发 click，按钮反而彻底点不动（踩过一次）。
  function bindBubble() {
    var e = bubbleEl();
    if (!e || e.__vrvBound) { return; }
    e.__vrvBound = true;
    function claim() { markOverlay(); }
    e.addEventListener('pointerdown', claim);
    e.addEventListener('mousedown', claim);
    e.addEventListener('touchstart', claim);
    // 兜底：万一某个选项自身的指针事件没派发到，就在容器上按坐标找一次
    e.addEventListener('touchend', function (ev) {
      var t = (ev.changedTouches && ev.changedTouches[0]) || null;
      if (!t) { return; }
      var node = bubbleOptionAt(t.clientX, t.clientY);
      if (node) { bindFire(node, ev); }
    });
  }

  /// 按坐标找气泡里被点中的那个选项
  function bubbleOptionAt(x, y) {
    var e = bubbleEl();
    if (!e) { return null; }
    var opts = e.querySelectorAll('.opt');
    for (var i = 0; i < opts.length; i++) {
      var r = opts[i].getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) { return opts[i]; }
    }
    return null;
  }

  /// 统一的"执行一次选项动作"（带去重）
  function bindFire(node, ev) {
    var now = Date.now();
    if (now - BUBBLE.lastFire < 400) { return; }
    BUBBLE.lastFire = now;
    if (ev && ev.preventDefault) { ev.preventDefault(); }
    onBubblePick({ currentTarget: node });
  }

  function bindEdit() {
    var p = paper();
    if (!p || p.__vrvBound) { return; }
    p.__vrvBound = true;
    renderDurBar();
    bindDurBar();
    bindBubble();

    // PointerEvent 和鼠标/触摸**两套都绑**：不同 WebView 递进来的事件不一样，
    // 只绑 pointer 的话碰上"只给 mouse/touch"的环境就是"点了完全没反应"。
    // 谁先来谁生效（Chromium 里 pointer 先到），后到的重复事件直接丢掉，
    // 否则一次点击会被当成两下 → 直接跳进时值模式。
    p.addEventListener('pointerdown', onDown, { passive: false });
    p.addEventListener('pointermove', onMove, { passive: false });
    window.addEventListener('pointerup', onUp);
    window.addEventListener('pointercancel', onUp);

    p.addEventListener('mousedown', onDown);
    p.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    p.addEventListener('touchstart', function (e) {
      if (e.touches && e.touches[0]) { onDown(e.touches[0]); }
    }, { passive: false });
    p.addEventListener('touchmove', function (e) {
      if (e.touches && e.touches[0]) { onMove(e.touches[0]); }
    }, { passive: false });
    window.addEventListener('touchend', onUp);
    window.addEventListener('touchcancel', onUp);
  }

  if (verovio.module.calledRun) { window.vrvInit(); }
  else { verovio.module.onRuntimeInitialized = window.vrvInit; }
})();
''';
