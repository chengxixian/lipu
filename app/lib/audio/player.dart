/// 播放器：合成 WAV 后用 audioplayers 播放
///
/// 要点：
///   1. 默认走**真实钢琴采样**（[renderPianoWav]）：44.1kHz 立体声，流式写文件；
///   2. 采样渲染很费 CPU（一首 5 分钟的曲子约 1300 万个采样帧），必须丢到
///      **后台 isolate**，否则界面会卡住；渲染进度通过 SendPort 回传；
///   3. 万一采样资源缺失（老安装包/被裁剪的构建），退回纯合成器（22050Hz 单声道）；
///   4. audioplayers 在部分机型上会"报错但其实已经开始放了"，所以出错后
///      以播放器真实状态为准，不轻易报失败。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../core/app_paths.dart';
import '../core/model.dart';
import 'piano_samples.dart';
import 'sampler.dart';
import 'synth.dart';

/// 退化方案（纯合成器）用的采样率（试听够用，内存/耗时是 44100 的一半）
const int kPreviewSampleRate = 22050;

/// 试听最长合成时长（秒）：扒谱结果可能有好几分钟，手机上要控制体积
const int kPreviewMaxSeconds = 300;

Uint8List _synthTask(Map<String, dynamic> args) =>
    synthesizeWav(args['score'] as Score, sampleRate: args['rate'] as int, timbre: 0);

/// 后台 isolate 入口：用采样渲染到文件，进度回传
void _pianoRenderEntry(Map<String, dynamic> job) {
  final port = job['port'] as SendPort;
  try {
    renderPianoWav(
      score: job['score'] as Score,
      samples: job['samples'] as PianoSampleSet,
      path: job['path'] as String,
      maxSeconds: (job['maxSeconds'] as num).toDouble(),
      onProgress: (p) => port.send({'p': p}),
    );
    port.send({'ok': true});
  } catch (e) {
    port.send([e.toString()]);
  }
}

class ScorePlayer {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  bool _wasTruncated = false;
  PianoSampleSet? _samples;
  bool _samplesFailed = false;

  bool get playing => _playing;

  /// 上一次试听是否因为超长被截断
  bool get wasTruncated => _wasTruncated;

  /// 是否用上了真实钢琴采样（否则是合成器兜底）
  bool get usingSamples => _samples != null;

  /// 采样音源的署名（CC-BY 要求标注；没加载到采样时为空）
  String get sampleAttribution => _samples?.attribution ?? '';

  Stream<PlayerState> get onStateChanged => _player.onPlayerStateChanged;

  /// 播放自然结束
  Stream<void> get onComplete => _player.onPlayerComplete;

  ScorePlayer() {
    _player.onPlayerStateChanged.listen((s) {
      _playing = s == PlayerState.playing;
    });
  }

  /// 读入内置钢琴采样（只读一次，缓存在内存里）
  Future<PianoSampleSet?> _ensureSamples() async {
    if (_samples != null || _samplesFailed) return _samples;
    try {
      _samples = await PianoSampleSet.load();
    } catch (e, st) {
      _samplesFailed = true;
      debugPrint('钢琴采样加载失败，退回合成器：$e\n$st');
    }
    return _samples;
  }

  Future<void> play(
    Score score, {
    double tempoScale = 1.0,
    void Function(String stage)? onStage,
  }) async {
    await _player.stop();
    final original = score.meta.tempo;
    if (tempoScale != 1.0) {
      score.meta.tempo = (original * tempoScale).round().clamp(30, 260);
    }
    try {
      final trimmed = _trimForPreview(score);
      _wasTruncated = trimmed != null;
      final target = trimmed ?? score;
      final file = File(AppPaths.join(AppPaths.tempDir(), 'jianpu_preview.wav'));

      final set = await _ensureSamples();
      if (set != null && !set.isEmpty) {
        await _renderWithSamples(target, set, file.path, onStage);
      } else {
        onStage?.call('正在合成试听音频…');
        final wav = await compute(_synthTask, {
          'score': target,
          'rate': kPreviewSampleRate,
        });
        await file.writeAsBytes(wav, flush: true);
      }

      onStage?.call('正在启动播放…');
      try {
        await _player.play(DeviceFileSource(file.path));
      } catch (e) {
        // 有些机型 play() 会抛异常但实际已经在播，等一下看真实状态再决定
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (_player.state != PlayerState.playing) rethrow;
      }
      _playing = true;
    } finally {
      score.meta.tempo = original;
    }
  }

