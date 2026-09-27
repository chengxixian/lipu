/// 离谱 —— 自动识别简谱并转换成五线谱
///
/// 界面采用 Material 3 / Material You：
/// Android 12+ 通过系统动态色生成配色，其它平台使用种子色色板（可切换）。
library;

import 'package:flutter/material.dart';

import 'omr/omr_service.dart';
import 'state.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LipuApp());
}

class LipuApp extends StatefulWidget {
  const LipuApp({super.key});

  @override
  State<LipuApp> createState() => _LipuAppState();
}

class _LipuAppState extends State<LipuApp> {
  final AppState _appState = AppState();
  final ThemeController _theme = ThemeController();

  @override
  void initState() {
    super.initState();
    _theme.tryDynamicColor();
    _appState.loadCloudSettings();
    // 预热字形模板：首次识谱需要几百次字体渲染，放在启动后分片做好，
    // 这样用户点"识别"时不会先卡一下
    WidgetsBinding.instance.addPostFrameCallback((_) {
      glyphClassifier();
    });
  }

  @override
  void dispose() {
    _appState.dispose();
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: _theme,
      child: AnimatedBuilder(
        animation: _theme,
        builder: (context, _) {
          return MaterialApp(
            title: '离谱',
            debugShowCheckedModeBanner: false,
            theme: _theme.themeFor(Brightness.light),
            darkTheme: _theme.themeFor(Brightness.dark),
            themeMode: _theme.mode,
            home: HomePage(state: _appState),
          );
        },
      ),
    );
  }
}
