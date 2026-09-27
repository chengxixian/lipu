/// 钢琴采样渲染器测试：音高、时长、循环延续、限幅、休止
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/audio/piano_samples.dart';
import 'package:jianpu_app/audio/sampler.dart';
import 'package:jianpu_app/core/model.dart';
import 'package:jianpu_app/core/parse.dart';
import 'package:jianpu_app/transcribe/wav.dart';

late PianoSampleSet samples;
late Directory tmp;

/// 直接构造"只有一个音"的乐谱（C 大调自然音级），避免测试里算错简谱音级。
///
/// 注意 `NoteItem.octave` 是**上下加点的个数**（0 = 不带点 = 中央 C 那一组），
/// 不是科学音高记号里的八度数。
Score singleNote(int midi, {int ticks = 4, int tempo = 120}) {
  const offsets = [0, 2, 4, 5, 7, 9, 11]; // 1 2 3 4 5 6 7
  for (var d = 0; d < offsets.length; d++) {
    final rel = midi - 60 - offsets[d];
    if (rel % 12 == 0) {
      final meta = ScoreMeta(title: 't', keyName: 'C', beats: 4, beatType: 4, tempo: tempo);
      final measure = Measure()..items.add(NoteItem(degree: d + 1, octave: rel ~/ 12, ticks: ticks.toDouble()));
      return Score(meta, <Measure>[measure]);
    }
  }
  throw ArgumentError('测试只支持自然音级：$midi');
}

/// 渲染到临时文件再解回来
WavData render(
  String jianpu, {
  double gain = 0.8,
  double reverbMix = 0.45,
  double maxSeconds = 60,
  void Function(double)? onProgress,
}) =>
    renderScore(parseJianpu(jianpu),
        gain: gain, reverbMix: reverbMix, maxSeconds: maxSeconds, onProgress: onProgress);

/// 渲染一份乐谱
WavData renderScore(
  Score score, {
  double gain = 0.8,
  double reverbMix = 0.45,
  double maxSeconds = 60,
  void Function(double)? onProgress,
}) {
  final path = '${tmp.path}/out.wav';
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
  renderPianoWav(
    score: score,
    samples: samples,
    path: path,
    gain: gain,
    reverbMix: reverbMix,
    maxSeconds: maxSeconds,
    onProgress: onProgress,
  );
  return decodeWav(f.readAsBytesSync());
}

/// 自相关估计基频（钢琴录音有拍频，取 0.35~0.75 秒区间更稳）
double estimateF0(Float64List x, int rate, double expected) {
  final lo = math.max(2, (rate / (expected * 1.15)).floor());
  final hi = (rate / (expected * 0.87)).ceil();
  final start = (rate * 0.05).round();
  final len = math.min(x.length - start - hi, (rate * 0.6).round());
  var bestLag = lo;
  var best = -2.0;
  for (var lag = lo; lag <= hi; lag++) {
    var num = 0.0;
    var d1 = 0.0;
    var d2 = 0.0;
    for (var i = 0; i < len; i++) {
      final a = x[start + i];
      final b = x[start + i + lag];
      num += a * b;
      d1 += a * a;
      d2 += b * b;
    }
    final r = num / math.sqrt(d1 * d2 == 0 ? 1e-30 : d1 * d2);
    if (r > best) {
      best = r;
      bestLag = lag;
    }
  }
  // 抛物线插值
  double rAt(int lag) {
    var num = 0.0;
    var d1 = 0.0;
    var d2 = 0.0;
    for (var i = 0; i < len; i++) {
      num += x[start + i] * x[start + i + lag];
      d1 += x[start + i] * x[start + i];
      d2 += x[start + i + lag] * x[start + i + lag];
    }
    return num / math.sqrt(d1 * d2 == 0 ? 1e-30 : d1 * d2);
  }

  final r0 = rAt(bestLag - 1);
  final r1 = rAt(bestLag);
  final r2 = rAt(bestLag + 1);
  final den = r0 - 2 * r1 + r2;
  final delta = den == 0 ? 0.0 : 0.5 * (r0 - r2) / den;
  return rate / (bestLag + delta);
}

