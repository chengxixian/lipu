/// 和弦识别结果的**乐理判读**：一组音高到底构成什么和弦、缺了什么音、多了什么音。
///
/// 用途：扒谱（尤其是钢琴）出来的和弦不可能 100% 准——
///   实测 Basic Pitch 对真实钢琴和弦的 **recall 是 100%**（和弦音一个不漏），
///   但会有**八度泛音鬼影**（C4 的二次谐波被当成 C5，precision 86%~73%），
///   而这些鬼影在频谱上与"真的八度叠置"几乎同源，**自动删不可靠**
///   （试过响度/时长判据：真 C5 = 0.43/0.19s vs 鬼影 C5 = 0.48/0.21s，完全重叠；
///    试过频谱残差：保守配置下 recall 保住了但一个鬼影也去不掉）。
/// 所以这里不猜、不删，只**把判断结果告诉用户**：这里像什么和弦、可能缺哪个音、
/// 哪几个音是八度重复——由人在编辑器里一键处理。
library;

import 'model.dart';

/// 和弦模板（相对根音的半音集合）
const Map<String, String> kChordQualityNames = {
  'maj': '大三',
  'min': '小三',
  'dim': '减三',
  'aug': '增三',
  'sus4': '挂四',
  'sus2': '挂二',
  'maj7': '大七',
  'min7': '小七',
  'dom7': '属七',
  'm7b5': '半减七',
  'dim7': '减七',
  'maj6': '大六',
  'min6': '小六',
};

const Map<String, List<int>> kChordTemplates = {
  'maj': [0, 4, 7],
  'min': [0, 3, 7],
  'dim': [0, 3, 6],
  'aug': [0, 4, 8],
  'sus4': [0, 5, 7],
  'sus2': [0, 2, 7],
  'maj7': [0, 4, 7, 11],
  'min7': [0, 3, 7, 10],
  'dom7': [0, 4, 7, 10],
  'm7b5': [0, 3, 6, 10],
  'dim7': [0, 3, 6, 9],
  'maj6': [0, 4, 9],
  'min6': [0, 3, 9],
};

const List<String> kPitchNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/// 一个和弦的判读结果
class ChordGuess {
  /// 形如 `C` / `Am7` / `G7`；认不出来时是空串
  final String label;

  /// 中文性质：大三 / 属七 …
  final String quality;

  /// 相对模板**多出来**的音（半音数，相对根音）
  final List<int> extraSteps;

  /// 模板里**没弹**的音（半音数，相对根音）
  final List<int> missingSteps;

  /// 八度重复（同一个音名出现两次）的音名
  final List<String> octaveDoubled;

  /// 匹配得分（越高越像），用于判断可不可信
  final int score;

  const ChordGuess({
    this.label = '',
    this.quality = '',
    this.extraSteps = const [],
    this.missingSteps = const [],
    this.octaveDoubled = const [],
    this.score = 0,
  });

  bool get recognized => label.isNotEmpty;

  /// 认出来了但"缺音/多音/八度重复"——值得让人看一眼
  bool get suspicious => recognized && (extraSteps.isNotEmpty || missingSteps.isNotEmpty);

  String get detail {
    final parts = <String>[];
    if (missingSteps.isNotEmpty) parts.add('缺 ${missingSteps.map(_stepName).join("/")}');
    if (extraSteps.isNotEmpty) parts.add('多 ${extraSteps.map(_stepName).join("/")}');
    if (octaveDoubled.isNotEmpty) parts.add('八度重复 ${octaveDoubled.join("/")}');
    return parts.join('，');
  }

  static String _stepName(int step) {
    const names = ['1', '#1', '2', '#2', '3', '4', '#4', '5', '#5', '6', '#6', '7'];
    return names[((step % 12) + 12) % 12];
  }
}

