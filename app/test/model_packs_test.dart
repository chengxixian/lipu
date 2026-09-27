/// 可选模型包（下载 / 校验 / 续传 / 导入 / 删除）测试
///
/// 用本地 HttpServer 当"模型服务器"，验证：
///   · 正常下载后字节数与 SHA256 都对，文件落在包目录里；
///   · **校验失败必须删掉文件并报错**（半截模型比没有更糟）；
///   · 断点续传（Range）能接上已下载的部分；
///   · 本地导入（发行包附带的量化版走这条）；
///   · 删除后回到"未安装"。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianpu_app/transcribe/backends.dart';
import 'package:jianpu_app/transcribe/model_packs.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late List<int> payload;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('pack_test');
    payload = List<int>.generate(200000, (i) => (i * 7) % 256);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 起一个只会服务一次请求的模型服务器（支持 Range）
  void serve({bool ignoreRange = false, int statusOverride = 0, List<String?>? rangeLog}) {
    server.listen((req) {
      final range = ignoreRange ? null : req.headers.value(HttpHeaders.rangeHeader);
      rangeLog?.add(range);
      if (statusOverride != 0) {
        req.response.statusCode = statusOverride;
        req.response.close();
        return;
      }
      var start = 0;
      if (range != null && range.startsWith('bytes=')) {
        start = int.parse(range.substring(6).split('-').first);
        if (start >= payload.length) {
          // 真实服务器就是这样回 416 的
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${payload.length - 1}/${payload.length}');
      }
      final body = payload.sublist(start);
      req.response.headers.contentLength = body.length;
      req.response.add(body);
      req.response.close();
    });
  }

  ModelPackSpec specFor(Uri uri, {int? bytes, String? sha}) => ModelPackSpec(
        id: 'test',
        title: '测试包',
        subtitle: 'sub',
        fileName: 'test.onnx',
        sources: [PackSource('测试源', uri.toString())],
        bytes: bytes ?? payload.length,
        sha256: sha ?? sha256.convert(payload).toString(),
        license: 'MIT',
        attribution: 'test',
      );

  test('多源回退：第一个源连不上时自动换下一个（手机连不上 HF 的场景）', () async {
    serve();
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    // 第一个源指向一个没人监听的端口
    final spec = ModelPackSpec(
      id: 'test',
      title: '测试包',
      subtitle: 'sub',
      fileName: 'test.onnx',
      sources: [
        PackSource('镜像（坏）', 'http://127.0.0.1:1/never.onnx'),
        PackSource('官方（好）', 'http://127.0.0.1:${server.port}/m.onnx'),
      ],
      bytes: payload.length,
      sha256: sha256.convert(payload).toString(),
      license: 'MIT',
      attribution: 'test',
    );
    final stages = <String>[];
    final file = await store.download(spec, onStage: stages.add);
    expect(file.lengthSync(), payload.length);
    expect(file.readAsBytesSync(), payload);
    expect(await store.stateOf(spec), PackState.ready);
    expect(stages.any((s) => s.contains('换下一个下载源')), isTrue, reason: '应当报告切换下载源');
  });

  test('换源续传：第一个源下一半断了，第二个源接着下', () async {
    serve();
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    await store.ensureDir();
    final spec = ModelPackSpec(
      id: 'test',
      title: '测试包',
      subtitle: 'sub',
      fileName: 'test.onnx',
      sources: [
        PackSource('镜像（坏）', 'http://127.0.0.1:1/never.onnx'),
        PackSource('官方（好）', 'http://127.0.0.1:${server.port}/m.onnx'),
      ],
      bytes: payload.length,
      sha256: sha256.convert(payload).toString(),
      license: 'MIT',
      attribution: 'test',
    );
    // 先造一个"从坏源下了一半"的临时文件
    store.partOf(spec).writeAsBytesSync(payload.sublist(0, payload.length ~/ 2));
    final ranges = <String?>[];
    // 重新起一个记录 Range 的服务器
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serve(rangeLog: ranges);
    final spec2 = ModelPackSpec(
      id: spec.id,
      title: spec.title,
      subtitle: spec.subtitle,
      fileName: spec.fileName,
      sources: [
        PackSource('镜像（坏）', 'http://127.0.0.1:1/never.onnx'),
        PackSource('官方（好）', 'http://127.0.0.1:${server.port}/m.onnx'),
      ],
      bytes: spec.bytes,
      sha256: spec.sha256,
      license: spec.license,
      attribution: spec.attribution,
    );
    final file = await store.download(spec2);
    expect(file.readAsBytesSync(), payload, reason: '换源后内容必须完整');
    expect(ranges.any((r) => r != null && r.startsWith('bytes=')), isTrue,
        reason: '第二个源应当带 Range 续传，而不是从头再来');
  });

  test('所有源都失败：报错并且保留 .part 供下次续传', () async {
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    await store.ensureDir();
    final spec = ModelPackSpec(
      id: 'test',
      title: '测试包',
      subtitle: 'sub',
      fileName: 'test.onnx',
      sources: const [
        PackSource('坏源1', 'http://127.0.0.1:1/a.onnx'),
        PackSource('坏源2', 'http://127.0.0.1:2/b.onnx'),
      ],
      bytes: payload.length,
      sha256: sha256.convert(payload).toString(),
      license: 'MIT',
      attribution: 'test',
    );
    store.partOf(spec).writeAsBytesSync(payload.sublist(0, 1000));
    await expectLater(store.download(spec), throwsA(isA<StateError>()));
    expect(store.partOf(spec).existsSync(), isTrue, reason: '已下的部分要留着');
    expect(store.partOf(spec).lengthSync(), 1000);
  });

  test('正常下载：字节数与 SHA256 都对得上，文件落到包目录', () async {
    serve();
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    final spec = specFor(Uri.parse('http://127.0.0.1:${server.port}/m.onnx'));
    final seen = <double>[];
    final file = await store.download(spec, onProgress: (p) => seen.add(p.fraction));
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), payload.length);
    expect(await store.stateOf(spec), PackState.ready);
    expect(store.installedFile(spec), isNotNull);
    expect(seen, isNotEmpty);
    expect(seen.last, closeTo(1.0, 0.001));
    expect(store.partOf(spec).existsSync(), isFalse, reason: '临时文件应当已改名');
  });

  test('内容不对：必须删掉文件并抛错（半截模型比没有更糟）', () async {
    serve();
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    // 故意给一个错的 SHA256
    final spec = specFor(Uri.parse('http://127.0.0.1:${server.port}/m.onnx'),
        sha: 'deadbeef' * 8);
    await expectLater(store.download(spec), throwsA(isA<StateError>()));
    expect(store.fileOf(spec).existsSync(), isFalse, reason: '校验失败的文件必须删掉');
    expect(store.installedFile(spec), isNull);
  });

  test('字节数不对：同样拒绝', () async {
    serve();
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    final spec = specFor(Uri.parse('http://127.0.0.1:${server.port}/m.onnx'),
        bytes: payload.length + 1);
    await expectLater(store.download(spec), throwsA(isA<StateError>()));
    expect(store.fileOf(spec).existsSync(), isFalse);
  });

  test('断点续传：已下了一半时带 Range 只取剩下的', () async {
    final ranges = <String?>[];
    serve(rangeLog: ranges);
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    await store.ensureDir();
    final spec = specFor(Uri.parse('http://127.0.0.1:${server.port}/m.onnx'));
    // 手动造一个"下了一半"的临时文件
    final half = payload.sublist(0, payload.length ~/ 2);
    store.partOf(spec).writeAsBytesSync(half);

    final file = await store.download(spec);
    expect(ranges.any((r) => r != null && r.startsWith('bytes=')), isTrue, reason: '应当带 Range 续传');
    expect(file.lengthSync(), payload.length);
    expect(file.readAsBytesSync(), payload, reason: '续传后的内容必须完整且顺序正确');
    expect(await store.stateOf(spec), PackState.ready);
  });

  test('服务器不支持 Range 时也能下完（不至于永远卡在半截）', () async {
    serve(ignoreRange: true);
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    await store.ensureDir();
    final spec = specFor(Uri.parse('http://127.0.0.1:${server.port}/m.onnx'));
    store.partOf(spec).writeAsBytesSync(payload.sublist(0, payload.length ~/ 2));
    final file = await store.download(spec);
    expect(file.lengthSync(), payload.length);
  });

  test('本地导入：发行包里附带的量化版走这条', () async {
    final src = File('${tmp.path}/downloaded_by_user.onnx')..writeAsBytesSync(payload);
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    final spec = specFor(Uri.parse('http://127.0.0.1:1/never'));
    final file = await store.import(spec, src);
    expect(file.path, endsWith('test.onnx'));
    expect(file.readAsBytesSync(), payload);
    expect(await store.stateOf(spec), PackState.ready);
  });

  test('导入坏文件同样拒绝', () async {
    final src = File('${tmp.path}/bad.onnx')..writeAsBytesSync(List<int>.filled(10, 1));
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    final spec = specFor(Uri.parse('http://127.0.0.1:1/never'));
    await expectLater(store.import(spec, src), throwsA(isA<StateError>()));
    expect(store.installedFile(spec), isNull);
  });

  test('删除后回到未安装，临时文件也清掉', () async {
    serve();
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    final spec = specFor(Uri.parse('http://127.0.0.1:${server.port}/m.onnx'));
    await store.download(spec);
    expect(await store.stateOf(spec), PackState.ready);
    await store.delete(spec);
    expect(await store.stateOf(spec), PackState.missing);
    expect(store.partOf(spec).existsSync(), isFalse);
  });

  test('文件大小与规格对不上时视为装坏（invalid），不会拿去推理', () async {
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    await store.ensureDir();
    final spec = specFor(Uri.parse('http://127.0.0.1:1/never'));
    store.fileOf(spec).writeAsBytesSync(List<int>.filled(123, 0));
    expect(await store.stateOf(spec), PackState.invalid);
    expect(store.installedFile(spec), isNull);
  });

  test('三个真实包的元信息齐全（体积/许可证/出处都写清楚了）', () {
    for (final spec in kModelPacks) {
      expect(spec.title, isNotEmpty);
      expect(spec.subtitle, isNotEmpty);
      expect(spec.license, isNotEmpty);
      expect(spec.attribution, isNotEmpty);
      expect(spec.fileName, contains('.'));
    }
    expect(kPianoCrnnPack.bytes, 154206740);
    expect(kPianoCrnnPack.sha256.length, 64);
    expect(kPianoCrnnPack.sources.first.url, contains('hf-mirror.com'));
    expect(packDetailLines(kPianoCrnnPack, PackState.missing), contains('未安装'));
    expect(packDetailLines(kPianoCrnnPack, PackState.ready), contains('已安装'));
    expect(ModelPackStore.describe(kPianoCrnnPack), contains('147MB'));

    // 非商用 + 门控的包必须把这两点标出来（免得用户以为可以随便用/直接下）
    expect(kMuScriptorPack.nonCommercial, isTrue);
    expect(kMuScriptorPack.needsToken, isTrue);
    expect(kMuScriptorPack.licensePage, isNotNull);
    expect(kMuScriptorPack.license, contains('非商用'));
    // 手机端排除 1.1GB 的 medium，只提供 small
    expect(kMuScriptorPack.sources.single.url, contains('small'));
  });

  test('导入时必须带上附属文件（.onnx.data），否则 ORT 加载会失败', () async {
    // 用户踩过：tsumugi_amt.onnx 与 .onnx.data 在同一目录，导入照样失败 ——
    // 因为旧实现只拷了被选中的那一个文件 ✗
    final srcDir = Directory('${tmp.path}/user_download')..createSync(recursive: true);
    final onnx = File('${srcDir.path}/tsumugi_amt.onnx')..writeAsBytesSync(payload);
    File('${srcDir.path}/tsumugi_amt.onnx.data').writeAsBytesSync(List<int>.filled(4096, 7));
    File('${srcDir.path}/无关文件.txt').writeAsBytesSync(List<int>.filled(10, 1));

    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    final spec = specFor(Uri.parse('http://127.0.0.1:1/never'));
    await store.import(spec, onnx); // 只选主文件，附属文件应被自动发现
    final installed = store.installedFiles(spec);
    expect(installed, contains('test.onnx'));
    expect(installed.any((n) => n.endsWith('.data')), isTrue,
        reason: '同目录的 .data 必须一起拷进来');
    expect(installed.any((n) => n.contains('无关')), isFalse, reason: '不该乱拷别的文件');
  });

  test('多选导入：用户一次选中两个文件也支持', () async {
    final srcDir = Directory('${tmp.path}/user_download2')..createSync(recursive: true);
    final onnx = File('${srcDir.path}/m.onnx')..writeAsBytesSync(payload);
    final data = File('${srcDir.path}/m.onnx.data')..writeAsBytesSync(List<int>.filled(2048, 3));
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    final spec = specFor(Uri.parse('http://127.0.0.1:1/never'));
    await store.import(spec, onnx, extra: [data]);
    final installed = store.installedFiles(spec);
    expect(installed, contains('test.onnx'));
    expect(installed, contains('m.onnx.data'));
  });

  test('Tsumugi 包有网盘入口（用户提供的夸克分享），文案提醒两个文件一起导入', () {
    // 网上没有现成下载，所以必须给网盘入口；而网盘是"人工取回"，不能程序化下载
    expect(kTsumugiPack.hasNetdisk, isTrue);
    expect(kTsumugiPack.netdiskUrl, contains('pan.quark.cn'));
    expect(kTsumugiPack.netdiskLabel, contains('.data'), reason: '要提醒把 .onnx.data 一起导入');
    expect(kTsumugiPack.downloadable, isFalse);
  });

  test('界面与后端必须用**同一个**包目录（否则"显示已安装、识别说没装"）', () {
    // 用户实测踩到的 bug：增强包区块显示"已安装 实际=期望"，识别却报"增强包未安装"。
    // 根因是后端读取方式与界面不一致（后端读的是 engine 内部状态，从没被设置过）。
    // 这里把"同一入口"钉住：两边都必须是 forApp()。
    final a = ModelPackStore.forApp();
    final b = ModelPackStore.forApp();
    expect(a.root.path, b.root.path);
    expect(a.root.path, contains('packs'));
    expect(a.root.path, contains('离谱'));
  });

  test('后端 ready() 与实际文件一致：装好就 ready，删掉就不 ready', () async {
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    final crnn = kTranscribeBackends.firstWhere((b) => b.id == kPianoCrnnPack.id);
    expect(crnn.ready(store), isFalse);
    await store.ensureDir();
    store.fileOf(kPianoCrnnPack).writeAsBytesSync(List<int>.filled(kPianoCrnnPack.bytes, 0));
    expect(crnn.ready(store), isTrue, reason: '文件齐了就该 ready');
    await store.delete(kPianoCrnnPack);
    expect(crnn.ready(store), isFalse);
  });

  test('大小不符要说清"实际 vs 期望"，并允许用户忽略检查继续用', () async {
    // 用户报："装上了却显示未安装" —— 根因是严格大小校验，而界面不解释 ✗
    final store = ModelPackStore(root: Directory('${tmp.path}/packs'));
    await store.ensureDir();
    final spec = specFor(Uri.parse('http://127.0.0.1:1/never')); // 期望 payload.length
    store.fileOf(spec).writeAsBytesSync(List<int>.filled(payload.length + 1024, 1));

    final d1 = store.detailOf(spec);
    expect(d1.state, PackState.invalid);
    expect(d1.actual, payload.length + 1024);
    expect(d1.expected, payload.length);
    expect(store.installedFile(spec), isNull, reason: '默认仍按严格校验拦着');

    // 用户点"忽略大小检查，仍要使用"
    await store.accept(spec);
    expect(store.isAccepted(spec), isTrue);
    expect(store.detailOf(spec).state, PackState.ready);
    expect(store.installedFile(spec), isNotNull, reason: '接受后应当能拿去用（模型坏了由 ORT 报错）');
  });
}
