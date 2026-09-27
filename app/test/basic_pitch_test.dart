/// Basic Pitch Dart 移植的**参考实现对照测试**。
///
/// `test/fixtures/basic_pitch/` 里的数据由 `tool/basicpitch_reference.py` 生成：
/// 它用官方 `basic_pitch` 库（0.4.0）跑**同一个** ONNX 模型，
/// 导出音频、切窗结果、模型输出和官方解码出的音符事件。
/// 这里验证 Dart 端的切窗、拼接、峰值解码与官方逐位/逐个一致。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/basic_pitch.dart';
import 'package:jianpu_app/transcribe/basic_pitch_engine.dart';
import 'package:jianpu_app/transcribe/melody.dart';

const String _dir = 'test/fixtures/basic_pitch';

Float32List _loadF32(String name) {
  final bytes = File('$_dir/$name').readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getFloat32(i * 4, Endian.little);
  }
  return out;
}

Map<String, dynamic> _loadJson(String name) =>
    jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, dynamic>;

List<Map<String, dynamic>> _loadNotes() =>
    (jsonDecode(File('$_dir/notes.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();

void main() {
  final meta = _loadJson('meta.json');
  final audio = _loadF32('audio.f32');
  final windows = _loadF32('windows.f32');
  final noteAct = _loadF32('note.f32');
  final onsetAct = _loadF32('onset.f32');
  final referenceNotes = _loadNotes();
  final nWindows = meta['nWindows'] as int;
  final nFrames = meta['nFrames'] as int;

  test('常量与官方 constants.py 一致', () {
    expect(BpConst.sampleRate, meta['sampleRate']);
    expect(BpConst.fftHop, meta['fftHop']);
    expect(BpConst.audioNSamples, meta['audioNSamples']);
    expect(BpConst.hopSize, meta['hopSize']);
    expect(BpConst.nOverlappingFrames, meta['overlapFrames']);
    expect(meta['nNoteBins'], BpConst.nNoteBins);
  });

  test('参考数据本身自洽', () {
    expect(audio.length, meta['samples']);
    expect(noteAct.length, nFrames * BpConst.nNoteBins);
    expect(onsetAct.length, nFrames * BpConst.nNoteBins);
    expect(windows.length, nWindows * BpConst.audioNSamples);
    expect(referenceNotes, isNotEmpty);
  });

  test('切窗（补零 + hop 36164）与官方 window_audio_file 逐位一致', () {
    final starts = windowStarts(audio.length);
    expect(starts.length, nWindows, reason: '窗口个数应与官方一致：$starts');

    for (var w = 0; w < nWindows; w++) {
      final window = extractWindow(audio, starts[w]);
      expect(window.length, BpConst.audioNSamples);
      final offset = w * BpConst.audioNSamples;
      for (var i = 0; i < window.length; i++) {
        if (window[i] != windows[offset + i]) {
          fail('第 $w 个窗口第 $i 个采样不一致：Dart=${window[i]} 官方=${windows[offset + i]}');
        }
      }
    }
  });

  test('去重叠拼接保留 142 帧/窗口，并按原始长度裁剪', () {
    // 用"窗口号*1000 + 帧号"编码，验证裁剪位置与顺序
    const bins = 2;
    final perWindow = <Float32List>[];
    for (var w = 0; w < 3; w++) {
      final buf = Float32List(BpConst.nFramesPerWindow * bins);
      for (var t = 0; t < BpConst.nFramesPerWindow; t++) {
        buf[t * bins] = w * 1000 + t.toDouble();
        buf[t * bins + 1] = 1;
      }
      perWindow.add(buf);
    }
    final merged = unwrapFrames(perWindow, bins, 10 * BpConst.hopSize);
    expect(merged.length ~/ bins, 3 * BpConst.framesPerWindow);
    // 每个窗口丢掉前 15 帧和后 15 帧
    for (var w = 0; w < 3; w++) {
      for (var t = 0; t < BpConst.framesPerWindow; t++) {
        final idx = (w * BpConst.framesPerWindow + t) * bins;
        expect(merged[idx], w * 1000 + t + 15);
      }
    }
    // 原始长度更短时按 int(len / hop * 142) 裁剪
    final shorter = unwrapFrames(perWindow, bins, BpConst.hopSize);
    expect(shorter.length ~/ bins, BpConst.framesPerWindow);
  });

  test('峰值解码与官方 output_to_notes_polyphonic 完全一致', () {
    final notes = decodeNotes(
      frameData: noteAct,
      onsetData: onsetAct,
      nFrames: nFrames,
    );
    expect(notes.length, referenceNotes.length,
        reason: '音符个数不一致：Dart=${notes.map((n) => "${n.startFrame}-${n.endFrame}/${n.midi}").toList()}');

    String key(BasicPitchNote n) => '${n.startFrame}:${n.endFrame}:${n.midi}';
    final got = notes.map(key).toList()..sort();
    final want = referenceNotes
        .map((e) => '${e['startFrame']}:${e['endFrame']}:${e['midi']}')
        .toList()
      ..sort();
    expect(got, want);

    // 能量也要对得上（官方用 float32 累加，这里用 float64，容差 1e-4）
    final byKey = {for (final n in notes) key(n): n};
    for (final e in referenceNotes) {
      final n = byKey['${e['startFrame']}:${e['endFrame']}:${e['midi']}']!;
      expect(n.amplitude, closeTo(e['amplitude'] as double, 1e-4));
    }
  });

  test('帧→时间映射与官方 model_frames_to_time 一致', () {
    final times = modelFramesToTime(nFrames);
    expect(times.length, nFrames);
    expect(times.first, 0);
    for (var i = 1; i < nFrames; i++) {
      expect(times[i], greaterThan(times[i - 1]));
    }
    // 官方参考里的时间点要能被这套映射复现
    for (final e in referenceNotes) {
      final start = times[e['startFrame'] as int];
      expect(start, closeTo(e['startSec'] as double, 1e-9));
    }
  });

  test('主旋律提取：去掉泛音与伴奏，得到小星星开头 C C G G A', () {
    final raw = referenceNotes
        .map((e) => DetectedNote(
              startSec: e['startSec'] as double,
              endSec: e['endSec'] as double,
              midi: (e['midi'] as num).toDouble(),
              confidence: e['amplitude'] as double,
            ))
        .toList();
    // 官方给出 11 个音（含 12 个半音以上的泛音重复与低八度）
    expect(raw.length, 11);
    final melody = pickMelodyNotes(raw);
    expect(melody.map((n) => n.midiRound).toList(), [60, 60, 67, 67, 69]);
  });

  test('空输入与超短输入不会崩', () {
    expect(decodeNotes(frameData: Float32List(0), onsetData: Float32List(0), nFrames: 0), isEmpty);
    expect(pickMelodyNotes(const []), isEmpty);
    expect(windowStarts(0).length, 1);
  });
}
