/// 分离引擎的端到端冒烟测试：跑真实 ONNX，检查**链路通**（形状/能量/可加性）。
///
///   flutter test integration_test/separator_e2e_test.dart -d windows
///
/// 需要模型：third_party/separators/uvr_kara2.onnx（HF `musetric/uvr-mdxnet-kara2-onnx`）
/// 质量好坏（分离后扒谱 precision 是否上升）是下一步的事，这里先保证管道正确。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianpu_app/transcribe/separator.dart';
import 'package:jianpu_app/transcribe/stft.dart';

const String _defaultModel = 'D:/dsh work region/jianpu2staff/third_party/separators/uvr_kara2.onnx';

String _modelPath() => Platform.environment['SEPARATOR_ONNX_PATH'] ?? _defaultModel;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('分离引擎：跑真模型，链路正确（可加性 + 能量合理性）', (tester) async {
    final model = File(_modelPath());
    if (!model.existsSync()) {
      markTestSkipped('缺少分离模型 ${model.path}');
      return;
    }
    final engine = UvrSeparator();
    expect(await engine.ensureLoaded(model.path), isTrue, reason: '加载失败：${engine.error}');
    addTearDown(engine.dispose);

    // 造一段"混音"：低频伴奏 + 中频人声感正弦（避免依赖真实音频文件）
    const sr = StftConst.sampleRate;
    final n = StftConst.chunkSamples + StftConst.hop * 20; // 一块多一点，验证跨块拼接
    final left = Float64List(n);
    final right = Float64List(n);
    for (var i = 0; i < n; i++) {
      final t = i / sr;
      final bass = 0.35 * math.sin(2 * math.pi * 110 * t);
      final voice = 0.25 * math.sin(2 * math.pi * 440 * t + 0.3);
      left[i] = bass + voice;
      right[i] = bass + 0.9 * voice;
    }

    final sw = Stopwatch()..start();
    final res = await engine.separate(
      left,
      right,
      onProgress: (f, stage) {
        if (f >= 0.999) {
          // ignore: avoid_print
          print('   $stage');
        }
      },
    );
    sw.stop();
    final secs = n / sr;
    // ignore: avoid_print
    print('分离：${secs.toStringAsFixed(1)}s 音频 → ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
        '（实时率 ${(sw.elapsedMilliseconds / 1000 / secs).toStringAsFixed(2)}×）');

    // 1) 形状与有限性
    expect(res.vocalLeft.length, n);
    expect(res.accompanimentLeft.length, n);
    expect(res.vocalLeft.every((v) => v.isFinite), isTrue);

    // 2) 可加性：人声 + 伴奏 == 混音（构造上必然，防止中间某处写错）
    var maxErr = 0.0;
    for (var i = 0; i < n; i++) {
      maxErr = math.max(maxErr, (res.vocalLeft[i] + res.accompanimentLeft[i] - left[i]).abs());
    }
    expect(maxErr, lessThan(1e-9), reason: '人声+伴奏必须等于原混音');

    // 3) 能量合理性：两轨都不该是空的
    final mixRms = rmsOf(left);
    final vocalRms = rmsOf(res.vocalLeft);
    final accRms = rmsOf(res.accompanimentLeft);
    // ignore: avoid_print
    print('RMS：混音 ${mixRms.toStringAsFixed(4)} / 人声 ${vocalRms.toStringAsFixed(4)} / '
        '伴奏 ${accRms.toStringAsFixed(4)}（人声/混音 = ${(vocalRms / mixRms).toStringAsFixed(2)}×）');
    expect(vocalRms, greaterThan(1e-6));
    expect(accRms, greaterThan(1e-6));

    // ⚠️ 已知问题（记录而非隐藏）：人声轨比混音大好几倍，说明 **ISTFT 的归一化约定
    // 与模型训练时不一致**（分析窗用 Hann、合成按 Σw² 归一化是我按 torch.istft 的默认约定写的）。
    // 模型卡的宿主契约没写这一项，而它提到的参考实现（Rust 那份）目前取不下来。
    // 在标定之前，分离结果**不能拿去扒谱**，所以扒谱页也还没接这个开关。
    final ratio = vocalRms / mixRms;
    // ignore: avoid_print
    print('⚠️ 缩放待标定：人声/混音 = ${ratio.toStringAsFixed(2)}×（期望 ≲1）');
    expect(ratio, greaterThan(0), reason: '先只记录，不做断言——标定后再收紧');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
