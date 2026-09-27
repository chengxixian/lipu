/// 乐谱页：用 **Verovio** 渲染五线谱（一页一张 A4，可翻页），并支持试听。
///
/// 渲染链路：Score IR → MusicXML → Verovio（WebView / WASM）→ SVG → A4 分页。
/// 如果 WebView / Verovio 起不来（比如系统缺 WebView2），自动退回内置排版引擎，
/// 保证"至少能看到谱"。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../audio/player.dart';
import '../core/chord_analysis.dart';
import '../core/musicxml.dart';
import '../render/staff_layout.dart';
import '../render/staff_painter.dart';
import '../render/verovio_view.dart';
import '../state.dart';
import 'common.dart';
import 'score_editor.dart';

/// A4 纸在 96dpi 下的逻辑尺寸（内置兜底引擎用）
const double kA4Width = 794;
const double kA4Height = 1123;

class ScoreView extends StatefulWidget {
  final AppState state;

  /// 测试用：外部注入渲染控制器（正常运行时页面自己建一个）
  final VerovioController? controller;

  const ScoreView({super.key, required this.state, this.controller});

  @override
  State<ScoreView> createState() => _ScoreViewState();
}

class _ScoreViewState extends State<ScoreView> {
  final ScorePlayer _player = ScorePlayer();
  late final VerovioController _vrv = widget.controller ?? VerovioController();
  bool _playing = false;
  bool _useFallback = false;
  bool _editing = false;
  String? _playStage;
  String? _renderedXml;
  String? _selectAfterRender;
  StreamSubscription<void>? _completeSub;

  /// 音源署名只需提示一次（CC-BY-3.0 要求的标注）
  static bool _audioCreditShown = false;

  @override
  void initState() {
    super.initState();
    _completeSub = _player.onComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
    widget.state.addListener(_onStateChanged);
    _vrv.addListener(_onVerovioChanged);
    // 在谱面上直接拖音符：WebView 里只负责"识别拖了多少"，改谱还是 Dart 这边做
    _vrv.onEdit = _handleEdit;
  }

  /// 谱面拖动 / 气泡菜单 → 改乐谱模型
  void _handleEdit(ScoreEditRequest r) {
    String? keep;
    switch (r.action) {
      case 'move':
        keep = widget.state.nudgeNote(r.id, stepDelta: r.step, gridDelta: r.grid);
        break;
      case 'duration':
        keep = widget.state.setNoteDuration(r.id, r.ticks);
        break;
      case 'tie':
        keep = widget.state.toggleTie(r.id);
        break;
      case 'tieTo':
        keep = widget.state.tieBetween(r.fromId, r.id);
        break;
      case 'chord':
        keep = widget.state.addChordTone(r.id);
        break;
      case 'delete':
        keep = widget.state.deleteNote(r.id); // 音符没了 → 不再选中
        break;
      case 'insert':
        keep = widget.state.insertAfter(r.id, asRest: r.asRest);
        break;
      case 'accidental':
        keep = widget.state.setToneAccidental(r.id, r.accidental);
        break;
      case 'octave':
        keep = widget.state.shiftOctave(r.id, r.step);
        break;
    }
    // 改完之后 id 可能变了（挪位置会换条目序号），等这一轮重排画完再把它选回来，
    // 这样"点一下改名位置、再点一下改时值"能连着做。
    if (keep != null) _selectAfterRender = keep;
  }

  /// 重排完了再把选中的音符接回来（每轮只用一次）
  void _restoreSelection() {
    final id = _selectAfterRender;
    if (id == null || _vrv.status.rendering) return;
    // 气泡开着 / 正在等"连音的第二个音"时不要抢选中：
    // selectNote 会把 JS 的编辑模式重置成 position，那一步就把连音流程打断了
    final m = _vrv.editMode;
    if (m == 'menu' || m == 'tiePick') return;
    _selectAfterRender = null;
    unawaited(_vrv.selectNote(id, mode: 'position'));
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _vrv.removeListener(_onVerovioChanged);
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    _syncScore();
  }

  void _onVerovioChanged() {
    if (!mounted) return;
    setState(() {});
    _syncScore();
    // 进入"气泡菜单/等连音第二个音"这类特殊模式时，把陈旧的"待恢复选中"丢掉，
    // 否则下一次重排完它会 selectNote(...,'position') 把模式重置掉
    final m = _vrv.editMode;
    if (m == 'menu' || m == 'tiePick') _selectAfterRender = null;
    if (!_vrv.status.rendering) _restoreSelection();
  }

