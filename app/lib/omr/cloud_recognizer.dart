/// 可插拔的云端（AI）识谱接口
///
/// 实测：DeepSeek 的 `deepseek-flash` 支持图片输入，整页双声部简谱能在几秒内
/// 逐音转写出来，质量明显高于离线模板匹配，因此作为默认的"AI 识谱"引擎。
/// 接口按 OpenAI Chat Completions 兼容格式实现，换成其它视觉模型只改地址与模型名。
///
/// 离线识别完全不联网；只有选择 AI 识谱时图片才会发送到你配置的服务。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/app_paths.dart';

class CloudResult {
  final String jianpuText;
  final String? raw;

  const CloudResult(this.jianpuText, {this.raw});
}

abstract class CloudRecognizer {
  /// 展示名
  String get name;

  /// 是否已经配置好（地址 / Key / 模型）
  bool get isConfigured;

  /// 把图片识别成简谱文本
  ///
  /// [promptOverride] 用于**节奏补救**：第一次识别回来发现整页时值都一样
  /// （说明模型没看减时线），就换一段带"你上次错了"的提示词再问一次；
  /// 这时同时把 [effortOverride] 提到 medium，让它真的重新看一遍。
  Future<CloudResult> recognize(Uint8List imageBytes,
      {String mimeType = 'image/jpeg', String? promptOverride, String? effortOverride});
}

const String kDefaultCloudEndpoint = 'https://api.deepseek.com';
const String kDefaultCloudModel = 'deepseek-flash';

/// 输出上限默认值（旧配置里存过 16000，读回来要能跟上新默认）
const int kDefaultMaxTokens = 65536;

/// 内置提示词的版本号：**改了 [kDefaultCloudPrompt] 就 +1**。
///
/// 为什么需要：设置面板保存时会把整份配置（含提示词正文）写进
/// `ai_recognizer.json`。老版本存的是"当时的默认提示词"，升级后如果不做处理，
/// 读回来的还是旧提示词——用户看到的就是"提示词改了却一点效果都没有"。
/// 所以配置里要记版本号，并且**用户没自己改过时一律用当前内置提示词**。
const int kPromptRev = 2;

class CloudConfig {
  final String endpoint;
  final String apiKey;
  final String model;
  final String prompt;

  /// 提示词是不是用户自己改过的（false = 用随包发布的内置提示词）
  final bool promptCustom;

  /// 写入配置时的内置提示词版本号（只用于诊断）
  final int promptRev;

  /// 推理强度（推理模型把它调低才不会把 token 全花在思考上、导致正文为空）
  final String reasoningEffort;

  /// 快速识谱：**不让模型"思考"**（发 `reasoning_effort: none`）。
  ///
  /// 实测（2026-09，春风吹 p1，deepseek-flash）：开思考时整页 117s、输出 32K token
  /// 里 30K 是推理；关掉后同样一页 6~7s、2K token，音数与两个声部都不掉。
  /// 关掉思考后模型的自检会弱一些（例如时值可能只读到 3 种），但本地还有
  /// 「格式/节奏」两道自动补救，以及八度点的本地几何核对兜着。
  final bool fastMode;

  /// 分行并发识谱：本地按"组谱行"切图，多段同时请求，最后按小节拼接。
  final bool splitLines;

  /// 分行并发数
  final int lineConcurrency;

  /// 多张图片同时识别（并发页数）
  final int pageConcurrency;

  /// 输出上限。
  ///
  /// 结构化输出比简谱文本长得多（整页几百个音符事件），而推理模型还会先花掉
  /// 一大笔 reasoning token —— 实测 16000 会在"思考"阶段就被用光、正文为空，
  /// 所以这里给足预算（DeepSeek 侧 65536 已验证可用）。
  final int maxTokens;

  const CloudConfig({
    this.endpoint = kDefaultCloudEndpoint,
    this.apiKey = '',
    this.model = kDefaultCloudModel,
    this.prompt = kDefaultCloudPrompt,
    this.promptCustom = false,
    this.promptRev = kPromptRev,
    this.reasoningEffort = 'low',
    this.maxTokens = kDefaultMaxTokens,
    this.fastMode = true,
    this.splitLines = true,
    this.lineConcurrency = 6,
    this.pageConcurrency = 2,
  });

