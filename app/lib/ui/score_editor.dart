/// 乐谱页内嵌的简谱编辑器：直接改文本，五线谱即时重排。
///
/// 放在乐谱页而不是单独一页，是为了**编辑时能看见谱面**——上半屏是排版结果，
/// 下半屏是简谱文本；改动经 350ms 防抖后重排（AppState 里已有防抖）。
library;

import 'package:flutter/material.dart';

import '../state.dart';

class ScoreEditorPanel extends StatefulWidget {
  final AppState state;
  final VoidCallback onClose;
  const ScoreEditorPanel({super.key, required this.state, required this.onClose});

  @override
  State<ScoreEditorPanel> createState() => _ScoreEditorPanelState();
}

class _ScoreEditorPanelState extends State<ScoreEditorPanel> {
  late final TextEditingController _controller = TextEditingController(text: widget.state.text);
  final FocusNode _focus = FocusNode();
  bool _showHelp = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_syncFromState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_syncFromState);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 外部改了谱子（识别/扒谱/示例）时同步进来；正在输入时不动，避免打断
  void _syncFromState() {
    if (!mounted) return;
    final text = widget.state.text;
    if (text != _controller.text && !_focus.hasFocus) {
      _controller.text = text;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warnings = widget.state.warnings;
    return Container(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 0),
            child: Row(
              children: [
                Icon(Icons.edit_note_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Text('编辑简谱', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
                const SizedBox(width: 10),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          label: const Text('示例：小星星', style: TextStyle(fontSize: 11.5)),
                          onPressed: () {
                            widget.state.loadSample(0);
                            _controller.text = widget.state.text;
                          },
                        ),
                        const SizedBox(width: 6),
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          label: const Text('示例：茉莉花', style: TextStyle(fontSize: 11.5)),
                          onPressed: () {
                            widget.state.loadSample(1);
                            _controller.text = widget.state.text;
                          },
                        ),
                        const SizedBox(width: 6),
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          avatar: Icon(Icons.help_outline, size: 15, color: scheme.onSurfaceVariant),
                          label: const Text('语法', style: TextStyle(fontSize: 11.5)),
                          onPressed: () => setState(() => _showHelp = !_showHelp),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '收起编辑',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ],
            ),
          ),
          if (_showHelp)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: const SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: _SyntaxHelp(),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                onChanged: widget.state.setText,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5, height: 1.5),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  hintText: '1=C 4/4 ♩=96\n1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]',
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    warnings.isEmpty
                        ? '改动会自动重排五线谱'
                        : warnings.first + (warnings.length > 1 ? '（共 ${warnings.length} 条）' : ''),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: warnings.isEmpty ? scheme.onSurfaceVariant : scheme.tertiary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SyntaxHelp extends StatelessWidget {
  const _SyntaxHelp();

  @override
  Widget build(BuildContext context) {
    const rows = <List<String>>[
      ['1=C 4/4 ♩=96', '调号 / 拍号 / 速度（放行首或单独一行）'],
      ['1 2 3 4 5 6 7', '音级；0 表示休止符'],
      ["1'  1''", '上八度（也可写 1^）'],
      ['1,  1,,', '下八度（也可写 1v）'],
      ['1/  1//  1///', '减时线：八分 / 十六分 / 三十二分'],
      ['1.  1/.', '附点四分 / 附点八分'],
      ['1-  1--', '延音：每个 - 延长一个四分音符'],
      ['#4  b7  n1', '升 / 降 / 还原'],
      ['[1 3 5]', '和弦：方括号里多个音同时发声（[135] 也认）'],
      ['高音: … 低音: …', '行首写声部，两行自动排成大谱表'],
      ['|  ||  |]  |:  :|', '小节线 / 终止线 / 反复记号'],
      ['(1 2 3)  6~ 6', '连音线'],
      ['1[啊]', '歌词'],
      ['标题： 词： 曲：', '元信息'],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows
          .map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 118,
                      child: Text(r[0], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ),
                    Expanded(child: Text(r[1], style: const TextStyle(fontSize: 12))),
                  ],
                ),
              ))
          .toList(),
    );
  }
}