  /// 乐谱变了就重新渲染。
  /// 缓存键要带上影响**排版**的开关（标题抬头），否则切"标题"不会重排。
  void _syncScore() {
    final score = widget.state.score;
    if (score == null || score.noteCount == 0) return;
    if (_useFallback) return;
    // 选中光环/拖动预览的颜色跟着当前主题（含系统动态色）
    if (mounted) {
      final scheme = Theme.of(context).colorScheme;
      unawaited(_vrv.setAccent(scheme.primary, scheme.tertiary));
    }
    final xml = toMusicXML(
      score,
      padIncompleteMeasures: true,
      includeLyrics: widget.state.showLyrics,
    );
    final key = '${widget.state.showTitle ? 'H' : '-'}${widget.state.showLyrics ? 'L' : '-'}|$xml';
    if (key == _renderedXml) return;
    _renderedXml = key;
    _vrv.render(xml, showHeader: widget.state.showTitle);
  }

  Future<void> _togglePlay() async {
    final score = widget.state.score;
    if (score == null) return;
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _playStage = '准备中…');
    try {
      await _player.play(
        score,
        tempoScale: widget.state.playbackTempo,
        onStage: (s) {
          if (mounted) setState(() => _playStage = s);
        },
      );
      if (!mounted) return;
      setState(() {
        _playing = true;
        _playStage = null;
      });
      if (_player.wasTruncated) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这首比较长，试听只合成了前 5 分钟')),
        );
      }
      if (!_audioCreditShown) {
        final credit = _player.sampleAttribution;
        if (credit.isNotEmpty) {
          _audioCreditShown = true;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('试听音源：$credit'), duration: const Duration(seconds: 5)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _playStage = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('播放失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final score = state.score;
    final scheme = Theme.of(context).colorScheme;

    if (score == null || score.noteCount == 0) {
      return const EmptyHint(
        icon: Icons.music_off_outlined,
        title: '还没有可显示的乐谱',
        message: '先在「识谱」页识别一张简谱图片，或直接输入简谱文本',
      );
    }

    final status = _vrv.status;
    final useFallback = _useFallback || status.error != null;

    // 和弦判读：只在有和弦时算一次，用于工具栏上的"和弦核对"入口
    final chordItems = analyzeScoreChords(score);
    return Column(
      children: [
        _Toolbar(
          state: state,
          playing: _playing,
          playStage: _playStage,
          editing: _editing,
          onToggleEdit: () => setState(() => _editing = !_editing),
          onTogglePlay: _togglePlay,
          onUseFallback: status.error == null ? null : () => setState(() => _useFallback = true),
          editReady: _vrv.editBound,
          onReloadEngine: () => _vrv.reload(),
          scheme: scheme,
          chordItems: chordItems,
        ),
        Expanded(
          child: useFallback
              ? _FallbackScore(score: score, state: state, scheme: scheme)
              : Stack(
                  children: [
                    Positioned.fill(child: VerovioScoreView(controller: _vrv)),
                    if (status.error != null)
                      Positioned.fill(
                        child: ColoredBox(
                          color: scheme.surface,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.error_outline, color: scheme.error, size: 36),
                                  const SizedBox(height: 12),
                                  Text('排版引擎出错：${status.error}',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: scheme.onSurfaceVariant)),
                                  const SizedBox(height: 16),
                                  FilledButton.tonal(
                                    onPressed: () => setState(() => _useFallback = true),
                                    child: const Text('改用内置排版'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (status.rendering || !status.ready)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          color: scheme.primary,
                          backgroundColor: Colors.transparent,
                        ),
                      ),
                    Positioned(left: 12, bottom: 12, child: _BottomBar(controller: _vrv)),
                  ],
                ),
        ),
        if (_editing)
          SizedBox(
            height: (MediaQuery.of(context).size.height * 0.42).clamp(220.0, 420.0),
            child: ScoreEditorPanel(state: state, onClose: () => setState(() => _editing = false)),
          ),
      ],
    );
  }
}

/// 底部浮条：翻页 + 缩放
class _BottomBar extends StatelessWidget {
  final VerovioController controller;
  const _BottomBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pages = controller.pages;
    final page = controller.page;
    final zoom = controller.zoom;
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '上一页',
              onPressed: page > 1 ? () => controller.gotoPage(page - 1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Text('$page / $pages',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '下一页',
              onPressed: page < pages ? () => controller.gotoPage(page + 1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
            Container(width: 1, height: 20, color: scheme.outlineVariant),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '缩小',
              onPressed: zoom > 0.55 ? () => controller.setZoom(zoom - 0.25) : null,
              icon: const Icon(Icons.zoom_out),
            ),
            TextButton(
              onPressed: (zoom - 1).abs() < 0.01 ? null : () => controller.setZoom(1),
              child: Text('适配宽度', style: TextStyle(fontSize: 11.5, color: scheme.primary)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '放大',
              onPressed: zoom < 5.5 ? () => controller.setZoom(zoom + 0.25) : null,
              icon: const Icon(Icons.zoom_in),
            ),
          ],
        ),
      ),
    );
  }
}

