/// 「增强包」管理区块：下载 / 续传 / 从文件导入 / 删除，并显示状态与进度。
///
/// 放在扒谱页的"分析参数"里——用户选了需要增强包的引擎时，这里就是装包的地方。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../transcribe/model_packs.dart';

/// 增强包区块（自带状态管理，外部只需要给一个 store）
class ModelPackSection extends StatefulWidget {
  const ModelPackSection({super.key, required this.store, this.onChanged});

  final ModelPackStore store;

  /// 状态变化（装好/删掉）时通知外面刷新引擎可用性
  final VoidCallback? onChanged;

  /// 界面用的包目录：**与后端 `ModelPackStore.forApp()` 是同一个**
  /// （以前界面和后端各算一次路径，一旦不一致就会出现"界面说已安装、识别说没装"）
  static ModelPackStore defaultStore() => ModelPackStore.forApp();

  @override
  State<ModelPackSection> createState() => _ModelPackSectionState();
}

class _ModelPackSectionState extends State<ModelPackSection> {
  final Map<String, PackState> _states = {};
  final Map<String, double> _progress = {};
  String? _busyId;
  String? _error;
  String? _stage;
  final TextEditingController _tokenCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _tokenCtl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    for (final spec in kModelPacks) {
      final s = await widget.store.stateOf(spec);
      if (!mounted) return;
      setState(() => _states[spec.id] = s);
    }
  }

  Future<void> _download(ModelPackSpec spec) async {
    setState(() {
      _busyId = spec.id;
      _error = null;
      _progress[spec.id] = 0;
    });
    try {
      await widget.store.download(
        spec,
        token: _tokenCtl.text.trim().isEmpty ? null : _tokenCtl.text.trim(),
        // 把"正在从哪个源下 / 已下多少 / 换源了"显示出来：
        // 手机端下载容易失败，用户需要知道卡在哪一步
        onStage: (s) {
          if (mounted) setState(() => _stage = s);
        },
        onProgress: (p) {
          if (mounted) setState(() => _progress[spec.id] = p.fraction);
        },
      );
      if (!mounted) return;
      setState(() => _states[spec.id] = PackState.ready);
      widget.onChanged?.call();
      _toast('${spec.title} 已安装');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '${spec.title}：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busyId = null;
          _stage = null;
          _progress.remove(spec.id);
        });
        await _refresh();
      }
    }
  }

  Future<void> _import(ModelPackSpec spec) async {
    // **多选**：ONNX 的外部权重（`.onnx.data`）必须一起导入，
    // 否则 onnxruntime 加载会失败（用户踩过："两个文件同目录也导入失败"）。
    // 就算只选了主文件，包管理器也会在它同目录里自动找附属文件 ✓
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择 ${spec.fileName}（如有 ${spec.fileName}.data 请一起选中）',
      type: FileType.any,
    );
    if (picked.isEmpty) return;
    final files = <File>[
      for (final f in picked)
        if (f.path != null) File(f.path!),
    ];
    if (files.isEmpty) return;
    setState(() {
      _busyId = spec.id;
      _error = null;
      _stage = '导入 ${files.length} 个文件…';
    });
    try {
      final file = await widget.store.import(spec, files.first, extra: files.skip(1).toList());
      if (!mounted) return;
      final installed = widget.store.installedFiles(spec);
      setState(() => _states[spec.id] = PackState.ready);
      widget.onChanged?.call();
      _toast('${spec.title} 已导入（${installed.length} 个文件：${installed.join("、")}）');
      if (file.lengthSync() == 0) {
        setState(() => _error = '${spec.title}：主文件是 0 字节，请确认选对了文件');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '${spec.title}：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busyId = null;
          _stage = null;
        });
        await _refresh();
      }
    }
  }

  Future<void> _delete(ModelPackSpec spec) async {
    await widget.store.delete(spec);
    if (!mounted) return;
    setState(() => _states[spec.id] = PackState.missing);
    widget.onChanged?.call();
    _toast('已删除 ${spec.title}');
  }

  /// 打开网盘分享页（应用内 WebView；网盘不能用程序下载，只能让用户自己去取）
  Future<void> _openNetdisk(ModelPackSpec spec) async {
    final url = spec.netdiskUrl;
    if (url == null || url.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _WebPage(title: spec.title, url: url),
      ),
    );
    if (mounted) {
      setState(() => _stage = '取回 ${spec.fileName} 与 ${spec.fileName}.data 后，点「从文件导入」');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.extension_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('增强包（可选，按需下载）', style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '高精度模型体积大，不塞进安装包；装好后可在上面的引擎里选它。'
          '下载中途断了可以继续；也可以把发行包 dist/packs 里的量化版拷过来"从文件导入"。',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (final spec in kModelPacks) _tile(spec, scheme),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!, style: TextStyle(fontSize: 11.5, color: scheme.error)),
          ),
      ],
    );
  }

  Widget _tile(ModelPackSpec spec, ColorScheme scheme) {
    final state = _states[spec.id] ?? PackState.missing;
    final busy = _busyId == spec.id;
    final progress = _progress[spec.id];
    final installed = state == PackState.ready;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(spec.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    switch (state) {
                      PackState.ready => '已安装',
                      PackState.downloading => '可续传',
                      PackState.invalid => '文件不完整',
                      PackState.missing => '未安装',
                    },
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            Text('${ModelPackStore.describe(spec)} · 来源：${spec.attribution}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            if (spec.sources.isNotEmpty)
              Text(
                '下载源：${spec.sources.map((s) => s.label).join(" → ")}（会按顺序自动重试，'
                '下完核对 SHA256）',
                style: TextStyle(fontSize: 10.5, color: scheme.outline),
              ),
            if (spec.nonCommercial)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '⚠ ${spec.license}：仅限非商用。App 不内嵌也不代下，'
                  '${spec.licensePage == null ? "" : "请先到 ${spec.licensePage} 接受协议，"}'
                  '再填 token 下载或自己下好导入。',
                  style: TextStyle(fontSize: 10.5, color: scheme.error),
                ),
              ),
            if (_stage != null && busy)
              Text(_stage!, style: TextStyle(fontSize: 10.5, color: scheme.primary)),
            // 诊断：导入后仍显示"未安装"时，这两行能直接看出问题
            // （文件落在哪个目录、实际装了哪些文件、各多大）
            Text('包目录：${widget.store.root.path}',
                style: TextStyle(fontSize: 10, color: scheme.outline)),
            Builder(builder: (_) {
              final d = widget.store.detailOf(spec);
              final names = widget.store.installedFiles(spec);
              final files = names.isEmpty
                  ? '（该目录下没有本包的文件）'
                  : names.map((n) {
                      final f = File(
                          '${widget.store.root.path}${Platform.pathSeparator}$n');
                      final mb = f.existsSync()
                          ? '${(f.lengthSync() / 1048576).toStringAsFixed(1)}MB'
                          : '?';
                      return '$n($mb)';
                    }).join('、');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('已装文件：$files',
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                  if (d.expected > 0)
                    Text(
                      '实际 ${(d.actual / 1048576).toStringAsFixed(1)}MB / '
                      '期望 ${(d.expected / 1048576).toStringAsFixed(1)}MB'
                      '${d.state == PackState.invalid ? "　← 大小不符，所以显示未安装" : ""}',
                      style: TextStyle(
                          fontSize: 10,
                          color: d.state == PackState.invalid ? scheme.error : scheme.outline),
                    ),
                  // 大小不符但用户想试：给一条明确的路，而不是卡在"未安装"
                  if (d.state == PackState.invalid)
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              await widget.store.accept(spec);
                              widget.onChanged?.call();
                              if (!mounted) return;
                              setState(() => _states[spec.id] = PackState.ready);
                              _toast('已忽略大小检查；若模型真坏了，识别时会明确报错');
                            },
                      icon: const Icon(Icons.warning_amber_rounded, size: 16),
                      label: const Text('忽略大小检查，仍要使用', style: TextStyle(fontSize: 11)),
                    ),
                ],
              );
            }),
            const SizedBox(height: 6),
            // 门控模型要 token：先给个输入框（只在需要时出现）
            if (spec.needsToken && !installed) ...[
              TextField(
                controller: _tokenCtl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'HuggingFace token（hf_…）',
                  helperText: '在 huggingface.co/settings/tokens 生成；只在本次下载用，不落盘',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
            ],
            if (busy && progress != null)
              LinearProgressIndicator(value: progress == 0 ? null : progress)
            else
              Wrap(
                spacing: 8,
                children: [
                  if (spec.downloadable && !installed)
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : () => _download(spec),
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(state == PackState.downloading ? '继续下载' : '下载'),
                    ),
                  // 网盘按钮：大文件放网盘，App 只负责跳过去
                  if (spec.hasNetdisk && !installed)
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : () => _openNetdisk(spec),
                      icon: const Icon(Icons.cloud_download_outlined, size: 18),
                      label: Text(spec.netdiskLabel),
                    ),
                  if (!installed)
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => _import(spec),
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('从文件导入'),
                    ),
                  if (installed)
                    TextButton.icon(
                      onPressed: busy ? null : () => _delete(spec),
                      icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
                      label: Text('删除', style: TextStyle(color: scheme.error)),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 简单的应用内网页（网盘分享页、模型页等）
class _WebPage extends StatelessWidget {
  const _WebPage({required this.title, required this.url});

  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: '复制链接',
            icon: const Icon(Icons.link),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('链接已复制'), duration: Duration(seconds: 2)),
              );
            },
          ),
        ],
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
      ),
    );
  }
}