/// 判断一组 MIDI 音高构成什么和弦（三度叠置模板匹配）。
///
/// 评分：命中模板音 +1，多出来的音 −2，模板里缺的音 −1；
/// 得分最高且 >0 的模板胜出，否则判为"认不出来"（可能是非三度叠置、或者扒错了）。
ChordGuess guessChord(List<int> midis) {
  final pcs = midis.map((m) => ((m % 12) + 12) % 12).toSet();
  if (pcs.length < 2) return const ChordGuess();

  // 八度重复：同一个音名出现两次以上（不管相隔几个八度）
  final counts = <int, int>{};
  for (final m in midis) {
    counts[((m % 12) + 12) % 12] = (counts[((m % 12) + 12) % 12] ?? 0) + 1;
  }
  final doubled = <String>[
    for (final e in counts.entries)
      if (e.value > 1) kPitchNames[e.key],
  ];

  ChordGuess? best;
  var bestScore = 0;
  for (final entry in kChordTemplates.entries) {
    for (var root = 0; root < 12; root++) {
      final template = entry.value.map((s) => (s + root) % 12).toSet();
      final hit = pcs.intersection(template).length;
      final extra = pcs.difference(template);
      final missing = template.difference(pcs);
      // 至少要弹到模板里的**大部分**音：三和弦允许缺一个（正好是"缺五音"那种情况），
      // 七和弦要求至少三个。低于这个就不算和弦，免得两个音乱套成七和弦。
      if (hit < 2 || hit < template.length - 1) continue;
      final score = hit - 2 * extra.length - missing.length;
      if (score <= 0 || score <= bestScore) continue;
      bestScore = score;
      best = ChordGuess(
        label: '${kPitchNames[root]}${entry.key == 'maj' ? '' : _qualitySuffix(entry.key)}',
        quality: kChordQualityNames[entry.key] ?? entry.key,
        extraSteps: extra.map((pc) => (pc - root + 12) % 12).toList()..sort(),
        missingSteps: missing.map((pc) => (pc - root + 12) % 12).toList()..sort(),
        octaveDoubled: doubled,
        score: score,
      );
    }
  }
  return best ?? ChordGuess(octaveDoubled: doubled);
}

String _qualitySuffix(String quality) => switch (quality) {
      'min' => 'm',
      'dim' => 'dim',
      'aug' => 'aug',
      'sus4' => 'sus4',
      'sus2' => 'sus2',
      'maj7' => 'maj7',
      'min7' => 'm7',
      'dom7' => '7',
      'm7b5' => 'm7b5',
      'dim7' => 'dim7',
      'maj6' => '6',
      'min6' => 'm6',
      _ => '',
    };

/// 乐谱里一处和弦（用于在界面上列出来）
class ChordReportItem {
  final int measureIndex; // 第几小节（从 1 开始）
  final int beatIndex; // 小节内第几拍（从 1 开始，粗略）
  final List<int> midis;
  final ChordGuess guess;

  const ChordReportItem(this.measureIndex, this.beatIndex, this.midis, this.guess);

  String get tonesLabel => midis.map((m) => '${kPitchNames[m % 12]}${m ~/ 12 - 1}').join(' ');
}

/// 扫一遍乐谱：把每个含和弦的音符（`chord` 非空）判读一遍
List<ChordReportItem> analyzeScoreChords(Score score) {
  final ki = score.key;
  final out = <ChordReportItem>[];
  for (var mi = 0; mi < score.measures.length; mi++) {
    final m = score.measures[mi];
    for (final items in [m.items, m.items2]) {
      var beat = 1.0;
      for (final item in items) {
        if (item is NoteItem && item.chord.isNotEmpty) {
          final midis = notePitches(item, ki).map((p) => p.midi).toList()..sort();
          out.add(ChordReportItem(mi + 1, beat.floor(), midis, guessChord(midis)));
        }
        beat += item.ticks;
      }
    }
  }
  return out;
}

/// 一句话摘要：`和弦 8 处 · C×3 Am×2 G7×1 · ⚠2 处可疑`
String chordSummary(List<ChordReportItem> items) {
  if (items.isEmpty) return '';
  final counts = <String, int>{};
  var suspicious = 0;
  for (final it in items) {
    if (it.guess.recognized) {
      counts[it.guess.label] = (counts[it.guess.label] ?? 0) + 1;
    }
    if (it.guess.suspicious) suspicious++;
  }
  final top = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final buf = StringBuffer('和弦 ${items.length} 处');
  if (top.isNotEmpty) {
    buf.write(' · ${top.take(5).map((e) => '${e.key}×${e.value}').join(' ')}');
  }
  if (suspicious > 0) buf.write(' · ⚠$suspicious 处可疑');
  return buf.toString();
}