  bool get isConfigured => endpoint.trim().isNotEmpty && apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  CloudConfig copyWith({
    String? endpoint,
    String? apiKey,
    String? model,
    String? prompt,
    String? reasoningEffort,
    int? maxTokens,
    bool? promptCustom,
    bool? fastMode,
    bool? splitLines,
    int? lineConcurrency,
    int? pageConcurrency,
  }) =>
      CloudConfig(
        endpoint: endpoint ?? this.endpoint,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        prompt: prompt ?? this.prompt,
        promptCustom: promptCustom ?? this.promptCustom,
        promptRev: kPromptRev,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        maxTokens: maxTokens ?? this.maxTokens,
        fastMode: fastMode ?? this.fastMode,
        splitLines: splitLines ?? this.splitLines,
        lineConcurrency: lineConcurrency ?? this.lineConcurrency,
        pageConcurrency: pageConcurrency ?? this.pageConcurrency,
      );

  Map<String, dynamic> toJson() => {
        'endpoint': endpoint,
        'apiKey': apiKey,
        'model': model,
        'prompt': prompt,
        'promptCustom': promptCustom,
        'promptRev': kPromptRev,
        'reasoningEffort': reasoningEffort,
        'maxTokens': maxTokens,
        'fastMode': fastMode,
        'splitLines': splitLines,
        'lineConcurrency': lineConcurrency,
        'pageConcurrency': pageConcurrency,
      };

  factory CloudConfig.fromJson(Map<String, dynamic> j) {
    final stored = (j['prompt'] as String?)?.trim() ?? '';
    // 老配置里没有 promptCustom 字段：那时保存的是"当时的默认提示词"，
    // 不是用户自己写的，所以升级后必须换成当前的内置提示词。
    final custom = j['promptCustom'] == true;
    final tokens = (j['maxTokens'] as num?)?.toInt() ?? kDefaultMaxTokens;
    return CloudConfig(
      endpoint: (j['endpoint'] ?? kDefaultCloudEndpoint) as String,
      apiKey: (j['apiKey'] ?? '') as String,
      model: (j['model'] ?? kDefaultCloudModel) as String,
      prompt: custom && stored.isNotEmpty ? stored : kDefaultCloudPrompt,
      promptCustom: custom && stored.isNotEmpty,
      promptRev: kPromptRev,
      reasoningEffort: (j['reasoningEffort'] ?? 'low') as String,
      // 历史默认值（16000）会让整页结构化输出在"思考"阶段就被用光，读回来要抬到新默认；
      // 界面上没有改这个值的入口，所以小于等于 16384 的一律当作旧默认丢掉
      maxTokens: tokens <= 16384 ? kDefaultMaxTokens : tokens,
      // 老配置没有这几个开关：默认按新的快路径走（否则升级后还是慢）
      fastMode: j['fastMode'] != false,
      splitLines: j['splitLines'] != false,
      lineConcurrency: ((j['lineConcurrency'] as num?)?.toInt() ?? 6).clamp(1, 8),
      pageConcurrency: ((j['pageConcurrency'] as num?)?.toInt() ?? 2).clamp(1, 4),
    );
  }
}

