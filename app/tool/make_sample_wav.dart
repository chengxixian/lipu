/// 生成示例音频：把内置示例简谱渲染成 WAV，供「扒谱」页试用
///
///   dart run tool/make_sample_wav.dart
///
/// 只依赖纯 Dart 模块（乐谱模型 + 合成器 + WAV 编码），不需要 Flutter。
library;

import 'dart:io';

import '../lib/audio/synth.dart';
import '../lib/core/parse.dart';

const Map<String, String> _samples = {
  'xiaoxingxing': '''标题：小星星
1=C 4/4 ♩=96
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |
5 5 4 4 | 3 3 2 - | 5 5 4 4 | 3 3 2 - |
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]''',
  'molihua': '''标题：茉莉花（片段）
1=D 4/4 ♩=72
3 3 5 6 | 1' 6 5 6 | 5 5 3 5 | 6 - - - |
3 3 5 6 | 1' 6 5 6 | 5 5 3 5 | 6 - - - |]''',
};

void main() {
  final outDir = Directory('test/fixtures');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  _samples.forEach((name, text) {
    final score = parseJianpu(text);
    final wav = synthesizeWav(score, sampleRate: 22050);
    final file = File('${outDir.path}/$name.wav');
    file.writeAsBytesSync(wav);
    print('生成 ${file.path}  (${(wav.length / 1024).round()} KB, ${score.noteCount} 个音)');
  });
}
