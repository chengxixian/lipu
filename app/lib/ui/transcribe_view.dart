/// 扒谱页：听歌扒谱（音频文件）+ 哼唱记谱（麦克风），带钢琴卷帘人工校正
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state.dart';
import '../transcribe/audio_source.dart';
import '../transcribe/backends.dart';
import '../transcribe/basic_pitch_engine.dart';
import '../transcribe/melody.dart';
import '../transcribe/model_packs.dart';
import '../transcribe/quantize.dart';
import '../transcribe/recorder.dart';
import 'common.dart';
import 'model_pack_section.dart';
import 'piano_roll.dart';
import 'wavy_progress.dart';

/// 在后台 isolate 里跑分析，避免界面卡住
MelodyAnalysis _analyzeTask(Map<String, dynamic> args) {
  return analyzeMelody(
    args['samples'] as Float64List,
    sampleRate: args['rate'] as int,
    options: args['options'] as TranscribeOptions,
  );
}

class TranscribeView extends StatefulWidget {
  final AppState state;
  final VoidCallback onConverted;

  const TranscribeView({super.key, required this.state, required this.onConverted});

  @override
  State<TranscribeView> createState() => _TranscribeViewState();
}

class _TranscribeViewState extends State<TranscribeView> {
  bool _micMode = false;
  bool _busy = false;
  String? _status;
  String? _clipName;
  double _clipDuration = 0;

  AudioClip? _clip;
  MelodyAnalysis? _analysis;
  TranscribeOptions _options = const TranscribeOptions();

  // 识别引擎：走后端注册表（lib/transcribe/backends.dart）
  // 内置 Basic Pitch（默认）/ 内置纯 Dart 算法 / 可选增强包（钢琴 CRNN、Tsumugi…）
  String _backendId = 'basic_pitch';
  final ModelPackStore _packs = ModelPackSection.defaultStore();
  bool _melodyOnly = true;
  bool _twoStaves = true;
  String _engineUsed = '';
  double _progress = 0;
  String _stage = '';

  // 量化参数
  double _bpmOverride = 0;
  String? _keyOverride;
  int _beats = 4;
  int _beatType = 4;
  double _grid = 0.25;
  bool _keepRests = true;

