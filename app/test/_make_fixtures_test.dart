/// 一次性的辅助测试：调用 tool/make_chord_fixtures.dart 生成扒谱测试音频。
/// （工具脚本本身依赖 Flutter 包，只能用 flutter test 跑。）
library;

import 'package:flutter_test/flutter_test.dart';

import '../tool/make_chord_fixtures.dart' as fixtures;

void main() {
  test('生成和弦测试音频 + 真值', () async {
    await fixtures.main();
  });
}