/// 提示词：让模型直接给**结构化音符事件**（等价于 MIDI 事件表），而不是简谱文本。
///
/// 原因：简谱文本要用减时线/附点/延音横线这些排版符号表达节奏，模型很容易写错；
/// 改成 `{音级, 八度, 起始, 时值}` 的数字表后，节奏就是数字，误差小得多，
/// 而且这份数据可以直接生成乐谱与 MIDI（见 `omr/ai_notes.dart`）。
///
/// **节奏（时值）是这份提示词里最被强调的部分**：实际反馈里出现过"整页音符
/// 时值全都是 1 拍、节奏全丢"的情况。对策有三条，缺一不可：
///   1. 把减时线/附点/延音横线/休止符**逐条讲清楚**（不是一句"dur 以四分音符为 1"）；
///   2. 给一个**混合节奏的完整小节示例**，让模型照着抄格式；
///   3. 给一条**模型自己能算的硬性自检**——每个小节的 dur 之和必须等于拍号，
///      不等就必须回去重看减时线。模型算术比看图可靠，这条能自纠。
const String kDefaultCloudPrompt = '''你是简谱识谱专家。请把图片里的简谱识别成**音符事件表**，用 JSON 输出。

格式（只输出这个 JSON，不要解释、不要 Markdown 代码块、不要缩进换行）：
{"title":"曲名","key":"1=C","beats":4,"beatType":4,"tempo":96,"v1":[[1,0,0,0.5],[1,0,0.5,0.5],[5,0,1,1],[3,0,2,2]],"v2":[[1,-2,0,4]]}

每个音写成数组 [音级, 八度, 起始拍, 时值]，可选第 5 位是变音记号字符串：
- 音级：1-7（简谱上的数字）
- 八度：**看数字正上方/正下方的小圆点**（见下面"八度"一节），没有点才是 0
- 起始拍：这个音从第几拍开始，**以四分音符为 1**（0 = 第一拍）
- 时值：这个音持续几拍，**以四分音符为 1**（见下面的"节奏"一节）
- 变音记号：升号写 "#"，降号写 "b"，还原写 "n"；没有就省略第 5 位
- v1 = 上面那条旋律（高音谱/右手）；v2 = 下面那条（低音谱/左手），只有一条旋律时不要写 v2
- 同时发声的音（和弦、双音）：写成多条、**起止完全相同**即可，不要加别的标记
- 每小节拍数由 beats/beatType 决定（4/4 就是 4 拍）；start 请按谱面小节线累加，不要每小节重置
- 有反复记号时只识别一遍谱面内容，不要展开

调号 key：
- 大调写 "1=C" 这种形式，数字照抄谱面
- 小调若谱面写 "6=A"，就原样写 "6=A" 且数字照抄（不要自己换算音级）

曲名 title：
- 抄**谱面上印的曲名**：一般在页面最上方（可能在谱号上方、可能有书名号《》、可能是艺术字或手写体），
  请放大仔细看，一定不要漏。
- title 里**只放曲名本身**：不要写数字、不要写简谱音级（像 "7281" 这种是错的）、
  不要写"简谱/谱子/图片/未命名"这类词、也不要写词曲作者。
- 整张图确实没有印刷的标题时，才写空字符串 ""。

════════ 八度（数字上下的点）—— 最容易看漏，必须逐个数字看 ════════
简谱的音高 = 数字 + **数字正上方/正下方的小圆点**，点数就是八度数：
- 数字**上面**有 1 个点 → octave = **1**；2 个点 → **2**（更高）
- 数字**下面**有 1 个点 → octave = **-1**；2 个点 → **-2**（更低）
- **没有点才是 0**。
- 低八度也常写成数字右下角的**逗号**：`1,` = -1、`1,,` = -2（意思和下面的点一样）。

⚠️ 三条必须做到的：
1. **点的位置只有两种含义，别混**：在数字**正上方/正下方** = 八度；
   在数字**右边** = 附点（时值 ×1.5）。位置不同、含义完全不同。
2. 这些点非常小（扫描件里常常只有 1~2 像素），请**放大到能看清数字顶部和底部**再判断。
3. **没有点就是 0，这一点最容易被搞错**：只有"数字正上方确实能看到小圆点"才写 +1，
   只有"数字正下方确实能看到小圆点"（或右下角有逗号）才写负八度。
   看不清、拿不准的时候**按 0 写**，不要凭空加八度。

一致性自检（输出前必须做）：
- 一整页里**必然同时存在 0（无点）和 ±1（有点）的音**。如果你输出的 octave 里
  **一个 0 都没有**，几乎可以肯定你把"没有点的音"也当成有点了（尤其是把没有点的音
  写成了下加点 -1）——真实歌曲的中间音区一定会有大量不带点的音。
- **同一个声部的音域不该离谱地宽**：主旋律一般在一个八度多一点（十几度）以内。
  如果你输出的某个声部跨了三四个八度（例如 48~83 都出现），说明八度看错了。
- 上声部 v1 的音**普遍应当高于**下声部 v2。如果你输出的 v2 反而比 v1 高，说明八度看反了。

════════ 节奏（同样重要，最容易错，必须逐条核对）════════
简谱的音高写数字、节奏写在数字**身上**，所以时值必须从这些记号读出来，
**绝不能因为看不清楚就全都写 1**：

1) 数字后面什么都没有 → 时值 = 1（四分音符）
2) 数字**下面一条横线**（减时线）→ 时值 = 0.5（八分音符）
   两条横线 → 0.25（十六分音符）；三条横线 → 0.125（三十二分音符）
   ⚠️ 横线是"贴在数字下面的一条/两条短横"，扫描件里常常很细，请放大去看：
   一串数字下面连成一条线的，**整串都是八分音符**（0.5），不是四分音符。
3) 数字**右边一个点**（附点）→ 时值 ×1.5
   （0.5→0.75，1→1.5，2→2.5）注意区别：点写在数字右边才是附点，
   点写在数字**上面/下面**是八度记号，别混。
4) 数字后面跟**横线 `-`**（延音线）→ 每一条横线再加 1 拍。
   `5 -` 时值 = 2（二分）；`5 - - -` 时值 = 4（全音符）；
   `5 -` 在 3/4 拍里同样是 2 拍。**这是简谱里唯一表示"长音"的方式**，
   如果一个小节里出现了 `-`，这个小节的时值一定不是全 1。
5) 休止符 `0` 也要按时值算（`0` = 1 拍，`0/` = 0.5 拍…），
   但**不用写进 JSON**：它占掉的时间由前后音符的 start/dur 自然留出空档。
6) 三连音（数字上标 3 或连音线）：三个音平分两拍 → 每个 2/3 拍。
7) 连音线（`( )` 或 `~`）把同一个音连起来时，**合并成一个长音**写（dur = 各段之和），
   不要拆成两个独立事件。
8) 减时线与延音线可能同时出现（`5/ -`）：先把减时线算出来（0.5），
   再加延音线的拍数（+1）= 1.5。

**每小节自检（输出前必须做）**：
把每个小节里所有音符（含休止空档）的时值加起来，必须**正好等于** beats（4/4 就是 4 拍）。
- 如果某小节加起来不是 4 拍，说明你漏看了减时线或延音线，**回去重新看那一小节**，不要硬凑。
- 如果整页几乎每个音都是 1 拍，那基本可以确定你漏了减时线：真实歌曲里
  四分、八分、十六分、附点、二分、全音符都会出现，**时值必须至少有 3 种不同取值**。
- 反过来，时值也不能乱猜：相邻音之间横向距离宽 → 通常时值更长；
  挤在一起、下面有横线 → 时值更短。

**必须把整页每一个音都输出完**（整页通常有 100~300 个音）。一个音都不能漏，
不要写"以下省略""以此类推"，不要在中间结束。''';

