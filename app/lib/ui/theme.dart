/// Material You 主题：Android 12+ 读取系统动态色，其它平台使用种子色方案
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Material You 基线色板（取自 Material 3 官方配色）
class SeedPalette {
  final String name;
  final Color seed;
  const SeedPalette(this.name, this.seed);
}

const List<SeedPalette> kSeedPalettes = [
  SeedPalette('紫罗兰（基线）', Color(0xFF6750A4)),
  SeedPalette('青绿', Color(0xFF00696D)),
  SeedPalette('靛蓝', Color(0xFF4355B9)),
  SeedPalette('苔绿', Color(0xFF4C662B)),
  SeedPalette('珊瑚', Color(0xFF8E4956)),
  SeedPalette('琥珀', Color(0xFF7D5700)),
];

/// 伪色板：代表"跟随系统动态色"，放在调色盘菜单里而不是单独一个按钮
const SeedPalette kDynamicPalette = SeedPalette('跟随系统（动态色）', Color(0xFF6750A4));

/// 读取 Android 12+ 动态色（通过 MethodChannel，无需第三方插件）
class DynamicColorReader {
  static const MethodChannel _channel = MethodChannel('jianpu/dynamic_color');

  /// 返回系统主色（取不到时返回 null）
  static Future<Color?> systemSeed() async {
    try {
      final value = await _channel.invokeMethod<int>('getSystemSeed');
      if (value == null) return null;
      return Color(value);
    } catch (_) {
      return null;
    }
  }
}

class ThemeController extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.system;
  SeedPalette _palette = kSeedPalettes.first;
  Color? _dynamicSeed;
  bool _dynamicTried = false;
  bool _useDynamic = true;

  ThemeMode get mode => _mode;
  SeedPalette get palette => _palette;
  bool get hasDynamicColor => _dynamicSeed != null;
  bool get usingDynamicColor => _useDynamic && _dynamicSeed != null;

  /// 当前生效的色板（动态色时返回 [kDynamicPalette]）
  SeedPalette get activePalette => usingDynamicColor ? kDynamicPalette : _palette;

  /// 尝试启用系统动态色（Android 12+ 有效）
  Future<void> tryDynamicColor() async {
    if (_dynamicTried) return;
    _dynamicTried = true;
    final seed = await DynamicColorReader.systemSeed();
    if (seed != null) {
      _dynamicSeed = seed;
      notifyListeners();
    }
  }

  void setMode(ThemeMode m) {
    _mode = m;
    notifyListeners();
  }

  /// 选调色盘：其中 [kDynamicPalette] 表示"跟随系统动态色"
  void setPalette(SeedPalette p) {
    if (identical(p, kDynamicPalette)) {
      _useDynamic = _dynamicSeed != null;
      notifyListeners();
      return;
    }
    _palette = p;
    _useDynamic = false;
    notifyListeners();
  }

  Color get effectiveSeed => usingDynamicColor ? _dynamicSeed! : _palette.seed;

  ThemeData themeFor(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: effectiveSeed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        scrolledUnderElevation: 3,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        elevation: 1,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}

/// 把 ThemeController 暴露给整棵树
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({super.key, required ThemeController controller, required super.child})
      : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope 未挂载');
    return scope!.notifier!;
  }
}

