/// 主框架：Material 3 底部导航 + Material You 配色切换
library;

import 'package:flutter/material.dart';

import '../core/version.dart';
import '../state.dart';
import 'export_view.dart';
import 'input_view.dart';
import 'score_view.dart';
import 'theme.dart';
import 'transcribe_view.dart';

class HomePage extends StatefulWidget {
  final AppState state;
  const HomePage({super.key, required this.state});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final state = widget.state;
        return Scaffold(
          appBar: AppBar(
            // 标题下面挂版本号：装错包时一眼就能看出来
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('离谱'),
                Text(
                  // 只留版本号：装了哪个包一眼能对上，不再挂更新说明
                  'v$kAppVersion',
                  style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            actions: [
              // 「系统动态色」并进了调色盘菜单，不再占一个独立按钮
              PopupMenuButton<SeedPalette>(
                tooltip: '配色方案',
                icon: Icon(Icons.palette_outlined, color: theme.effectiveSeed),
                onSelected: theme.setPalette,
                itemBuilder: (context) {
                  final entries = <SeedPalette>[
                    if (theme.hasDynamicColor) kDynamicPalette,
                    ...kSeedPalettes,
                  ];
                  final active = theme.activePalette;
                  return entries
                      .map((p) => PopupMenuItem(
                            value: p,
                            child: Row(
                              children: [
                                Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: identical(p, kDynamicPalette)
                                        ? (theme.effectiveSeed)
                                        : p.seed,
                                    shape: BoxShape.circle,
                                    border: identical(p, kDynamicPalette)
                                        ? Border.all(color: scheme.outline, width: 1)
                                        : null,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(child: Text(p.name)),
                                if (identical(p, active))
                                  Icon(Icons.check, size: 18, color: scheme.primary),
                              ],
                            ),
                          ))
                      .toList();
                },
              ),
              IconButton(
                tooltip: theme.mode == ThemeMode.dark ? '切换到浅色' : '切换到深色',
                onPressed: () => theme.setMode(
                  Theme.of(context).brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark,
                ),
                icon: Icon(
                  Theme.of(context).brightness == Brightness.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                ),
              ),
              if (state.busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                ),
            ],
          ),
          body: IndexedStack(
            index: _index,
            children: [
              InputView(state: state, onConverted: () => setState(() => _index = 2)),
              TranscribeView(state: state, onConverted: () => setState(() => _index = 2)),
              ScoreView(state: state),
              ExportView(state: state),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.document_scanner_outlined),
                selectedIcon: Icon(Icons.document_scanner),
                label: '识谱',
              ),
              NavigationDestination(
                icon: Icon(Icons.graphic_eq_outlined),
                selectedIcon: Icon(Icons.graphic_eq),
                label: '扒谱',
              ),
              NavigationDestination(
                icon: Icon(Icons.music_note_outlined),
                selectedIcon: Icon(Icons.music_note),
                label: '乐谱',
              ),
              NavigationDestination(
                icon: Icon(Icons.ios_share_outlined),
                selectedIcon: Icon(Icons.ios_share),
                label: '导出',
              ),
            ],
          ),
        );
      },
    );
  }
}