/// 模型没按结构化格式返回（写成了简谱文本）时的**重问提示词**。
///
/// 为什么需要：文本路径要靠减时线/附点这些排版符号表达节奏，误差大得多，
/// 而且模型常常只写一行（整页几百个音会缩水成几十个）。实测春风吹一页：
/// 结构化 201 个音，文本兜底只有 32 个音——差 6 倍。
const String kFormatRepairPrompt = '''$kDefaultCloudPrompt

════════ 上一次的格式不对，请重做 ════════
你上一次输出的是**简谱文本**（像 "1 2 3 4 |" 这样），这是不行的。
只接受**一个 JSON 对象**：以 { 开头、以 } 结尾，里面是 title/key/beats/beatType/tempo/v1/v2。
- 不要写简谱文本、不要写 Markdown 代码块、不要任何解释文字。
- 整页每个音都要在 v1/v2 里出现（通常几百个），不能只写一行。
请重新输出完整 JSON。''';

/// 检测到"八度点没读对"时追加的补救提示词。
/// [zeroShare] 是上一次结果里 octave=0 的占比：太低说明把"没点的音"也当成有点了。
String octaveRepairPrompt({
  required int noteCount,
  required double flatShare,
  double zeroShare = 1,
  bool bassInverted = false,
  bool wideSpan = false,
}) {
  final zeroPct = (zeroShare * 100).round();
  final flatPct = (flatShare * 100).round();
  final what = bassInverted
      ? '下声部反而比上声部还高（八度看反了）'
      : zeroPct <= 2
          ? '整页一个 octave=0 都没有（$zeroPct%），说明你把**没有点的音**也当成有点了'
          : wideSpan
              ? '某个声部的音域宽得离谱（跨了三四个八度）'
              : '几乎全是同一个八度（$flatPct% 都是 0），说明你漏看了上下加点';
  return '''$kDefaultCloudPrompt

════════ 上一次的结果里八度不对，请重做 ════════
你上一次输出 $noteCount 个音，问题：$what。
请重新仔细看一遍图片，逐个数字确认：
- **没有点就是 0**：只有数字正上方**确实**能看到小圆点才写 +1；只有正下方确实有点
  （或右下角有逗号 `1,`）才写负八度。看不清就按 0 写，**不要凭空加八度**。
- 一整页里**必然同时有 0 和 ±1 的音**：不带点的中间音区通常占很大比例。
- 主旋律的音域一般在一个八度多一点以内；若某个声部跨了三四个八度，就是看错了。
- 上声部 v1 要普遍高于下声部 v2；低音伴奏才带下加点/逗号。
重新输出**完整**的 JSON（整页所有音），octave 必须真实反映谱面上的点。''';
}

