/// 应用目录工具（纯 dart:io，不依赖 path_provider）
///
/// 之所以不用 path_provider：它在 Android 上会引入 jni/jni_flutter 原生插件，
/// 触发 CMake 构建；而 AGP 在含空格的 Windows 路径下解析 CMake 的 buildFiles iSON 会失败。
/// 这里自己按平台推导目录，功能相同、构建更稳。
library;

import 'dart:io';

class AppPaths {
  /// 应用私有数据目录（用于保存配置）
  static Directory baseDir() {
    if (Platform.isAndroid) {
      // Directory.systemTemp 在 Android 上是 /data/user/0/<pkg>/cache
      try {
        final files = Directory('${Directory.systemTemp.parent.path}/files');
        if (!files.existsSync()) files.createSync(recursive: true);
        return files;
      } catch (_) {
        return Directory.systemTemp;
      }
    }
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final docs = Directory('$home${Platform.pathSeparator}Documents');
      if (docs.existsSync()) return docs;
    }
    return Directory.systemTemp;
  }

  /// 导出文件的默认目录
  static Directory outputDir() {
    final dir = Directory('${baseDir().path}${Platform.pathSeparator}离谱');
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (_) {
        return baseDir();
      }
    }
    return dir;
  }

  /// 临时文件目录（试听用的 WAV）
  static Directory tempDir() => Directory.systemTemp;

  static String join(Directory dir, String name) => '${dir.path}${Platform.pathSeparator}$name';
}
