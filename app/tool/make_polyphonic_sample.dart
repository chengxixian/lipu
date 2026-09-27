/// 生成一个**复调**示例音频，用来验证"听歌扒谱"的真实场景：
/// 主旋律 + 低音（低两个八度，全音符）+ 琶音伴奏（低一个八度，八分音符），
/// 三层叠加后再加一点白噪声，模拟"歌里有伴奏"的情况。
///
///   dart run tool/make_polyphonic_sample.dart
///
/// 输出：test/fixtures/polyphonic.wav（22050Hz 单声道）
/// 真值（主旋律音高序列）同时打印出来，供端到端测试比对。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../lib/audio/synth.dart';
import '../lib/core/model.dart';
import '../lib/core/parse.dart';
import '../lib/transcribe/wav.dart';

/// 主旋律：小星星，42 个音
const String _melody = '''标题：小星星
1=C 4/4 ♩=96
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |
5 5 4 4 | 3 3 2 - | 5 5 4 4 | 3 3 2 - |
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]''';

/// 低音：两拍一个根音，低两个八度（`,,` = 下两个八度）
const String _bass = '''1=C 4/4 ♩=96
1,, - | 5,, - | 4,, - | 1,, - |
5,, - | 3,, - | 5,, - | 3,, - |
1,, - | 5,, - | 4,, - | 1,, - |]''';

/// 伴奏琶音：低一个八度，连续八分音符（与技术无关，只是为了制造同时发声）
const String _arp = '''1=C 4/4 ♩=96
1,/ 3/ 5/ 3/ | 1,/ 3/ 5/ 3/ | 4,/ 6/ 1/ 6/ | 1,/ 3/ 5/ 3/ |
5,/ 7/ 2/ 7/ | 3,/ 5/ 7/ 5/ | 5,/ 7/ 2/ 7/ | 3,/ 5/ 7/ 5/ |
1,/ 3/ 5/ 3/ | 1,/ 3/ 5/ 3/ | 4,/ 6/ 1/ 6/ | 1,/ 3/ 5/ 3/ |]''';

const int _rate = 22050;

void main() {
  final melody = parseJianpu(_melody);
  final bass = parseJianpu(_bass);
  final arp = parseJianpu(_arp);

  final melodySamples = toMono(decodeWav(synthesizeWav(melody, sampleRate: _rate)));
  final bassSamples = toMono(decodeWav(synthesizeWav(bass, sampleRate: _rate, timbre: 1)));
  final arpSamples = toMono(decodeWav(synthesizeWav(arp, sampleRate: _rate, timbre: 1)));

  final total = [
    melodySamples.length,
    bassSamples.length,
    arpSamples.length,
  ].reduce(math.max);

  final mixed = Float64List(total);
  for (var i = 0; i < total; i++) {
    final m = i < melodySamples.length ? melodySamples[i] : 0.0;
    final b = i < bassSamples.length ? bassSamples[i] : 0.0;
    final a = i < arpSamples.length ? arpSamples[i] : 0.0;
    // 旋律最响，低音次之，琶音最轻；再加 0.4% 白噪声
    mixed[i] = m * 1.0 + b * 0.55 + a * 0.30;
  }
  final rng = math.Random(20260924);
  for (var i = 0; i < total; i++) {
    mixed[i] += (rng.nextDouble() * 2 - 1) * 0.004;
  }
  normalize(mixed, target: 0.85);

  final outDir = Directory('test/fixtures');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final file = File('${outDir.path}/polyphonic.wav');
  file.writeAsBytesSync(encodeWav16(mixed, _rate));

  final truth = melodyTruth(melody);
  stdout.writeln('生成 ${file.path}  (${(file.lengthSync() / 1024).round()} KB, '
      '${(total / _rate).toStringAsFixed(1)} 秒)');
  stdout.writeln('主旋律真值(${truth.length} 个音): ${truth.join(',')}');
}

/// 取乐谱里每个音符的 MIDI 音高（按时间顺序），作为比对真值
List<int> melodyTruth(Score score) {
  final ki = score.key;
  final out = <int>[];
  for (final m in score.measures) {
    for (final item in m.items) {
      if (item is NoteItem && !item.tieToPrev) out.add(noteToPitch(item, ki).midi);
    }
  }
  return out;
}
