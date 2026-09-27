/// 识谱页：选图片 → AI 识谱 → 直接转五线谱
///
/// 按需求精简：只保留「选择简谱图片」+「转化为五线谱」+ 右上角设置。
/// 识别结果不再需要人工逐行勾选（AI 直接给结构化音符事件、声部已经分好），
/// 中间的简谱文本框也一并去掉。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../omr/cloud_recognizer.dart';
import '../state.dart';
import 'common.dart';
import 'wavy_progress.dart';

class InputView extends StatefulWidget {
  final AppState state;

  /// 转换完成后跳到乐谱页
  final VoidCallback onConverted;

  const InputView({super.key, required this.state, required this.onConverted});

  @override
  State<InputView> createState() => _InputViewState();
}

class _InputViewState extends State<InputView> {
  final TextEditingController _endpointCtrl = TextEditingController();
  final TextEditingController _keyCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();

  /// 快速识谱（不让模型"思考"）
  bool _fastMode = true;

  /// 分行并发识谱
  bool _splitLines = true;

  @override
  void initState() {
    super.initState();
    _syncCloudFields();
  }

  @override
  void dispose() {
    _endpointCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  void _syncCloudFields() {
    final cloud = widget.state.cloud;
    _endpointCtrl.text = cloud.endpoint;
    _keyCtrl.text = cloud.apiKey;
    _modelCtrl.text = cloud.model;
  }

  Future<void> _pickImages() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      dialogTitle: '选择简谱图片（可多选）',
    );
    if (picked.isEmpty) return;
    final inputs = <RecognizeInput>[];
    for (final f in picked) {
      try {
        final bytes = await f.readAsBytes();
        if (bytes.isNotEmpty) inputs.add(RecognizeInput(f.name, bytes));
      } catch (_) {
        // 单张失败不影响其它
      }
    }
    if (inputs.isEmpty) return;
    await widget.state.recognizeImages(inputs);
  }

  /// 底部设置面板：AI 接口配置
  Future<void> _openSettings() async {
    final state = widget.state;
    // 面板里的开关先取当前配置，保存时才写回
    _fastMode = state.cloud.fastMode;
    _splitLines = state.cloud.splitLines;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final scheme = Theme.of(ctx).colorScheme;
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 4,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('识谱设置', style: Theme.of(ctx).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '图片识谱用视觉大模型逐音转写，并把结果整理成**结构化音符事件**'
                    '（音高、起始拍、时值、声部），直接生成五线谱与 MIDI。'
                    '图片会发送到你填写的服务。',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Text('AI 接口配置', style: Theme.of(ctx).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _endpointCtrl,
                    decoration: const InputDecoration(
                      labelText: '接口地址',
                      hintText: kDefaultCloudEndpoint,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'API Key', isDense: true),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _modelCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型名',
                      hintText: kDefaultCloudModel,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _fastMode,
                    onChanged: (v) => setSheet(() => _fastMode = v),
                    title: const Text('快速识谱（不让模型"思考"）', style: TextStyle(fontSize: 14)),
                    subtitle: Text(
                      '整页 6~7 秒。实测：开着"思考"同样一页要 117 秒（输出里 94% 是思考），'
                      '音数并不更多。关掉后自检变弱，但时值/八度还有自动补救与本地核对兜底。',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _splitLines,
                    onChanged: (v) => setSheet(() => _splitLines = v),
                    title: const Text('分行并发识谱', style: TextStyle(fontSize: 14)),
                    subtitle: Text(
                      '先把整页按行切开，多段同时识别再按小节拼接：更快，而且密集页面不容易'
                      '漏行/丢低音声部（哪段错了只重试那一段）。切不动或失败会自动退回整页识别。',
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          await state.saveCloudSettings(CloudConfig(
                            endpoint: _endpointCtrl.text.trim().isEmpty
                                ? kDefaultCloudEndpoint
                                : _endpointCtrl.text.trim(),
                            apiKey: _keyCtrl.text.trim(),
                            model: _modelCtrl.text.trim().isEmpty
                                ? kDefaultCloudModel
                                : _modelCtrl.text.trim(),
                            prompt: state.cloud.prompt,
                            promptCustom: state.cloud.promptCustom,
                            fastMode: _fastMode,
                            splitLines: _splitLines,
                          ));
                          setSheet(() {});
                        },
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('保存'),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        state.cloud.isConfigured ? '已配置 ✓' : '未配置',
                        style: TextStyle(
                          fontSize: 12,                          color: state.cloud.isConfigured ? scheme.primary : scheme.error,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '兼容任何 OpenAI Chat Completions 格式的视觉模型；'
                    '默认值已按 DeepSeek 视觉模型填好，只需填 API Key。'
                    'Key 只保存在本机（应用私有目录），不会打进安装包。\n'
                    '识别提示词：内置 v${state.cloud.promptRev}'
                    '${state.cloud.promptCustom ? '（自定义）' : '（随版本更新，升级后自动用新版）'}',
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted) setState(_syncCloudFields);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final engineLabel = state.cloud.isConfigured
        ? 'AI 识谱 · ${state.cloud.model}'
        : 'AI 识谱（未配置，点右上角设置）';
    final ready = state.score != null && (state.score?.noteCount ?? 0) > 0;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        SectionCard(
          title: '图片识谱',
          subtitle: '$engineLabel　·　支持多选',
          icon: Icons.image_outlined,
          actions: [
            IconButton(
              tooltip: '识谱设置',
              onPressed: state.busy ? null : _openSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: state.busy ? null : _pickImages,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('选择简谱图片'),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: (state.busy || !ready) ? null : widget.onConverted,
                icon: const Icon(Icons.music_note),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('转化为五线谱'),
                ),
              ),
              if (state.busy) ...[
                const SizedBox(height: 14),
                // 始终是确定进度：AI 识谱按已用时间估算，不会只转一条波浪线
                WavyProgressBar(value: state.omrProgress.clamp(0.02, 1.0), height: 12),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.omrStage.isEmpty ? '准备中…' : state.omrStage,
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ),
                    Text(
                      '${(state.omrProgress * 100).round()}%',
                      style: TextStyle(fontSize: 11.5, color: scheme.primary),
                    ),
                  ],
                ),
              ],
              if (state.status != null) ...[
                const SizedBox(height: 10),
                Text(state.status!, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