/// 检测到"整页时值都一样"时，追加在提示词后面的**补救指令**。
///
/// 为什么需要它：只把规则写清楚不一定够——模型一旦先入为主按四分音符输出，
/// 就会一路错到底。这时候把"你上次的结果"直接甩回给它（整页都是 X 拍），
/// 让它带着怀疑重看一遍减时线，实测能显著提高时值多样性。
String rhythmRepairPrompt({required int noteCount, required double flatDur}) {
  final label = flatDur == flatDur.roundToDouble()
      ? '${flatDur.toInt()}'
      : '$flatDur';
  return '''$kDefaultCloudPrompt

════════ 上一次的结果不合格，请重做 ════════
你上一次输出把 $noteCount 个音的时值几乎全写成了 $label 拍（四分音符）。
这是错的：说明你**没有看每个数字下面的减时线、右边的附点、以及后面的延音横线**。
请重新仔细看一遍图片，特别注意：
- 数字下面有没有短横线（一条 = 0.5 拍，两条 = 0.25 拍）；扫描件里这些线很细，
  但同一行里往往是**连续的**（一整串数字共用一条线），不要漏。
- 数字右边有没有附点（×1.5）。
- 数字后面有没有 `-`（每条 +1 拍）——这是简谱里唯一表示长音的方式，
  歌里一定会有（句尾、长音处）。
- 每个小节的时值之和必须正好等于拍号；对不上就是你漏看了。
重新输出**完整**的 JSON（整页所有音，不能少），时值至少要有 3 种不同取值。''';
}

/// DeepSeek / OpenAI 兼容实现（用 dart:io，无需额外依赖）
class OpenAiCompatibleRecognizer implements CloudRecognizer {
  final CloudConfig config;
  const OpenAiCompatibleRecognizer(this.config);

  @override
  String get name => 'AI 识谱（${config.model}）';

  @override
  bool get isConfigured => config.isConfigured;

  @override
  Future<CloudResult> recognize(Uint8List imageBytes,
      {String mimeType = 'image/jpeg', String? promptOverride, String? effortOverride}) async {
    if (!isConfigured) throw StateError('AI 识谱尚未配置：请在设置里填写接口地址、API Key 与模型名');
    final base = config.endpoint.replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse(base.endsWith('/chat/completions') ? base : '$base/chat/completions');

    // 快速模式：不让模型"思考"。实测整页 117s -> 6~7s，输出 token 少一个数量级。
    // 两个字段一起发：`reasoning_effort: none` 是标准写法，`thinking: {type: disabled}`
    // 是 DeepSeek 系的写法；实测偶尔只发前者模型仍会"想"（那一次跑了 150s）。
    // 有些 OpenAI 兼容服务不认这些字段会返回 400，所以按三级降级重试（见下）。
    final fast = config.fastMode && (effortOverride == null || effortOverride == 'none');
    final effort = effortOverride ?? (config.fastMode ? 'none' : config.reasoningEffort);

    Map<String, dynamic> buildBody(String? effortValue, {required bool withThinking}) => {
          'model': config.model,
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': promptOverride ?? config.prompt},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:$mimeType;base64,${base64Encode(imageBytes)}'},
                },
              ],
            },
          ],
          'temperature': 0,
          'max_tokens': config.maxTokens,
          // 推理模型：不压低推理量的话 token 会被"思考"吃光，正文会是空的。
          if (effortValue != null && effortValue.isNotEmpty) 'reasoning_effort': effortValue,
          if (withThinking) 'thinking': {'type': 'disabled'},
        };

    Future<String> post(Map<String, dynamic> body, Duration timeout) async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      try {
        final request = await client.postUrl(url);
        request.headers.contentType = ContentType.json;
        request.headers.set('Authorization', 'Bearer ${config.apiKey}');
        request.add(utf8.encode(jsonEncode(body)));
        final response = await request.close().timeout(timeout);
        final text = await response.transform(utf8.decoder).join();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('AI 识谱失败（HTTP ${response.statusCode}）：'
              '${text.length > 300 ? text.substring(0, 300) : text}');
        }
        return text;
      } finally {
        client.close(force: true);
      }
    }

    // 快速模式给一个"不正常就重来"的上限：正常 6~7 秒，卡到 60 秒说明这次
    // 服务端/模型没听"别思考"，直接掐掉重发一次，别让用户干等两三分钟。
    final fastTimeout = const Duration(seconds: 60);
    final normalTimeout = const Duration(seconds: 180);

    final attempts = <Map<String, dynamic>>[
      buildBody(effort, withThinking: fast),
      if (fast) buildBody(effort, withThinking: false),
      if (effort.isNotEmpty) buildBody(null, withThinking: false),
    ];

    String? text;
    Object? lastError;
    for (var i = 0; i < attempts.length && text == null; i++) {
      try {
        text = await post(attempts[i], fast ? fastTimeout : normalTimeout);
      } on HttpException catch (e) {
        lastError = e;
        // 只有"服务端不认这个字段"（400）才值得换一种写法重发；
        // 其它 HTTP 错误（401/429/5xx）换字段也没用，直接抛出
        if (!e.message.contains('HTTP 400')) rethrow;
      } on TimeoutException catch (e) {
        lastError = e;
        // 超时：同一种写法再试一次（多见于网络抖动）
        if (i + 1 >= attempts.length) rethrow;
        try {
          text = await post(attempts[i], fast ? fastTimeout : normalTimeout);
        } on TimeoutException {
          rethrow;
        }
      }
    }
    if (text == null) {
      throw lastError is Exception ? lastError : StateError('AI 识谱失败：$lastError');
    }

    final decoded = jsonDecode(text) as Map<String, dynamic>;    final choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) throw StateError('AI 返回内容为空');
    final message = (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?;
    final content = message?['content'];
    final raw = content is String
        ? content
        : (content is List ? content.map((c) => (c is Map ? (c['text'] ?? '') : '')).join() : '');
    final cleaned = cleanJianpuText(raw);
    if (cleaned.trim().isEmpty) {
      final usage = decoded['usage'];
      throw StateError('AI 没有返回正文（可能是推理 token 用尽），返回用量：${jsonEncode(usage)}');
    }
    return CloudResult(cleaned, raw: raw);
  }
}

