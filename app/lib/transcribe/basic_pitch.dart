/// Basic Pitch（Spotify AB，Apache-2.0）的 Dart 端移植。
///
/// 这里只做**前后处理**，矩阵运算交给 ONNX Runtime：
///   音频 →（补零/切窗）→ 模型 →（去重叠/拼接）→ 峰值解码 → 音符事件
///
/// 逐行对照官方实现移植，便于核对：
///   - `basic_pitch/constants.py`  窗口/帧率常量
///   - `basic_pitch/inference.py`  `get_audio_input` / `unwrap_output`
///   - `basic_pitch/note_creation.py`  `output_to_notes_polyphonic` 等
///
/// 与官方实现的**有意差异**（都不影响单声部简谱结果）：
///   1. 不计算 pitch bend（简谱/五线谱的十二平均律记谱表达不了弯音）；
///   2. `get_infered_onsets` 里 `frame_diff` 全零时官方会除零得到 NaN，
///      这里退化为"只用模型给出的 onset"。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 与 `basic_pitch/constants.py` 一一对应
abstract final class BpConst {
  /// `AUDIO_SAMPLE_RATE`
  static const int sampleRate = 22050;

  /// `FFT_HOP`
  static const int fftHop = 256;

  /// `AUDIO_WINDOW_LENGTH`（秒）
  static const int windowSeconds = 2;

  /// `ANNOTATIONS_FPS = AUDIO_SAMPLE_RATE // FFT_HOP`
  static const int annotationsFps = sampleRate ~/ fftHop; // 86

  /// `ANNOT_N_FRAMES = ANNOTATIONS_FPS * AUDIO_WINDOW_LENGTH`
  static const int nFramesPerWindow = annotationsFps * windowSeconds; // 172

  /// `AUDIO_N_SAMPLES = AUDIO_SAMPLE_RATE * AUDIO_WINDOW_LENGTH - FFT_HOP`
  static const int audioNSamples = sampleRate * windowSeconds - fftHop; // 43844

  /// `DEFAULT_OVERLAPPING_FRAMES`（inference.py）
  static const int nOverlappingFrames = 30;

  /// `N_FREQ_BINS_NOTES`
  static const int nNoteBins = 88;

  /// `N_FREQ_BINS_CONTOURS`
  static const int nContourBins = 264;

  /// `MIDI_OFFSET`（note_creation.py）
  static const int midiOffset = 21;

  /// `ANNOTATIONS_BASE_FREQUENCY`
  static const double baseFrequency = 27.5;

  /// `MAGIC_ALIGNMENT_OFFSET`
  static const double magicAlignmentOffset = 0.0018;

  /// `hop_size = AUDIO_N_SAMPLES - overlap_len`，其中 `overlap_len = 30 * FFT_HOP`
  static const int hopSize = audioNSamples - nOverlappingFrames * fftHop; // 36164

  /// `overlap_len / 2`：官方在音频**最前面**补的零
  static const int frontPad = (nOverlappingFrames * fftHop) ~/ 2; // 3840

  /// 每个窗口去掉首尾重叠后剩下的帧数
  static const int framesPerWindow = nFramesPerWindow - nOverlappingFrames; // 142
}

/// 解码参数，默认值与官方 `predict()` 一致
class BasicPitchParams {
  /// `DEFAULT_ONSET_THRESHOLD`
  final double onsetThreshold;

  /// `DEFAULT_FRAME_THRESHOLD`
  final double frameThreshold;

  /// `DEFAULT_MINIMUM_NOTE_LENGTH_MS`
  final double minNoteLengthMs;

  /// 是否用帧能量的突变补出额外 onset（官方默认开）
  final bool inferOnsets;

  /// 是否启用 melodia 后处理补音（官方默认开）
  final bool melodiaTrick;

  /// `energy_tol`
  final int energyTolerance;

  /// 允许的最低/最高音（Hz），null 表示不限制
  final double? minFrequency;
  final double? maxFrequency;

