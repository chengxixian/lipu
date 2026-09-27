/// 把内置谱例导出成 MusicXML 文件，用来验证 Verovio 能不能正确排版我们生成的 MusicXML。
///
///   dart run tool/dump_musicxml.dart <输出目录>
library;

import 'dart:io';

import '../lib/core/musicxml.dart';
import '../lib/core/parse.dart';

const Map<String, String> _samples = {
  'simple': '''标题：小星星
1=C 4/4 ♩=96
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]''',
  'chord_grand': '''标题：和弦与大谱表
1=C 4/4 ♩=96
高音: [1 3 5] [4 6 1'] [5 7 2'] [1 3 5] |
高音: [4 6 1'] [2 4 6] [5 7 2'] [1 3 5] |
低音: 1,, - - - | 4,, - - - |
低音: 5,, - - - | 1,, - - - |]''',
  'tricky': '''标题：记号测试
1=G 4/4 ♩=88
5 5 6 5 | 1' 7 1' - | 4/ 4/ #4 3 | 2 0 1 - |
(1 2 3) 6~ 6 5 - - | 1' 1' 7 6 | 5 - - - |]''',
};

void main(List<String> args) {
  final outDir = Directory(args.isEmpty ? 'build/musicxml' : args.first);
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  _samples.forEach((name, text) {
    final score = parseJianpu(text);
    final xml = toMusicXML(score, padIncompleteMeasures: true);
    final file = File('${outDir.path}/$name.musicxml');
    file.writeAsStringSync(xml);
    stdout.writeln('${file.path}  ${xml.length} 字节  '
        '${score.measures.length} 小节 / ${score.pitchCount} 个音'
        '${score.isGrandStaff ? " / 大谱表" : ""}');
  });
}
