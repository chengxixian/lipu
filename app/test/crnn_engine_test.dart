/// CRNN 解码器测试（纯函数，不需要 ONNX 运行时）。
///
/// **这些断言写的是官方解码器的语义**（`piano_transcription_inference`：
/// `get_binarized_output_from_regression` + `note_detection_with_onset_offset_regress`），
/// 不是我自己发明的那套（手写版连撞两次墙的教训见 `docs/和弦识别-测量记录.md`）：
///   · onset/offset 要**超过阈值 + 左右单调**（邻域去抖）才算事件；
///   · 帧内位置用左右邻帧算出的 **shift**，不是回归值本身；
///   · 音的结束取 `offset_occur` 与 `frame_disappear` 中**离起点更近**的那个；
///   · 连续两个 onset 表示"前一个音在这里收尾"。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/crnn_engine.dart';

const int frames = CrnnConst.framesPerSegment;
const int keys = CrnnConst.keyCount;

/// 在**行优先**矩阵（frames × keys）里给第 [k] 键画一个"三角鼓包"。
/// 注意别用 `Float32List.view` —— 它是连续内存，而行优先的步长是 keys，会写错位置。
void bump(Float32List data, int k, int center, double peak, {int halfWidth = 3}) {
  for (var d = -halfWidth; d <= halfWidth; d++) {
    final i = center + d;
    if (i < 0 || i >= frames) continue;
    data[i * keys + k] = peak * (1 - d.abs() / (halfWidth + 1));
  }
}