/// 清理 AI 返回的文本：去掉代码块、说明文字、声部标签、小节序号，全角转半角
String cleanJianpuText(String raw) {
  var s = raw.trim();
  final fence = RegExp(r'```[a-zA-Z]*\n?([\s\S]*?)```').firstMatch(s);
  if (fence != null) s = fence.group(1)!.trim();

  final out = <String>[];
  for (var line in s.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    line = line.replaceAll('：', ':');
    // 去掉开头的声部标签 / 小节序号，只保留冒号后面的记号
    final labelMatch = RegExp(r'^(上声部|下声部|高声部|低声部|旋律|伴奏|主旋律|voice\s*\d*)\s*[:：]').firstMatch(line);
    if (labelMatch != null) line = line.substring(labelMatch.end).trim();
    line = line.replaceAll(RegExp(r'^\(?\d{1,2}\)?[\.、]\s*'), ''); // (1) 5. 之类的小节序号
    if (line.isEmpty) continue;
    if (RegExp(r'^(说明|注[:：]|以下是|格式参考)').hasMatch(line)) continue;
    // 全角数字/符号规范成半角
    line = line
        .replaceAll('｜', '|')
        .replaceAll('／', '/')
        .replaceAll('－', '-')
        .replaceAll('．', '.')
        .replaceAll('，', ',')
        .replaceAll('＃', '#');
    for (var d = 0; d <= 9; d++) {
      line = line.replaceAll(String.fromCharCode(0xFF10 + d), '$d');
    }
    // 模型偶尔把八度点写在数字前面（如 ".4" 表示 4 上加点），统一挪到数字后面
    line = line.replaceAllMapped(
      RegExp(r'(^|[\s|])\.([0-7])'),
      (m) => "${m.group(1)}${m.group(2)}'",
    );
    out.add(line);
  }
  return out.join('\n');
}

/// 极简设置持久化（JSON 文件，避免引入 shared_preferences 依赖）
class CloudSettingsStore {
  static const _fileName = 'ai_recognizer.json';

  static Future<File> _file() async {
    final dir = AppPaths.outputDir();
    return File(AppPaths.join(dir, _fileName));
  }

  static Future<CloudConfig> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return const CloudConfig();
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return CloudConfig.fromJson(json);
    } catch (_) {
      return const CloudConfig();
    }
  }

  static Future<void> save(CloudConfig config) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(config.toJson()), flush: true);
  }
}