  const BasicPitchParams({
    this.onsetThreshold = 0.5,
    this.frameThreshold = 0.3,
    this.minNoteLengthMs = 127.7,
    this.inferOnsets = true,
    this.melodiaTrick = true,
    this.energyTolerance = 11,
    this.minFrequency,
    this.maxFrequency,
  });

  /// `min_note_len = round(ms / 1000 * (AUDIO_SAMPLE_RATE / FFT_HOP))`
  int get minNoteLengthFrames =>
      (minNoteLengthMs / 1000 * (BpConst.sampleRate / BpConst.fftHop)).round();

  BasicPitchParams copyWith({
    double? onsetThreshold,
    double? frameThreshold,
    double? minNoteLengthMs,
    bool? inferOnsets,
    bool? melodiaTrick,
    int? energyTolerance,
    double? minFrequency,
    double? maxFrequency,
  }) =>
      BasicPitchParams(
        onsetThreshold: onsetThreshold ?? this.onsetThreshold,
        frameThreshold: frameThreshold ?? this.frameThreshold,
        minNoteLengthMs: minNoteLengthMs ?? this.minNoteLengthMs,
        inferOnsets: inferOnsets ?? this.inferOnsets,
        melodiaTrick: melodiaTrick ?? this.melodiaTrick,
        energyTolerance: energyTolerance ?? this.energyTolerance,
        minFrequency: minFrequency ?? this.minFrequency,
        maxFrequency: maxFrequency ?? this.maxFrequency,
      );
}

/// 一个音符事件（帧为单位；`amplitude` 是 0~1 的能量）
class BasicPitchNote {
  final int startFrame;
  final int endFrame;
  final int midi;
  final double amplitude;

  const BasicPitchNote(this.startFrame, this.endFrame, this.midi, this.amplitude);

  @override
  String toString() => 'BasicPitchNote($startFrame..$endFrame, midi=$midi, amp=${amplitude.toStringAsFixed(3)})';
}

/// 时间轴：帧号 → 秒（移植 `model_frames_to_time`，含官方的对齐修正）
List<double> modelFramesToTime(int nFrames) {
  final windowOffset = (BpConst.fftHop / BpConst.sampleRate) *
          (BpConst.nFramesPerWindow - BpConst.audioNSamples / BpConst.fftHop) +
      BpConst.magicAlignmentOffset;
  final out = List<double>.filled(nFrames, 0);
  for (var i = 0; i < nFrames; i++) {
    final original = i * BpConst.fftHop / BpConst.sampleRate;
    final windowNumber = (i / BpConst.nFramesPerWindow).floorToDouble();
    out[i] = original - windowOffset * windowNumber;
  }
  return out;
}

/// 一次模型推理的原始输出（按时间优先展平：`[frame][bin]`）
class BasicPitchWindowOutput {
  final Float32List note;
  final Float32List onset;
  const BasicPitchWindowOutput(this.note, this.onset);
}

/// 按官方 `window_audio_file` + `get_audio_input` 切窗。
///
/// 返回每个窗口的起始下标（以"补零后的音频"为坐标，长度 43844，不足的尾部补零）。
List<int> windowStarts(int audioLength) {
  final padded = audioLength + BpConst.frontPad;
  final starts = <int>[];
  for (var i = 0; i < padded; i += BpConst.hopSize) {
    starts.add(i);
  }
  return starts;
}

/// 取出补零后坐标 `[start, start + audioNSamples)` 的窗口（越界补零）
Float32List extractWindow(Float32List audio, int start) {
  final out = Float32List(BpConst.audioNSamples);
  for (var i = 0; i < BpConst.audioNSamples; i++) {
    final k = start + i - BpConst.frontPad; // 换算回原始音频下标
    if (k >= 0 && k < audio.length) out[i] = audio[k];
  }
  return out;
}