double rms(Float64List x, int rate, double fromSec, double toSec) {
  final a = (fromSec * rate).round().clamp(0, x.length);
  final b = (toSec * rate).round().clamp(a, x.length);
  if (b <= a) return 0;
  var sum = 0.0;
  for (var i = a; i < b; i++) {
    sum += x[i] * x[i];
  }
  return math.sqrt(sum / (b - a));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    samples = await PianoSampleSet.load();
    tmp = Directory.systemTemp.createTempSync('lipu_sampler_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('中央 C 的音高正确（等程律 261.6Hz，误差 < 1%）', () {
    final wav = renderScore(singleNote(60), reverbMix: 0);
    final mono = toMono(wav);
    final f0 = estimateF0(mono, wav.sampleRate, 261.63);
    expect((f0 - 261.63).abs() / 261.63, lessThan(0.01), reason: '实测 ${f0.toStringAsFixed(1)}Hz');
  });

  test('最低音 A0 的音高正确（27.5Hz，误差 < 1%）', () {
    final wav = renderScore(singleNote(21), reverbMix: 0);
    final mono = toMono(wav);
    final f0 = estimateF0(mono, wav.sampleRate, 27.5);
    expect((f0 - 27.5).abs() / 27.5, lessThan(0.01), reason: '实测 ${f0.toStringAsFixed(2)}Hz');
  });

  test('时长 = 乐曲时长 + 尾音，且 44.1kHz 立体声', () {
    final wav = render('1=C 4/4 ♩=120\n1 2 3 4 |]');
    expect(wav.sampleRate, kPianoSampleRate);
    expect(wav.channels, 2);
    // 4 拍 @120 = 2 秒，加 1.4 秒尾音
    expect(wav.durationSec, closeTo(3.4, 0.05));
  });

  test('长音靠循环延续，不会中途断掉', () {
    // 8 拍 @60 = 8 秒
    final wav = render('1=C 4/4 ♩=60\n1 - - - | 1 - - - |]');
    final mono = toMono(wav);
    final early = rms(mono, wav.sampleRate, 0.05, 0.5);
    final late = rms(mono, wav.sampleRate, 5.0, 6.0);
    expect(early, greaterThan(0.01), reason: '起音应当有声音');
    expect(late, greaterThan(0.0005), reason: '第 5~6 秒还在响（循环生效），实测 $late');
    expect(late, lessThan(early), reason: '钢琴是衰减的，后面应更轻');
  });

  test('休止符不发声', () {
    final wav = render('1=C 4/4 ♩=120\n1 0 0 0 |]');
    final mono = toMono(wav);
    final note = rms(mono, wav.sampleRate, 0.05, 0.4);
    final rest = rms(mono, wav.sampleRate, 0.7, 1.9);
    expect(note, greaterThan(0.01));
    expect(rest, lessThan(note * 0.2), reason: '休止处应当明显更轻，实测 $rest vs $note');
  });

  test('和弦不削顶（软限幅），也不会过轻', () {
    final wav = render("1=C 4/4 ♩=120\n[1 3 5 1'] [1 3 5 1'] [1 3 5 1'] [1 3 5 1'] |]");
    var peak = 0.0;
    var clipped = 0;
    for (final v in wav.samples) {
      final a = v.abs();
      if (a > peak) peak = a;
      if (a >= 0.999) clipped++;
    }
    expect(peak, lessThanOrEqualTo(1.0));
    expect(peak, greaterThan(0.15), reason: '整体太轻了：$peak');
    expect(clipped / wav.samples.length, lessThan(0.005), reason: '削顶样本过多');
  });

  test('空谱（全休止）不崩，输出静音', () {
    final wav = render('1=C 4/4 ♩=120\n0 0 0 0 |]');
    var peak = 0.0;
    for (final v in wav.samples) {
      peak = math.max(peak, v.abs());
    }
    expect(peak, lessThan(0.01));
    expect(wav.durationSec, closeTo(3.4, 0.05));
  });

  test('大谱表两个声部同时发声', () {
    final wav = render('1=C 4/4 ♩=120\n高音: 1 - - - |\n低音: 1,, - - - |]');
    final mono = toMono(wav);
    // 同时有 C4(261.6) 与 C2(65.4)：低频能量应当明显大于单声部
    final melodyOnly = render('1=C 4/4 ♩=120\n1 - - - |]');
    final grand = rms(mono, wav.sampleRate, 0.05, 0.5);
    final single = rms(toMono(melodyOnly), melodyOnly.sampleRate, 0.05, 0.5);
    expect(grand, greaterThan(single * 1.1), reason: '大谱表应比单声部更厚：$grand vs $single');
  });

  test('进度回调单调递增并结束在 1.0', () {
    final seen = <double>[];
    render('1=C 4/4 ♩=120\n1 2 3 4 | 5 6 7 1\' |]', onProgress: seen.add);
    expect(seen, isNotEmpty);
    expect(seen.last, closeTo(1.0, 1e-9));
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThan(seen[i - 1]));
    }
  });

  test('移调播放（G1 用 F#1 采样升高 1 个半音）音高正确', () {
    final expected = (440 * math.pow(2, (31 - 69) / 12.0)).toDouble();
    final wav = renderScore(singleNote(31), reverbMix: 0);
    final mono = toMono(wav);
    final f0 = estimateF0(mono, wav.sampleRate, expected);
    expect((f0 - expected).abs() / expected, lessThan(0.01),
        reason: '实测 ${f0.toStringAsFixed(2)}Hz 期望 ${expected.toStringAsFixed(2)}Hz');
  });
}
