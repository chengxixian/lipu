/// 端到端：**App 自己的 Dart 引擎**（PianoCrnnEngine + 解码器）跑真实 ONNX，
/// 与 Node 探针（`tools/piano_crnn_probe/`）的结果对得上吗？
///
///   flutter test integration_test/crnn_pack_e2e_test.dart -d windows
///
/// 需要先把可选包放在磁盘上（默认读 third_party/piano_crnn/piano_crnn.onnx，
/// 可用环境变量 PIANO_CRNN_PATH 覆盖）。
/// 测试音频用 app/tool/make_chord_fixtures.dart 生成（已有真值）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/transcribe/audio_source.dart';
import 'package:jianpu_app/transcribe/crnn_engine.dart';
import 'package:jianpu_app/transcribe/model_packs.dart';

const String _defaultModel = 'D:/dsh work region/jianpu2staff/third_party/piano_crnn/piano_crnn.onnx';

String _modelPath() => Platform.environment['PIANO_CRNN_PATH'] ?? _defaultModel;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CRNN 可选包：App 引擎跑真实模型，准确率与探针一致', (tester) async {
    final model = File(_modelPath());
    if (!model.existsSync()) {
      markTestSkipped('没找到 CRNN 模型 ${model.path}（先下载可选包）');
      return;
    }
    final fixtureDir = Directory('build/fixtures');
    if (!fixtureDir.existsSync()) {
      markTestSkipped('缺少测试音频，先跑 flutter test test/_make_fixtures_test.dart');
      return;
    }
    final truth = jsonDecode(File('${fixtureDir.path}/truth.json').readAsStringSync()) as Map<String, dynamic>;
    final cases = truth['cases'] as Map<String, dynamic>;

    final engine = PianoCrnnEngine();
    expect(await engine.ensureLoaded(model.path), isTrue, reason: '加载失败：${engine.error}');
    addTearDown(engine.dispose);

    var tpAll = 0, detAll = 0, truthAll = 0;
    final sw = Stopwatch()..start();
    var audioSec = 0.0;

    for (final entry in cases.entries) {
      final name = entry.key;
      final chords = (entry.value as List<dynamic>).map((e) => e as Map<String, dynamic>).toList();
      final clip = await loadAudioFile('${fixtureDir.path}/chords_$name.wav',
          targetSampleRate: CrnnConst.sampleRate);
      audioSec += clip.durationSec;
      final notes = await engine.transcribe(clip.samples);
      var tp = 0, det = 0, tot = 0;
      final lines = <String>[];
      for (final ch in chords) {
        final start = (ch['start'] as num).toDouble();
        final dur = (ch['dur'] as num).toDouble();
        final want = (ch['midis'] as List<dynamic>).map((e) => (e as num).toInt()).toSet();
        final found = notes
            .where((n) => n.startSec >= start - 0.25 && n.startSec <= start + dur * 0.6)
            .map((n) => n.midi.round())
            .toSet();
        final hit = found.intersection(want);
        tp += hit.length;
        det += found.length;
        tot += want.length;
        lines.add('   ${start.toStringAsFixed(1)}s [${want.map(_n).join(" ")}] 检出 ${found.length}：'
            '${found.map(_n).join(" ")}'
            '${want.difference(found).isEmpty ? "" : "  漏:${want.difference(found).map(_n).join(",")}"}'
            '${found.difference(want).isEmpty ? "" : "  多:${found.difference(want).map(_n).join(",")}"}');
      }
      tpAll += tp;
      detAll += det;
      truthAll += tot;
      // ignore: avoid_print
      print('== $name：recall=${(tp / tot * 100).round()}% precision=${(det == 0 ? 0 : (tp / det * 100)).round()}%');
      for (final l in lines) {
        // ignore: avoid_print
        print(l);
      }
    }
    sw.stop();
    final recall = (tpAll / truthAll * 100).round();
    final precision = (tpAll / detAll * 100).round();
    // ignore: avoid_print
    print('合计：recall=$recall%  precision=$precision%（真值 $truthAll，检出 $detAll，命中 $tpAll）');
    // ignore: avoid_print
    print('速度：${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s 处理 ${audioSec.toStringAsFixed(1)}s 音频'
        '（实时率 ${(sw.elapsedMilliseconds / 1000 / audioSec).toStringAsFixed(2)}×）');

    // 与 Node 探针一致的口径：recall 100%、precision 86%
    expect(recall, 100, reason: '和弦音一个都不能漏');
    expect(precision, greaterThanOrEqualTo(80), reason: 'precision 不能明显低于探针的 86%');
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('可选包元信息与实际文件一致（体积/校验）', (tester) async {
    final model = File(_modelPath());
    if (!model.existsSync()) {
      markTestSkipped('没找到 CRNN 模型');
      return;
    }
    expect(model.lengthSync(), kPianoCrnnPack.bytes, reason: '包规格里记的字节数必须与实际文件一致');
    final store = ModelPackStore(root: model.parent);
    expect(await store.stateOf(kPianoCrnnPack), PackState.ready);
    final sha = await ModelPackStore.sha256OfFile(model);
    expect(sha, kPianoCrnnPack.sha256, reason: 'SHA256 必须一致，否则用户下载后会被判为损坏');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('排障：B4 到底有没有被模型检出（看原始张量）', (tester) async {
    final model = File(_modelPath());
    if (!model.existsSync()) {
      markTestSkipped('没找到 CRNN 模型');
      return;
    }
    final engine = PianoCrnnEngine();
    expect(await engine.ensureLoaded(model.path), isTrue, reason: '${engine.error}');
    addTearDown(engine.dispose);

    final clip = await loadAudioFile('build/fixtures/chords_seventh.wav', targetSampleRate: CrnnConst.sampleRate);
    Float32List? onsetRaw, frameRaw, offsetRaw;
    final notes = await engine.transcribe(
      clip.samples,
      onRawSegment: (seg, onset, offset, frame, velocity) {
        onsetRaw = onset;
        frameRaw = frame;
        offsetRaw = offset;
      },
    );
    const keys = CrnnConst.keyCount;
    for (final midi in [59, 60, 64, 67, 71]) {
      final k = CrnnConst.keyOf(midi);
      // 最后一组和弦在 3.0s 附近 → 帧 290~340
      var maxOnset = 0.0, maxFrame = 0.0;
      final onsetFrames = <int>[];
      for (var t = 290; t < 340; t++) {
        final o = onsetRaw![t * keys + k];
        if (o > maxOnset) maxOnset = o;
        if (o > 0.5) onsetFrames.add(t);
        final f = frameRaw![t * keys + k];
        if (f > maxFrame) maxFrame = f;
      }
      // ignore: avoid_print
      print('  ${_n(midi)}(key $k)：onset最大=$maxOnset 帧=$onsetFrames  frame最大=$maxFrame');
    }
    final inWindow = notes.where((n) => n.startSec >= 2.75 && n.startSec <= 3.6).map((n) => _n(n.midi.round()));
    // ignore: avoid_print
    print('  解码结果（2.75~3.6s）：${inWindow.join(" ")}');

    // 用同一份张量单独调解码器（frames/keys 写死 1001/88），看它能不能解出 B4
    final direct = decodeCrnnNotes(
      onset: onsetRaw!,
      offset: offsetRaw!,
      frame: frameRaw!,
      velocity: Float32List(0),
      frames: 1001,
      keys: 88,
      segStartSec: 0,
    );
    final b4 = direct.where((n) => n.midi.round() == 71).toList();
    // ignore: avoid_print
    print('  解码器直接解：共 ${direct.length} 个音，B4 ${b4.length} 个 → '
        '${b4.map((n) => "${n.startSec.toStringAsFixed(3)}~${n.endSec.toStringAsFixed(3)}").join(", ")}');
    // ignore: avoid_print
    print('  引擎返回：共 ${notes.length} 个音，B4 ${notes.where((n) => n.midi.round() == 71).length} 个；'
        '张量长度 onset=${onsetRaw!.length}（1001*88=${1001 * 88}）');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

String _n(int midi) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return '${names[midi % 12]}${midi ~/ 12 - 1}';
}