/// 移植 `unwrap_output`：去掉每个窗口首尾各 15 帧后拼接，并对齐原始长度
Float32List unwrapFrames(
  List<Float32List> windows,
  int nBins,
  int originalLength,
) {
  final half = BpConst.nOverlappingFrames ~/ 2; // 15
  const keep = BpConst.framesPerWindow; // 142
  final total = windows.length * keep;
  final out = Float32List(total * nBins);
  var w = 0;
  for (final win in windows) {
    for (var t = 0; t < keep; t++) {
      final src = (t + half) * nBins;
      out.setRange(w * nBins, w * nBins + nBins, win, src);
      w++;
    }
  }
  // int(audio_original_length / hop_size * n_frames_per_window)
  final expected = (originalLength / BpConst.hopSize * keep).truncate();
  final n = math.min(expected, total);
  return n >= total ? out : Float32List.sublistView(out, 0, n * nBins);
}

/// `librosa.hz_to_midi`
double hzToMidi(double hz) => 69 + 12 * (math.log(hz / 440) / math.ln2);

/// 移植 `constrain_frequency`
void _constrainFrequency(
  Float64List onsets,
  Float64List frames,
  int nFrames,
  int nBins,
  double? minFreq,
  double? maxFreq,
) {
  var minIdx = 0;
  var maxIdx = nBins;
  if (minFreq != null) minIdx = (hzToMidi(minFreq) - BpConst.midiOffset).round();
  if (maxFreq != null) maxIdx = (hzToMidi(maxFreq) - BpConst.midiOffset).round();
  minIdx = minIdx.clamp(0, nBins);
  maxIdx = maxIdx.clamp(0, nBins);
  for (var t = 0; t < nFrames; t++) {
    final base = t * nBins;
    for (var f = 0; f < minIdx; f++) {
      onsets[base + f] = 0;
      frames[base + f] = 0;
    }
    for (var f = maxIdx; f < nBins; f++) {
      onsets[base + f] = 0;
      frames[base + f] = 0;
    }
  }
}

/// 移植 `get_infered_onsets`
Float64List _inferOnsets(Float64List onsets, Float64List frames, int nFrames, int nBins, int nDiff) {
  final diff = List<Float64List>.generate(nDiff, (k) {
    final shift = k + 1;
    final d = Float64List(frames.length);
    for (var t = 0; t < nFrames; t++) {
      final base = t * nBins;
      if (t < shift) {
        for (var f = 0; f < nBins; f++) {
          d[base + f] = frames[base + f];
        }
      } else {
        final prev = base - shift * nBins;
        for (var f = 0; f < nBins; f++) {
          d[base + f] = frames[base + f] - frames[prev + f];
        }
      }
    }
    return d;
  });

  final frameDiff = Float64List(frames.length);
  for (var i = 0; i < frameDiff.length; i++) {
    var m = diff[0][i];
    for (var k = 1; k < nDiff; k++) {
      if (diff[k][i] < m) m = diff[k][i];
    }
    frameDiff[i] = m < 0 ? 0 : m;
  }
  final zeroRows = math.min(nDiff, nFrames);
  for (var t = 0; t < zeroRows; t++) {
    frameDiff.fillRange(t * nBins, t * nBins + nBins, 0);
  }

  var maxOnset = 0.0;
  for (final v in onsets) {
    if (v > maxOnset) maxOnset = v;
  }
  var maxDiff = 0.0;
  for (final v in frameDiff) {
    if (v > maxDiff) maxDiff = v;
  }
  final scale = maxDiff > 0 ? maxOnset / maxDiff : 0.0;

  final out = Float64List(onsets.length);
  for (var i = 0; i < out.length; i++) {
    final a = onsets[i];
    final b = frameDiff[i] * scale;
    out[i] = a > b ? a : b;
  }
  return out;
}

double _meanColumn(Float64List m, int fromFrame, int toFrame, int freq, int nBins) {
  if (toFrame <= fromFrame) return 0;
  var sum = 0.0;
  for (var t = fromFrame; t < toFrame; t++) {
    sum += m[t * nBins + freq];
  }
  return sum / (toFrame - fromFrame);
}

