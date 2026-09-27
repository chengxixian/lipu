/// 钢琴卷帘：显示音高轨迹与切分出来的音符，可点选删除/恢复（人工校正）
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../transcribe/melody.dart';

const List<String> _noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

String midiName(int midi) => '${_noteNames[((midi % 12) + 12) % 12]}${midi ~/ 12 - 1}';

bool isBlackKey(int midi) {
  const black = {1, 3, 6, 8, 10};
  return black.contains(((midi % 12) + 12) % 12);
}

class PianoRollView extends StatefulWidget {
  final MelodyAnalysis analysis;
  final ValueChanged<int> onToggleNote;
  final double height;

  const PianoRollView({
    super.key,
    required this.analysis,
    required this.onToggleNote,
    this.height = 260,
  });

  @override
  State<PianoRollView> createState() => _PianoRollViewState();
}

class _PianoRollViewState extends State<PianoRollView> {
  double _zoom = 1.0;
  final ScrollController _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = widget.analysis;
    final duration = math.max(0.5, a.durationSec);
    final viewWidth = math.max(320.0, MediaQuery.of(context).size.width - 64) * _zoom;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: widget.height,
          child: Scrollbar(
            controller: _hScroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _hScroll,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: viewWidth,
                height: widget.height,
                child: GestureDetector(
                  onTapUp: (details) {
                    final idx = _hitTest(details.localPosition, viewWidth, widget.height, duration);
                    if (idx != null) widget.onToggleNote(idx);
                  },
                  child: CustomPaint(
                    painter: PianoRollPainter(
                      analysis: a,
                      duration: duration,
                      background: scheme.surfaceContainerLow,
                      gridLine: scheme.outlineVariant,
                      barLine: scheme.primary.withValues(alpha: 0.55),
                      blackKeyRow: scheme.surfaceContainerHighest,
                      cLabel: scheme.onSurfaceVariant,
                      trackColor: scheme.tertiary,
                      noteColor: scheme.primary,
                      removedColor: scheme.error.withValues(alpha: 0.55),
                      textColor: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Row(
          children: [
            const Icon(Icons.zoom_out, size: 18),
            Expanded(
              child: Slider(
                min: 1,
                max: 8,
                value: _zoom,
                onChanged: (v) => setState(() => _zoom = v),
              ),
            ),
            const Icon(Icons.zoom_in, size: 18),
            const SizedBox(width: 8),
            Text('点音符可删除/恢复', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      ],
    );
  }

  /// 命中测试：返回被点到的音符序号
  int? _hitTest(Offset p, double width, double height, double duration) {
    final a = widget.analysis;
    final layout = _RollLayout(a, duration, width, height);
    final midi = layout.yToMidi(p.dy);
    final t = layout.xToTime(p.dx);
    for (var i = 0; i < a.notes.length; i++) {
      final n = a.notes[i];
      if (t >= n.startSec - 0.02 && t <= n.endSec + 0.02 && (n.midi - midi).abs() <= 0.6) return i;
    }
    return null;
  }
}

/// 坐标换算（画家与命中测试共用）
class _RollLayout {
  final double gutter = 42;
  final MelodyAnalysis analysis;
  final double duration;
  final double width;
  final double height;
  final int minMidi;
  final int maxMidi;

  _RollLayout(this.analysis, this.duration, this.width, this.height)
      : minMidi = _bound((analysis.notes.isEmpty
                ? 60
                : analysis.notes.map((n) => n.midiRound).reduce(math.min)) -
            3),
        maxMidi = _bound((analysis.notes.isEmpty
                ? 72
                : analysis.notes.map((n) => n.midiRound).reduce(math.max)) +
            3);

  static int _bound(int v) => v.clamp(21, 108);

  int get rows => math.max(8, maxMidi - minMidi + 1);
  double get rowH => height / rows;
  double get plotW => math.max(1, width - gutter);

  double timeToX(double t) => gutter + (t / duration) * plotW;
  double xToTime(double x) => ((x - gutter) / plotW) * duration;
  double midiToY(double midi) => (maxMidi - midi + 0.5) * rowH;
  double yToMidi(double y) => maxMidi - (y / rowH) + 0.5;
}

class PianoRollPainter extends CustomPainter {
  final MelodyAnalysis analysis;
  final double duration;
  final Color background, gridLine, barLine, blackKeyRow, cLabel, trackColor, noteColor, removedColor, textColor;

  PianoRollPainter({
    required this.analysis,
    required this.duration,
    required this.background,
    required this.gridLine,
    required this.barLine,
    required this.blackKeyRow,
    required this.cLabel,
    required this.trackColor,
    required this.noteColor,
    required this.removedColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final layout = _RollLayout(analysis, duration, size.width, size.height);
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    // 黑键行底色 + 左侧音名
    for (var midi = layout.minMidi; midi <= layout.maxMidi; midi++) {
      final y = layout.midiToY(midi.toDouble());
      final rect = Rect.fromLTWH(layout.gutter, y - layout.rowH / 2, layout.plotW, layout.rowH);
      if (isBlackKey(midi)) {
        canvas.drawRect(rect, Paint()..color = blackKeyRow);
      }
      if (midi % 12 == 0) {
        canvas.drawLine(
          Offset(layout.gutter, y + layout.rowH / 2),
          Offset(size.width, y + layout.rowH / 2),
          Paint()
            ..color = gridLine
            ..strokeWidth = 1,
        );
        _text(canvas, midiName(midi), Offset(4, y - layout.rowH / 2 + 1), 10, cLabel);
      }
    }

    // 时间网格：按拍与按小节
    final bpm = analysis.bpm > 0 ? analysis.bpm : 90.0;
    final secPerBeat = 60.0 / bpm;
    var beat = 0;
    for (var t = 0.0; t <= duration + 1e-9; t += secPerBeat, beat++) {
      final x = layout.timeToX(t);
      final isBar = beat % 4 == 0;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = isBar ? barLine : gridLine
          ..strokeWidth = isBar ? 1.4 : 0.8,
      );
    }

    // 音高轨迹
    final trackPaint = Paint()
      ..color = trackColor.withValues(alpha: 0.75)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final path = Path();
    var started = false;
    for (final p in analysis.track) {
      if (!p.voiced) {
        started = false;
        continue;
      }
      final x = layout.timeToX(p.timeSec);
      final y = layout.midiToY(p.midi);
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, trackPaint);

    // 切分出来的音符
    for (var i = 0; i < analysis.notes.length; i++) {
      final n = analysis.notes[i];
      final x0 = layout.timeToX(n.startSec);
      final x1 = layout.timeToX(n.endSec);
      final y = layout.midiToY(n.midi);
      final h = math.max(6.0, layout.rowH * 0.86);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, y - h / 2, math.max(x1, x0 + 3), y + h / 2),
        const Radius.circular(3),
      );
      canvas.drawRRect(rect, Paint()..color = n.removed ? removedColor : noteColor);
      if (x1 - x0 > 26) {
        _text(canvas, midiName(n.midiRound), Offset(x0 + 3, y - h / 2), 9, Colors.white);
      }
    }

    // 录音/文件总时长标尺
    canvas.drawLine(
      Offset(layout.gutter, size.height - 1),
      Offset(size.width, size.height - 1),
      Paint()..color = gridLine,
    );
  }

  void _text(Canvas canvas, String s, Offset at, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant PianoRollPainter old) =>
      old.analysis != analysis || old.noteColor != noteColor || old.duration != duration;
}
