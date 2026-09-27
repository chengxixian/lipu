/// 导出页：MusicXML / MIDI / WAV / PNG / 简谱文本
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/synth.dart';
import '../core/app_paths.dart';
import '../core/midi.dart';
import '../core/musicxml.dart';
import '../core/parse.dart';
import '../render/staff_layout.dart';
import '../render/verovio_view.dart';
import '../state.dart';
import 'common.dart';
import 'score_view.dart' show kA4Width, kA4Height, renderPagePngFallback;

class ExportView extends StatefulWidget {
  final AppState state;
  const ExportView({super.key, required this.state});

  @override
  State<ExportView> createState() => _ExportViewState();
}

class _ExportViewState extends State<ExportView> {
  String? _lastPath;

  /// 正在导出时的提示（Verovio 渲染一页要几百毫秒）
  String? _exporting;

  Future<Directory> _outputDir() async => AppPaths.outputDir();

  String _safeName(String title, String fallback) {
    final t = title.trim().isEmpty ? fallback : title.trim();
    return t.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
  }

  String _mimeFor(String fileName) {
    if (fileName.endsWith('.musicxml') || fileName.endsWith('.xml')) return 'application/vnd.recordare.musicxml+xml';
    if (fileName.endsWith('.mid')) return 'audio/midi';
    if (fileName.endsWith('.wav')) return 'audio/wav';
    if (fileName.endsWith('.png')) return 'image/png';
    return 'text/plain';
  }

  /// 优先弹出系统「另存为」对话框，失败时退回应用文档目录
  Future<void> _save(String fileName, List<int> bytes, String label) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    try {
      final uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: data,
        mimeType: _mimeFor(fileName),
        dialogTitle: '保存$label',
      );
      if (uri == null) return; // 用户取消
      setState(() => _lastPath = uri.toString());
      _snack('$label 已保存：$uri');
      return;
    } catch (_) {
      // 某些平台不支持另存为对话框，退回文档目录
    }
    final dir = await _outputDir();
    final f = File('${dir.path}${Platform.pathSeparator}$fileName');
    await f.writeAsBytes(data, flush: true);
    setState(() => _lastPath = f.path);
    _snack('$label 已保存：${f.path}');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  Future<void> _exportMusicXml() async {
    final score = widget.state.score;
    if (score == null) return;
    final xml = toMusicXML(score);
    await _save('${_safeName(score.meta.title, 'jianpu')}.musicxml', utf8Bytes(xml), 'MusicXML');
  }

  Future<void> _exportMidi() async {
    final score = widget.state.score;
    if (score == null) return;
    await _save('${_safeName(score.meta.title, 'jianpu')}.mid', toMidi(score), 'MIDI');
  }

  Future<void> _exportWav() async {
    final score = widget.state.score;
    if (score == null) return;
    await _save('${_safeName(score.meta.title, 'jianpu')}.wav', synthesizeWav(score), '音频');
  }

  Future<void> _exportPng() async {
    final score = widget.state.score;
    if (score == null) return;
    final base = _safeName(score.meta.title, 'jianpu');

    // 首选 Verovio：同一份 MusicXML，出图和屏幕上看到的一致（专业排版）
    setState(() => _exporting = '正在用 Verovio 排版…');
    var pngs = <Uint8List>[];
    try {
      pngs = await exportScorePngsHeadless(
        toMusicXML(score, padIncompleteMeasures: true),
        showHeader: widget.state.showTitle,
      );
    } catch (_) {
      pngs = [];
    }

    // 退路：内置排版引擎
    if (pngs.isEmpty) {
      setState(() => _exporting = 'Verovio 不可用，改用内置排版…');
      final doc = layoutScore(
        score,
        width: kA4Width,
        style: StaffStyle(
          showLyrics: widget.state.showLyrics,
          showTitle: widget.state.showTitle,
          space: 11,
          pageHeight: kA4Height,
        ),
      );
      final count = doc.pages.isEmpty ? 1 : doc.pages.length;
      for (var i = 0; i < count; i++) {
        final png = await renderPagePngFallback(
          score,
          showLyrics: widget.state.showLyrics,
          showTitle: widget.state.showTitle,
          pageIndex: i,
        );
        if (png != null) pngs.add(png);
      }
    }

    setState(() => _exporting = null);
    if (pngs.isEmpty) return;
    for (var i = 0; i < pngs.length; i++) {
      final suffix = pngs.length > 1 ? '_p${i + 1}' : '';
      await _save('$base$suffix.png', pngs[i], '五线谱图片');
    }
  }

  Future<void> _exportText() async {
    final score = widget.state.score;
    if (score == null) return;
    final text = toJianpu(score);
    await _save('${_safeName(score.meta.title, 'jianpu')}.jianpu.txt', utf8Bytes(text), '简谱文本');
  }

  Future<void> _copyText() async {
    final score = widget.state.score;
    if (score == null) return;
    await Clipboard.setData(ClipboardData(text: toJianpu(score)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('简谱文本已复制到剪贴板')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final score = widget.state.score;
    final scheme = Theme.of(context).colorScheme;
    final enabled = score != null && score.noteCount > 0;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        SectionCard(
          title: '五线谱导出',
          subtitle: '用 Verovio 排版（与屏幕上看到的一致）；MusicXML 可被 MuseScore / Finale / Sibelius 直接打开编辑',
          icon: Icons.ios_share_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_exporting != null) ...[
                Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                    ),
                    const SizedBox(width: 10),
                    Text(_exporting!, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
              FilledButton.icon(
                onPressed: enabled ? _exportMusicXml : null,
                icon: const Icon(Icons.description_outlined),
                label: const Text('MusicXML'),
              ),
              FilledButton.tonalIcon(
                onPressed: enabled ? _exportMidi : null,
                icon: const Icon(Icons.piano_outlined),
                label: const Text('MIDI'),
              ),
              FilledButton.tonalIcon(
                onPressed: enabled && _exporting == null ? _exportPng : null,
                icon: const Icon(Icons.image_outlined),
                label: const Text('五线谱 PNG'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? _exportWav : null,
                icon: const Icon(Icons.graphic_eq),
                label: const Text('试听音频 WAV'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? _exportText : null,
                icon: const Icon(Icons.text_snippet_outlined),
                label: const Text('简谱文本'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? _copyText : null,
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('复制简谱'),
              ),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: '乐谱信息',
          icon: Icons.info_outline,
          child: enabled
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('标题', score.meta.title.isEmpty ? '（未命名）' : score.meta.title),
                    _kv('调号', '1 = ${score.key.letter}${score.key.alter > 0 ? '#' * score.key.alter : score.key.alter < 0 ? 'b' * (-score.key.alter) : ''}'
                        '${score.key.mode == 'minor' ? '（小调）' : ''}'),
                    _kv('拍号', '${score.meta.beats}/${score.meta.beatType}'),
                    _kv('速度', '♩ = ${score.meta.tempo}'),
                    _kv('规模', '${score.measures.length} 小节 / ${score.noteCount} 个音'),
                    if (score.lowConfidenceCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '提示：有 ${score.lowConfidenceCount} 个音符来自低置信度识别，建议对照原谱校对',
                          style: TextStyle(color: scheme.error, fontSize: 12),
                        ),
                      ),
                  ],
                )
              : Text('还没有乐谱可导出', style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        if (_lastPath != null)
          SectionCard(
            title: '最近保存',
            icon: Icons.folder_outlined,
            child: SelectableText(_lastPath!, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 64, child: Text(k, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 12.5))),
          ],
        ),
      );
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
