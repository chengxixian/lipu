/// 波浪进度条：一条圆头粗正弦波表示进度，末端带圆点，底部是浅色轨道
///
/// 样式对齐常见 App（如本地 AI 绘图工具）的"波浪进度"观感：
/// 进度部分是一条会流动的正弦线，而不是平直色条。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class WavyProgressBar extends StatefulWidget {
  /// 0..1；null 表示进度未知（波浪整条流动）
  final double? value;
  final double height;
  final Color? color;
  final Color? trackColor;

  /// 一个完整波长的像素长度（越大波形越舒展）
  final double wavelength;

  const WavyProgressBar({
    super.key,
    required this.value,
    this.height = 14,
    this.color,
    this.trackColor,
    this.wavelength = 34,
  });

  @override
  State<WavyProgressBar> createState() => _WavyProgressBarState();
}

class _WavyProgressBarState extends State<WavyProgressBar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: WavyPainter(
            progress: widget.value,
            phase: _controller.value,
            color: widget.color ?? scheme.primary,
            trackColor: widget.trackColor ?? scheme.surfaceContainerHighest,
            height: widget.height,
            wavelength: widget.wavelength,
          ),
        ),
      ),
    );
  }
}

/// 波浪进度条画笔（公开出去便于离屏渲染/测试）
class WavyPainter extends CustomPainter {
  final double? progress;
  final double phase;
  final Color color;
  final Color trackColor;
  final double height;
  final double wavelength;

  WavyPainter({
    required this.progress,
    required this.phase,
    required this.color,
    required this.trackColor,
    required this.height,
    required this.wavelength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final radius = size.height / 2;

    // 轨道：一条细圆头线
    canvas.drawLine(
      Offset(radius, midY),
      Offset(size.width - radius, midY),
      Paint()
        ..color = trackColor
        ..strokeWidth = math.max(2, size.height * 0.22)
        ..strokeCap = StrokeCap.round,
    );

    final fillWidth = progress == null ? size.width : size.width * progress!.clamp(0.0, 1.0);
    if (fillWidth <= 1) return;

    // 波浪：振幅取高度的一小半，圆头粗线
    final amplitude = size.height * 0.26;
    final stroke = math.max(2.5, size.height * 0.40);
    final path = Path();
    final k = 2 * math.pi / wavelength;
    final left = radius * 0.6;
    final right = math.min(fillWidth, size.width - radius * 0.6);
    if (right <= left) return;
    var started = false;
    for (var x = left; x <= right; x += 1.5) {
      final y = midY + math.sin((x - left) * k - phase * 2 * math.pi) * amplitude;
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 末端圆点（进度头）
    final endY = midY + math.sin((right - left) * k - phase * 2 * math.pi) * amplitude;
    canvas.drawCircle(Offset(right, endY), size.height * 0.30, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant WavyPainter old) =>
      old.phase != phase || old.progress != progress || old.color != color || old.trackColor != trackColor;
}