void main() {
  late Float32List onset, offset, frame, velocity;

  setUp(() {
    onset = Float32List(frames * keys);
    offset = Float32List(frames * keys);
    frame = Float32List(frames * keys);
    velocity = Float32List(frames * keys);
  });

  List<({int midi, double start, double end, double conf})> decode() => decodeCrnnNotes(
        onset: onset,
        offset: offset,
        frame: frame,
        velocity: velocity,
        frames: frames,
        keys: keys,
      ).map((n) => (midi: n.midi.round(), start: n.startSec, end: n.endSec, conf: n.confidence)).toList();

  /// 一个"正常"的音：onset 鼓包 + frame 高于阈值 + offset 鼓包
  void playNote(int midi, {int onFrame = 50, int offFrame = 150, double vel = 0.8}) {
    final k = CrnnConst.keyOf(midi);
    bump(onset, k, onFrame, 0.9);
    bump(offset, k, offFrame, 0.9);
    for (var t = onFrame; t <= offFrame; t++) {
      frame[t * keys + k] = 0.9;
    }
    velocity[onFrame * keys + k] = vel;
  }

  test('单个音：起止时间用"帧号 + 邻域算出的 shift"', () {
    playNote(60, onFrame: 50, offFrame: 150);
    final notes = decode();
    expect(notes.length, 1);
    expect(notes.first.midi, 60);
    // 三角鼓包在峰处左右对称 → shift 为 0 → 时间就是帧号 /100
    expect(notes.first.start, closeTo(0.50, 0.02));
    expect(notes.first.end, closeTo(1.50, 0.02));
    expect(notes.first.conf, closeTo(0.8, 1e-3));
  });

  test('和弦：同一段上三个音都解出来（C4 E4 G4）', () {
    for (final m in [60, 64, 67]) {
      playNote(m);
    }
    final notes = decode();
    expect(notes.map((n) => n.midi).toList(), [60, 64, 67]);
  });

  test('邻域去抖：一段平顶的 onset 只会算一个事件（不会排出好几个音）', () {
    final k = CrnnConst.keyOf(60);
    for (var t = 40; t <= 60; t++) {
      onset[t * keys + k] = 0.9; // 平顶：左右不严格单调
    }
    for (var t = 40; t <= 120; t++) {
      frame[t * keys + k] = 0.9;
    }
    bump(offset, k, 120, 0.9);
    final notes = decode();
    expect(notes.length, 1, reason: '平顶不该被当成很多个 onset');
  });

  test('连续两个 onset：前一个音在第二个 onset 前收尾', () {
    playNote(60, onFrame: 50, offFrame: 100);
    // 第二个 onset（踏板没松又弹了一下）
    final k = CrnnConst.keyOf(60);
    bump(onset, k, 200, 0.9);
    for (var t = 200; t <= 260; t++) {
      frame[t * keys + k] = 0.9;
    }
    bump(offset, k, 260, 0.9);
    final notes = decode();
    expect(notes.length, 2, reason: '两下触键是两个音');
    expect(notes.first.end, lessThan(notes.last.start));
  });

  test('音的结束取"离起点更近"的那个（frame 消失 vs offset 事件）', () {
    final k = CrnnConst.keyOf(60);
    bump(onset, k, 100, 0.9);
    // frame 在 120 就掉到阈值以下；offset 事件在 200
    for (var t = 100; t < 120; t++) {
      frame[t * keys + k] = 0.9;
    }
    bump(offset, k, 200, 0.9);
    final notes = decode();
    expect(notes.length, 1);
    // bgn=100：frame_disappear(120) 离起点 20，offset_occur(200) 离起点 100 → 取 120
    expect(notes.first.end, closeTo(1.20, 0.03));
  });

  test('offset 的取舍：靠近消失点才采信，太早反而取消失点（官方语义）', () {
    // 情况 A：offset 贴近 frame 消失点 → 采信 offset
    final k = CrnnConst.keyOf(60);
    bump(onset, k, 100, 0.9);
    for (var t = 100; t < 130; t++) {
      frame[t * keys + k] = 0.9;
    } // frame 在 130 消失
    bump(offset, k, 125, 0.9); // 离消失点只有 5 帧
    var notes = decode();
    expect(notes.length, 1);
    expect(notes.first.end, closeTo(1.25, 0.03), reason: '贴近消失点 → 用 offset');

    // 情况 B：同样的音，offset 很早（110）→ 视为杂散，用 frame 消失点 130
    offset = Float32List(frames * keys);
    bump(offset, k, 110, 0.9);
    notes = decode();
    expect(notes.length, 1);
    expect(notes.first.end, closeTo(1.30, 0.03), reason: 'offset 太早 → 用 frame 消失点');
  });

  test('第 0 帧不会被当成 onset（官方二值化从 neighbour 帧才开始扫）', () {
    final k = CrnnConst.keyOf(60);
    onset[k] = 0.9;
    onset[keys + k] = 0.5;
    for (var t = 0; t < 80; t++) {
      frame[t * keys + k] = 0.9;
    }
    bump(offset, k, 80, 0.9);
    final notes = decode();
    expect(notes, isEmpty,
        reason: '官方实现里 i 从 neighbour 起，第 0 帧永远不会被标成 onset —— 这里如实记录，不自作聪明');
  });

  test('一直没消失的音按上限截断', () {
    final k = CrnnConst.keyOf(60);
    bump(onset, k, 10, 0.9);
    for (var t = 10; t < frames; t++) {
      frame[t * keys + k] = 0.9;
    }
    final notes = decode();
    expect(notes.length, 1);
    expect(notes.first.end, greaterThan(5.9));
  });

  test('跨段：segStartSec 累加到绝对时间上', () {
    playNote(60, onFrame: 50, offFrame: 150);
    final notes = decodeCrnnNotes(
      onset: onset,
      offset: offset,
      frame: frame,
      velocity: velocity,
      frames: frames,
      keys: keys,
      segStartSec: 10.0,
    );
    expect(notes.single.startSec, closeTo(10.5, 0.02));
    expect(notes.single.endSec, closeTo(11.5, 0.02));
  });

  test('键位映射：第 0 键是 A0(21)，第 87 键是 C8(108)', () {
    expect(CrnnConst.midiOf(0), 21);
    expect(CrnnConst.midiOf(87), 108);
  });

  test('分析结果包装：音符进 MelodyAnalysis 后不丢', () {
    playNote(60);
    playNote(64);
    final notes = decodeCrnnNotes(
      onset: onset,
      offset: offset,
      frame: frame,
      velocity: velocity,
      frames: frames,
      keys: keys,
    );
    final analysis = analysisFromDetectedNotes(notes, sampleRate: 16000, durationSec: 10);
    expect(analysis.notes.length, 2);
    expect(analysis.track, isNotEmpty);
    expect(analysis.keyName, isNotEmpty);
  });
}