  // 录音
  final MicRecorder _mic = MicRecorder();
  LivePitchTracker? _tracker;
  StreamSubscription<Uint8List>? _sub;
  bool _recording = false;
  double _liveMidi = 0;
  double _liveLevel = 0;
  double _recordSeconds = 0;
  Timer? _ticker;
  final List<double> _recorded = <double>[];

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    _mic.dispose();
    super.dispose();
  }

  /* ---------------- 文件扒谱 ---------------- */

  Future<void> _pickAndAnalyze() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择音频文件',
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus'],
    );
    if (picked == null) return;
    final path = picked.path;
    if (path == null) {
      setState(() => _status = '无法读取该文件路径');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在解码音频…';
      _analysis = null;
    });
    try {
      final clip = await loadAudioFile(path);
      setState(() {
        _clip = clip;
        _clipName = clip.name;
        _clipDuration = clip.durationSec;
        _status = '已解码 ${clip.durationSec.toStringAsFixed(1)} 秒，正在分析主旋律…';
      });
      await _analyze(clip);
    } catch (e) {
      setState(() => _status = '处理失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _analyze(AudioClip clip) async {
    final analysis = await _runEngine(clip);
    if (!mounted) return;
    setState(() {
      _analysis = analysis;
      _bpmOverride = analysis.bpm;
      _keyOverride = null;
      _status = '分析完成（$_engineUsed）：检测到 ${analysis.activeNotes.length} 个音'
          '${analysis.bpm > 0 ? '，估计速度 ${analysis.bpm.round()} BPM' : ''}'
          '，估计调号 ${analysis.keyName}';
      _progress = 1;
      _stage = '';
    });
  }

  void _onProgress(double fraction, String stage) {
    if (!mounted) return;
    setState(() {
      _progress = fraction;
      _stage = stage;
    });
  }

  /// 打开"增强包"抽屉（毛玻璃面板）：包管理不占主页面篇幅
  Future<void> _openPackDrawer() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => Material(
          color: Theme.of(ctx).colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            controller: scroll,
            padding: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    const Icon(Icons.extension_outlined, size: 18),
                    const SizedBox(width: 8),
                    Text('增强包', style: Theme.of(ctx).textTheme.titleMedium),
                    const Spacer(),
                    Text('按需下载 · 可删除',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              ModelPackSection(
                store: _packs,
                onChanged: () => setState(() {}),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 每个后端在界面上的图标（按 id 给，新增后端时在这里补一个就行）
  IconData _backendIcon(TranscribeBackend b) => switch (b.id) {
        'builtin' => Icons.bolt_outlined,
        'basic_pitch' => Icons.auto_awesome,
        'piano_crnn' => Icons.piano,
        _ => Icons.queue_music,
      };

  /// 跑识别：走**后端注册表**（`lib/transcribe/backends.dart`）。
  ///
  /// 加新模型只需要写一个 TranscribeBackend + 一条 ModelPackSpec，界面这里不用动；
  /// 选中的后端不可用（包没装/加载失败/没检出音符）时统一回落到内置算法，并说明原因。
  Future<MelodyAnalysis> _runEngine(AudioClip clip) async {
    final wanted = backendById(_backendId) ?? backendById('basic_pitch')!;
    final choice = resolveBackend(wanted, _packs);
    if (choice.fallbackNote != null) _engineUsed = choice.fallbackNote!;

    if (choice.backend is BuiltinDspBackend) {
      _engineUsed = _engineUsed.isEmpty ? '内置算法' : _engineUsed;
      return _runBuiltin(clip);
    }

    if (mounted) {
      setState(() {
        _progress = 0.02;
        _stage = '加载 ${choice.backend.label}…';
      });
    }
    try {
      final analysis = await choice.backend.run(clip, options: _options, onProgress: _onProgress);
      if (analysis.notes.isNotEmpty) {
        if (_engineUsed.isEmpty) _engineUsed = choice.backend.label;
        return analysis;
      }
      _engineUsed = '${choice.backend.label}（没检测到音符，已并入内置算法结果）';
    } catch (e) {
      _engineUsed = '${choice.backend.label} 不可用（$e），已用内置算法';
    }
    return _runBuiltin(clip);
  }

  /// 内置纯 Dart 算法（原始实现保持不变）
  Future<MelodyAnalysis> _runBuiltin(AudioClip clip) async {
    // 内置算法在后台 isolate 里跑，没有细粒度进度，用**已用时间**做渐近估算，
    // 并把秒数显示出来（否则进度条会一直停在原地）。
    var elapsed = 0.0;
    final ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      elapsed += 0.1;
      if (!mounted) return;
      setState(() {
        _progress = (0.9 * (1 - math.exp(-elapsed / 4))).clamp(0.02, 0.9);
        _stage = '内置算法分析中… 已用 ${elapsed.toStringAsFixed(1)} 秒';
      });
    });
    try {
      return await compute(_analyzeTask, {
        'samples': clip.samples,
        'rate': clip.sampleRate,
        'options': _options,
      });
    } finally {
      ticker.cancel();
    }
  }

  /// 载入内置示例音频（方便先试效果）
  ///
  /// 示例是「Merry Christmas Mr. Lawrence」的前 90 秒：整首 4 分 49 秒转成 WAV 有
  /// 12.7MB，会让安装包明显变大，所以内置只放一段；想扒整首用「选择音频文件」。
  Future<void> _loadSample() async {
    const asset = 'assets/samples/merry_christmas.wav';
    const label = '示例：Merry Christmas Mr. Lawrence';
    setState(() {
      _busy = true;
      _status = '正在载入示例音频…';
      _analysis = null;
    });
    try {
      final data = await rootBundle.load(asset);
      final clip = prepareWavBytes(data.buffer.asUint8List(), label);
      if (!mounted) return;
      setState(() {
        _clip = clip;
        _clipName = clip.name;
        _clipDuration = clip.durationSec;
        _status = '已载入示例（${clip.durationSec.toStringAsFixed(1)} 秒），正在分析…';
      });
      await _analyze(clip);
    } catch (e) {
      setState(() => _status = '载入示例失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reanalyze() async {    final clip = _clip;
    if (clip == null) return;
    setState(() {
      _busy = true;
      _status = '重新分析中…';
    });
    try {
      await _analyze(clip);
    } catch (e) {
      setState(() => _status = '分析失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /* ---------------- 哼唱记谱 ---------------- */

  Future<void> _toggleRecord() async {
    if (_recording) {
      await _stopRecord();
      return;
    }
    final ok = await _mic.hasPermission();
    if (!ok) {
      setState(() => _status = '没有麦克风权限，请在系统设置里允许录音');
      return;
    }
    try {
      _recorded.clear();
      _tracker = LivePitchTracker(options: _options);
      final stream = await _mic.start(sampleRate: kAnalysisRate);
      _sub = stream.listen((bytes) {
        final tracker = _tracker;
        if (tracker == null) return;
        final produced = tracker.push(bytes);
        if (produced.isEmpty || !mounted) return;
        final last = produced.last;
        setState(() {
          _liveMidi = last.midi;
          _liveLevel = last.level;
          _recordSeconds = tracker.durationSec;
        });
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted && _tracker != null) setState(() => _recordSeconds = _tracker!.durationSec);
      });
      setState(() {
        _recording = true;
        _liveMidi = 0;
        _liveLevel = 0;
        _status = '正在录音：跟着哼唱或唱出旋律，尽量用“啊/啦”保持音高稳定';
      });
    } catch (e) {
      setState(() => _status = '无法开始录音：$e');
    }
  }

  Future<void> _stopRecord() async {
    _ticker?.cancel();
    _ticker = null;
    await _sub?.cancel();
    _sub = null;
    await _mic.stop();
    final tracker = _tracker;
    _tracker = null;
    if (!mounted) return;
    setState(() {
      _recording = false;
      _liveMidi = 0;
      _liveLevel = 0;
    });
    if (tracker == null || tracker.durationSec < 0.4) {
      setState(() => _status = '录音太短了，至少哼唱 1 秒以上');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在分析哼唱（${tracker.durationSec.toStringAsFixed(1)} 秒）…';
      _clipDuration = tracker.durationSec;
      _clipName = '哼唱录音';
    });
    try {
      final pcm = tracker.pcm;
      final clip = AudioClip(pcm, kAnalysisRate, '哼唱录音', tracker.durationSec);
      _clip = clip;
      final analysis = await _runEngine(clip);
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _bpmOverride = analysis.bpm;
        _keyOverride = null;
        _status = '哼唱分析完成（$_engineUsed）：${analysis.activeNotes.length} 个音';
        _progress = 1;
        _stage = '';
      });
    } catch (e) {
      setState(() => _status = '分析失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /* ---------------- 转换 ---------------- */

  void _convert() {
    final analysis = _analysis;
    if (analysis == null) return;
    // 曲谱名字自动跟随输入曲子的名字（把扩展名去掉）
    final title = _pieceName();
    final options = QuantizeOptions(
      bpm: _bpmOverride,
      beats: _beats,
      beatType: _beatType,
      keyName: _keyOverride,
      grid: _grid,
      keepRests: _keepRests,
      title: title,
    );
    final result = _twoStaves
        ? quantizeToGrandStaff(analysis, options: options)
        : quantizeToScore(_melodyOnly ? _withMelodyOnly(analysis) : analysis, options: options);
    if (result.jianpu.trim().isEmpty) {
      setState(() => _status = '没有可转换的音符');
      return;
    }
    // 清掉旧表头，写入新乐谱
    final lines = result.jianpu.split('\n').where((l) => !RegExp(r'^\s*1\s*=').hasMatch(l)).join('\n');
    widget.state.setText(lines, immediate: true);
    setState(() => _status = '已生成乐谱${_twoStaves ? "（大谱表 / 钢琴谱）" : ""}：${describeQuantize(result)}'
        '${result.warnings.isEmpty ? '' : '（${result.warnings.join("；")}）'}');
    widget.onConverted();
  }

  /// 曲谱名字：用输入音频的文件名（去掉扩展名）
  String? _pieceName() {
    final name = _clipName?.trim();
    if (name == null || name.isEmpty) return null;
    var n = name;
    final dot = n.lastIndexOf('.');
    if (dot > 0) n = n.substring(0, dot);
    // 「示例：小星星（带伴奏）」这类前缀去掉，只留曲子名
    n = n.replaceFirst(RegExp(r'^(示例[:：]|哼唱录音)'), '').trim();
    return n.isEmpty ? null : n;
  }

  /// 单谱表模式下的"只保留主旋律"过滤
  MelodyAnalysis _withMelodyOnly(MelodyAnalysis analysis) {
    final melody = pickMelodyNotes(analysis.activeNotes);
    final keep = melody.map((n) => '${n.startSec}:${n.midiRound}').toSet();
    return analysis.withNotes([
      for (final n in analysis.notes)
        n.copyWith(removed: n.removed || !keep.contains('${n.startSec}:${n.midiRound}')),
    ]);
  }

  void _toggleNote(int index) {
    final a = _analysis;
    if (a == null) return;
    final notes = List<DetectedNote>.from(a.notes);
    notes[index] = notes[index].copyWith(removed: !notes[index].removed);
    setState(() => _analysis = a.withNotes(notes));
  }

  /* ---------------- UI ---------------- */

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final analysis = _analysis;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        SectionCard(
          title: '第一步 · 声音来源',
          subtitle: '听歌扒谱选音频文件；哼唱记谱用麦克风。全部在本机处理，音频不会上传',
          icon: Icons.graphic_eq,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.audio_file_outlined), label: Text('音频文件')),
                  ButtonSegment(value: true, icon: Icon(Icons.mic_none), label: Text('哼唱录音')),
                ],
                selected: {_micMode},
                onSelectionChanged: _recording
                    ? null
                    : (s) => setState(() => _micMode = s.first),
              ),
              const SizedBox(height: 14),
              if (!_micMode)
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _pickAndAnalyze,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('选择音频文件'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _loadSample(),
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: const Text('示例：Merry Christmas'),
                    ),
                  ],
                )
              else ...[
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _toggleRecord,
                      icon: Icon(_recording ? Icons.stop_rounded : Icons.mic),
                      label: Text(_recording ? '停止并分析' : '开始哼唱'),
                    ),
                    const SizedBox(width: 14),
                    Text('${_recordSeconds.toStringAsFixed(1)} s'),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (_liveLevel * 4).clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.music_note, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      _liveMidi > 0 ? '当前音高 ${describePitch(_liveMidi)}' : '（等待声音…）',
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
              if (_clipName != null) ...[
                const SizedBox(height: 10),
                Text(
                  '当前音频：$_clipName · ${_clipDuration.toStringAsFixed(1)} 秒',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                // 确定进度：Basic Pitch 按窗口上报真实进度，内置算法按已用时间估算
                WavyProgressBar(value: _progress.clamp(0.02, 1.0), height: 12),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _stage.isEmpty ? '准备中…' : _stage,
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ),
                    Text(
                      '${(_progress * 100).round()}%',
                      style: TextStyle(fontSize: 11.5, color: scheme.primary),
                    ),
                  ],
                ),
              ],
              if (_status != null) ...[
                const SizedBox(height: 10),
                Text(_status!, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        SectionCard(
          title: '第二步 · 分析参数',
          subtitle: analysis == null
              ? '选好音源后先分析，再在下方校正'
              : '模式与灵敏度会影响切分结果；改完点“重新分析”',
          icon: Icons.tune,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _backendId,
                decoration: const InputDecoration(
                  labelText: '识别引擎',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  // 选项来自后端注册表（lib/transcribe/backends.dart）：
                  // 加新模型只需要注册一个 TranscribeBackend，这里自动出现。
                  for (final b in selectableBackends(_packs))
                    DropdownMenuItem(
                      value: b.id,
                      child: Row(
                        children: [
                          Icon(_backendIcon(b), size: 18),
                          const SizedBox(width: 8),
                          Text(b.label),
                          if (!b.ready(_packs)) ...[
                            const SizedBox(width: 6),
                            Text('（未安装）',
                                style: TextStyle(fontSize: 11, color: scheme.outline)),
                          ],
                        ],
                      ),
                    ),
                ],
                onChanged:
                    _busy ? null : (id) => setState(() => _backendId = id ?? _backendId),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      (backendById(_backendId) ?? backendById('basic_pitch')!).blurb,
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 增强包收进抽屉：主页面不再被一堆包撑长（用户要求）
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _openPackDrawer,
                    icon: const Icon(Icons.extension_outlined, size: 16),
                    label: const Text('增强包', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('歌曲主旋律模式'),
                    selected: _options.mixMode,
                    onSelected: (v) => setState(() => _options = _options.copyWith(mixMode: v)),
                  ),
                  FilterChip(
                    avatar: const Icon(Icons.piano_outlined, size: 18),
                    label: const Text('两行谱表（右手+左手）'),
                    selected: _twoStaves,
                    onSelected: _busy ? null : (v) => setState(() => _twoStaves = v),
                  ),
                  FilterChip(
                    avatar: const Icon(Icons.filter_alt_outlined, size: 18),
                    label: Text(_twoStaves ? '只保留主旋律（仅单谱表）' : '只保留主旋律（去伴奏/泛音）'),
                    selected: _melodyOnly && !_twoStaves,
                    onSelected: (_busy || _twoStaves) ? null : (v) => setState(() => _melodyOnly = v),
                  ),
                  FilterChip(
                    label: const Text('保留休止符'),
                    selected: _keepRests,
                    onSelected: (v) => setState(() => _keepRests = v),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('灵敏度 ${(_options.sensitivity * 100).round()}%',
                  style: const TextStyle(fontSize: 12)),
              Slider(
                min: 0,
                max: 1,
                value: _options.sensitivity,
                onChanged: (v) => setState(() => _options = _options.copyWith(sensitivity: v)),
              ),
              Text('最短音符 ${(_options.minNoteSec * 1000).round()} ms',
                  style: const TextStyle(fontSize: 12)),
              Slider(
                min: 0.04,
                max: 0.30,
                value: _options.minNoteSec,
                onChanged: (v) => setState(() => _options = _options.copyWith(minNoteSec: v)),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _BpmField(
                    value: _bpmOverride,
                    onChanged: (v) => setState(() => _bpmOverride = v),
                  ),
                  _dropdown<String?>(
                    label: '调号',
                    value: _keyOverride,
                    items: [null, 'C', 'G', 'D', 'A', 'E', 'F', 'bB', 'bE', 'Am', 'Em', 'Dm', 'Bm'],
                    labelOf: (v) => v ?? '自动',
                    onChanged: (v) => setState(() => _keyOverride = v),
                  ),
                  _dropdown<int>(
                    label: '拍号',
                    value: _beats,
                    items: const [2, 3, 4, 6],
                    labelOf: (v) => '$v/$_beatType',
                    onChanged: (v) => setState(() {
                      _beats = v;
                      _beatType = v == 6 ? 8 : 4;
                    }),
                  ),
                  _dropdown<double>(
                    label: '量化',
                    value: _grid,
                    items: const [0.5, 0.25, 0.125],
                    labelOf: (v) => v == 0.5 ? '八分' : (v == 0.25 ? '十六分' : '三十二分'),
                    onChanged: (v) => setState(() => _grid = v),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: (_busy || _clip == null) ? null : _reanalyze,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新分析'),
                  ),
                  FilledButton.icon(
                    onPressed: (_busy || analysis == null) ? null : _convert,
                    icon: const Icon(Icons.music_note),
                    label: const Text('生成乐谱'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (analysis != null)
          SectionCard(
            title: '第三步 · 校对（钢琴卷帘）',
            subtitle: '横轴时间、纵轴音高；蓝条是识别出的音符，点一下可删除（变红）或恢复',
            icon: Icons.piano_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.timelapse, size: 16),
                      label: Text('${analysis.durationSec.toStringAsFixed(1)} 秒'),
                      visualDensity: VisualDensity.compact,
                    ),
                    Chip(
                      avatar: const Icon(Icons.music_note, size: 16),
                      label: Text('${analysis.activeNotes.length} / ${analysis.notes.length} 个音'),
                      visualDensity: VisualDensity.compact,
                    ),
                    if (analysis.bpm > 0)
                      Chip(
                        avatar: const Icon(Icons.speed, size: 16),
                        label: Text('${analysis.bpm.round()} BPM'),
                        visualDensity: VisualDensity.compact,
                      ),
                    Chip(
                      avatar: const Icon(Icons.piano, size: 16),
                      label: Text('调号 ${analysis.keyName}'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                PianoRollView(
                  analysis: analysis,
                  onToggleNote: _toggleNote,
                  height: 280,
                ),
                const SizedBox(height: 4),
                Text(
                  analysis.mixMode
                      ? '当前是「歌曲主旋律模式」：从混音里提取最可能的旋律线，和弦/多声部不会拆开。'
                      : '当前是「独奏/哼唱模式」：适合单声部旋律，准确率最高。',
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) labelOf,
    required ValueChanged<T> onChanged,
  }) {
    return SizedBox(
      width: 132,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isDense: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: items
            .map((v) => DropdownMenuItem<T>(value: v, child: Text(labelOf(v), style: const TextStyle(fontSize: 13))))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

class _BpmField extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const _BpmField({required this.value, required this.onChanged});

  @override
  State<_BpmField> createState() => _BpmFieldState();
}

class _BpmFieldState extends State<_BpmField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value > 0 ? widget.value.round().toString() : '');

  @override
  void didUpdateWidget(_BpmField old) {
    super.didUpdateWidget(old);
    final text = widget.value > 0 ? widget.value.round().toString() : '';
    if (text != _c.text && !_c.selection.isValid) _c.text = text;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: TextField(
        controller: _c,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: '速度 BPM', isDense: true),
        style: const TextStyle(fontSize: 13),
        onChanged: (v) {
          final d = double.tryParse(v);
          if (d != null && d >= 30 && d <= 300) widget.onChanged(d);
        },
      ),
    );
  }
}