/// 兜底：内置排版引擎（Verovio 起不来时至少能看谱）
class _FallbackScore extends StatelessWidget {
  final dynamic score;
  final AppState state;
  final ColorScheme scheme;
  const _FallbackScore({required this.score, required this.state, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final doc = layoutScore(
      score,
      width: kA4Width,
      style: StaffStyle(
        showLyrics: state.showLyrics,
        showTitle: state.showTitle,
        space: 11,
        pageHeight: kA4Height,
      ),
    );
    final page = doc.pages.isEmpty ? null : doc.pages.first;
    final height = page?.height ?? doc.height;
    return Container(
      color: scheme.surfaceContainerHighest,
      child: Column(
        children: [
          // 兜底排版是 CustomPaint，没有"点音符拖动编辑"这回事，说清楚免得以为坏了
          Material(
            color: scheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 15, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '内置排版只用于兜底显示，不支持直接编辑（需要 Verovio 引擎）',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  width: kA4Width,
                  height: height,
                  color: Colors.white,
                  child: CustomPaint(
                    size: Size(kA4Width, height),
                    painter: StaffPainter(
                      StaffDocument(kA4Width, height, page?.ops ?? doc.ops),
                      color: const Color(0xFF1A1A1A),
                      accent: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 和弦核对面板：把每个和弦的判读结果列出来。
///
/// 为什么只"提示"不"自动改"：实测（钢琴采样渲染的已知和弦）Basic Pitch 的
/// 和弦 recall 是 100%，不准的地方主要是**八度泛音鬼影**；而鬼影与真实八度叠置
/// 在响度、时长、频谱残差上都分不开（真 C5 = 0.43/0.19s，鬼影 C5 = 0.48/0.21s），
/// 自动删除会连真的和弦音一起删掉。所以给用户看，由人决定。
Future<void> showChordReport(BuildContext context, List<ChordReportItem> items) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text('和弦核对（${items.length} 处）', style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '认出和弦名后，会标出"缺音 / 多音 / 八度重复"。'
            '扒谱的和弦不可能全对——尤其八度重复音，多半是低音的泛音被当成了高音，'
            '但算法分不出它和"真的八度叠置"，所以列出来让你看一眼再决定要不要删。',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          for (final it in items)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                it.guess.suspicious ? Icons.error_outline : Icons.check_circle_outline,
                size: 18,
                color: it.guess.suspicious ? scheme.primary : scheme.onSurfaceVariant,
              ),
              title: Text(
                '第 ${it.measureIndex} 小节 · ${it.guess.recognized ? it.guess.label : "认不出"}'
                '${it.guess.quality.isEmpty ? "" : "（${it.guess.quality}）"}',
                style: const TextStyle(fontSize: 13.5),
              ),
              subtitle: Text(
                '${it.tonesLabel}${it.guess.detail.isEmpty ? "" : " · ${it.guess.detail}"}',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Toolbar extends StatelessWidget {  final AppState state;
  final bool playing;
  final String? playStage;
  final bool editing;
  final VoidCallback onToggleEdit;
  final VoidCallback? onUseFallback;
  final VoidCallback onTogglePlay;

  /// 谱面交互层是否就绪（没就绪时只能看不能改，给一个重载入口）
  final bool editReady;
  final VoidCallback onReloadEngine;
  final ColorScheme scheme;

  /// 乐谱里的和弦判读结果（有和弦时才给入口）
  final List<ChordReportItem> chordItems;

  const _Toolbar({
    required this.state,
    required this.playing,
    required this.playStage,
    required this.editing,
    required this.onToggleEdit,
    required this.onTogglePlay,
    required this.onUseFallback,
    required this.editReady,
    required this.onReloadEngine,
    required this.scheme,
    this.chordItems = const [],
  });

  @override
  Widget build(BuildContext context) {
    final score = state.score;
    final stats = score == null
        ? ''
        : '${score.measures.length} 小节 · ${score.pitchCount} 个音'
            '${score.isGrandStaff ? ' · 大谱表' : ''}'
            ' · 调号 ${score.key.display} · ${score.meta.beats}/${score.meta.beatType}';
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: onTogglePlay,
                  icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded),
                  label: Text(playing ? '停止' : '试听'),
                ),
                const SizedBox(width: 8),
                if (playStage != null) ...[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(playStage!,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                ] else ...[
                  Text('速度 ×${state.playbackTempo.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      min: 0.5,
                      max: 1.6,
                      value: state.playbackTempo,
                      onChanged: state.setPlaybackTempo,
                    ),
                  ),
                ],
              ],
            ),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 直接在乐谱页编辑简谱：上半屏看谱、下半屏改字
                FilterChip(
                  avatar: const Icon(Icons.edit_note_outlined, size: 18),
                  label: const Text('编辑乐谱'),
                  selected: editing,
                  onSelected: (_) => onToggleEdit(),
                ),
                FilterChip(
                  label: const Text('歌词'),
                  selected: state.showLyrics,
                  onSelected: state.toggleLyrics,
                ),
                FilterChip(
                  label: const Text('标题'),
                  selected: state.showTitle,
                  onSelected: state.toggleTitle,
                ),
                if (onUseFallback != null)
                  TextButton(onPressed: onUseFallback, child: const Text('内置排版')),
                TextButton.icon(
                  onPressed: state.canUndo ? state.undo : null,
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('撤销'),
                ),
                if (!editReady)
                  ActionChip(
                    avatar: Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
                    label: Text('交互未就绪，点此重载',
                        style: TextStyle(fontSize: 11, color: scheme.error)),
                    visualDensity: VisualDensity.compact,
                    onPressed: onReloadEngine,
                  ),
                Text(stats, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                // 有和弦时给一个"和弦核对"入口：把每个和弦判读成 C/Am7…，
                // 并标出缺音/多音/八度重复——扒谱的和弦不可能全对，但不自动改，
                // 让用户看一眼再决定（实测自动去泛音不可靠，见 chord_analysis.dart）。
                if (chordItems.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  ActionChip(
                    avatar: Icon(
                      chordItems.any((c) => c.guess.suspicious)
                          ? Icons.music_note_outlined
                          : Icons.check_circle_outline,
                      size: 16,
                      color: chordItems.any((c) => c.guess.suspicious) ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    label: Text(chordSummary(chordItems), style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => showChordReport(context, chordItems),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 内置引擎的 PNG 渲染（Verovio 不可用时的兜底）
Future<Uint8List?> renderPagePngFallback(
  dynamic score, {
  double width = kA4Width,
  double pageHeight = kA4Height,
  double factor = 2.5,
  bool showLyrics = true,
  bool showTitle = true,
  int pageIndex = 0,
}) async {
  final doc = layoutScore(
    score,
    width: width,
    style: StaffStyle(
      showLyrics: showLyrics,
      showTitle: showTitle,
      space: 11,
      pageHeight: pageHeight,
    ),
  );
  final pages = doc.pages.isEmpty ? null : doc.pages;
  if (pages == null || pageIndex >= pages.length) return null;
  final page = pages[pageIndex];
  final recorder = ui.PictureRecorder();
  final outW = width * factor;
  final outH = page.height * factor;
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, outW, outH));
  canvas.scale(factor);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, page.height), Paint()..color = const Color(0xFFFFFFFF));
  StaffPainter(StaffDocument(width, page.height, page.ops),
          color: const Color(0xFF111111), accent: const Color(0xFF6750A4))
      .paint(canvas, Size(width, page.height));
  final image = await recorder.endRecording().toImage(outW.ceil(), outH.ceil());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data?.buffer.asUint8List();
}