/// 移植 `output_to_notes_polyphonic`：把模型输出解码成音符事件。
///
/// [frameData] / [onsetData] 都是按 `[frame][bin]` 展平的 0~1 激活值。
List<BasicPitchNote> decodeNotes({
  required Float32List frameData,
  required Float32List onsetData,
  required int nFrames,
  int nBins = BpConst.nNoteBins,
  BasicPitchParams params = const BasicPitchParams(),
}) {
  final frames = Float64List.fromList(frameData);
  var onsets = Float64List.fromList(onsetData);
  if (onsets.length != nFrames * nBins || frames.length != nFrames * nBins) {
    throw ArgumentError('激活矩阵尺寸与 nFrames/nBins 不一致');
  }

  _constrainFrequency(onsets, frames, nFrames, nBins, params.minFrequency, params.maxFrequency);
  if (params.inferOnsets) {
    onsets = _inferOnsets(onsets, frames, nFrames, nBins, 2);
  }

  // scipy.signal.argrelmax(onsets, axis=0)：沿时间轴的严格局部极大（不含首尾）
  final peaks = Float64List(onsets.length);
  for (var t = 1; t < nFrames - 1; t++) {
    final base = t * nBins;
    for (var f = 0; f < nBins; f++) {
      final v = onsets[base + f];
      if (v > onsets[base - nBins + f] && v > onsets[base + nBins + f]) {
        peaks[base + f] = v;
      }
    }
  }

  // np.where(...) 是按 C 序（时间优先）给出的，官方再 [::-1] 倒序处理
  final order = <int>[];
  for (var i = 0; i < peaks.length; i++) {
    if (peaks[i] >= params.onsetThreshold) order.add(i);
  }

  final remaining = Float64List.fromList(frames);
  final notes = <BasicPitchNote>[];
  const maxFreqIdx = BpConst.nNoteBins - 1;
  final minNoteLen = params.minNoteLengthFrames;
  final energyTol = params.energyTolerance;
  final frameThresh = params.frameThreshold;

  void clearAround(int t, int f) {
    final base = t * nBins;
    remaining[base + f] = 0;
    if (f < maxFreqIdx) remaining[base + f + 1] = 0;
    if (f > 0) remaining[base + f - 1] = 0;
  }

  for (var oi = order.length - 1; oi >= 0; oi--) {
    final flat = order[oi];
    final start = flat ~/ nBins;
    final freq = flat % nBins;
    if (start >= nFrames - 1) continue;

    var i = start + 1;
    var k = 0;
    while (i < nFrames - 1 && k < energyTol) {
      if (remaining[i * nBins + freq] < frameThresh) {
        k++;
      } else {
        k = 0;
      }
      i++;
    }
    i -= k;
    if (i - start <= minNoteLen) continue;

    for (var t = start; t < i; t++) {
      clearAround(t, freq);
    }
    notes.add(BasicPitchNote(start, i, freq + BpConst.midiOffset, _meanColumn(frames, start, i, freq, nBins)));
  }

  if (params.melodiaTrick) {
    while (true) {
      var best = -1;
      var bestValue = double.negativeInfinity;
      for (var idx = 0; idx < remaining.length; idx++) {
        if (remaining[idx] > bestValue) {
          bestValue = remaining[idx];
          best = idx;
        }
      }
      if (best < 0 || !(bestValue > frameThresh)) break;

      final mid = best ~/ nBins;
      final freq = best % nBins;
      remaining[best] = 0;

      var i = mid + 1;
      var k = 0;
      while (i < nFrames - 1 && k < energyTol) {
        if (remaining[i * nBins + freq] < frameThresh) {
          k++;
        } else {
          k = 0;
        }
        clearAround(i, freq);
        i++;
      }
      final end = i - 1 - k;

      i = mid - 1;
      k = 0;
      while (i > 0 && k < energyTol) {
        if (remaining[i * nBins + freq] < frameThresh) {
          k++;
        } else {
          k = 0;
        }
        clearAround(i, freq);
        i--;
      }
      final start = i + 1 + k;

      if (end - start <= minNoteLen) continue;
      if (start < 0 || end >= nFrames) continue;
      notes.add(BasicPitchNote(start, end, freq + BpConst.midiOffset, _meanColumn(frames, start, end, freq, nBins)));
    }
  }

  notes.sort((a, b) => a.startFrame != b.startFrame
      ? a.startFrame.compareTo(b.startFrame)
      : a.midi.compareTo(b.midi));
  return notes;
}