  /// 在后台 isolate 里用采样渲染，并把进度回传到 [onStage]
  Future<void> _renderWithSamples(
    Score score,
    PianoSampleSet samples,
    String path,
    void Function(String stage)? onStage,
  ) async {
    onStage?.call('正在合成试听音频…');
    final port = ReceivePort();
    final completer = Completer<void>();
    var lastReported = -1.0;
    port.listen((msg) {
      if (msg is Map && msg['p'] is double) {
        final p = msg['p'] as double;
        if (p - lastReported >= 0.02 || p >= 1) {
          lastReported = p;
          onStage?.call('正在合成试听音频… ${(p * 100).round()}%');
        }
      } else if (msg is Map && msg['ok'] == true) {
        if (!completer.isCompleted) completer.complete();
      } else if (msg is List) {
        if (!completer.isCompleted) {
          completer.completeError(StateError(msg.isEmpty ? '合成失败' : '${msg.first}'));
        }
      } else if (msg == null) {
        if (!completer.isCompleted) completer.completeError(StateError('合成进程意外退出'));
      }
    });
    final isolate = await Isolate.spawn(
      _pianoRenderEntry,
      <String, dynamic>{
        'score': score,
        'samples': samples,
        'path': path,
        'port': port.sendPort,
        'maxSeconds': kPreviewMaxSeconds,
      },
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
    );
    try {
      await completer.future;
    } finally {
      isolate.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  /// 太长的曲子只合成前 [kPreviewMaxSeconds] 秒（其余部分裁掉）
  Score? _trimForPreview(Score score) {
    final secPerTick = 60.0 / (score.meta.tempo <= 0 ? 96 : score.meta.tempo);
    final limitTicks = kPreviewMaxSeconds / secPerTick;
    var total = 0.0;
    for (final m in score.measures) {
      total += m.filled;
    }
    if (total <= limitTicks) return null;

    final meta = ScoreMeta(
      title: score.meta.title,
      composer: score.meta.composer,
      lyricist: score.meta.lyricist,
      keyName: score.meta.keyName,
      mode: score.meta.mode,
      beats: score.meta.beats,
      beatType: score.meta.beatType,
      tempo: score.meta.tempo,
      clef: score.meta.clef,
    );
    final measures = <Measure>[];
    var acc = 0.0;
    for (final m in score.measures) {
      if (acc >= limitTicks) break;
      final copy = Measure()
        ..repeatStart = m.repeatStart
        ..repeatEnd = m.repeatEnd;
      for (final it in m.items) {
        copy.items.add(_cloneItem(it));
      }
      for (final it in m.items2) {
        copy.items2.add(_cloneItem(it));
      }
      measures.add(copy);
      acc += m.filled;
    }
    if (measures.isEmpty) return null;
    measures.last.isFinal = true;
    return Score(meta, measures);
  }

  Item _cloneItem(Item it) {
    if (it is NoteItem) {
      final n = NoteItem(
        degree: it.degree,
        octave: it.octave,
        accidental: it.accidental,
        ticks: it.ticks,
        lyric: it.lyric,
        tieToPrev: it.tieToPrev,
        tieToNext: it.tieToNext,
        src: it.src,
      );
      for (final t in it.chord) {
        n.chord.add(t.clone());
      }
      return n;
    }
    return RestItem(ticks: it.ticks, src: it.src);
  }

  Future<void> stop() async {
    await _player.stop();
    _playing = false;
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}
