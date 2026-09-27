/// 用**本地几何检测**到的八度点，纠正云端识别结果的八度。
///
/// 背景（实测）：八度点是简谱里最小的记号（扫描件里只有 1~2 像素）。云端视觉模型
/// 读它**不稳定** —— 同一张春风吹原图，两次分别给出"整页一个 octave=0 都没有"和
/// "高点几乎全丢"两种相反的错，而且把旋律行裁出来放大 2.4× 后仍然错。
///
/// 但"数字正上方/正下方有没有点"本质是**几何问题**，本地那套连通域分析反而更可靠
/// （`lib/omr/` 里本来就会把点按位置分成"右侧居中 = 附点 / 上下 = 八度"）。
/// 所以：
///   1. 跑一次本地识别，拿到**每一行**的（音级, 八度）序列（只取八度，不依赖它的整体准确率）；
///   2. 用音级序列把本地行**对齐**到云端的音符序列（容忍个别数字认错）；
///   3. 对齐可信时，用本地的八度覆盖云端的八度。
///
/// 云端负责"音级 + 节奏"（它很准），本地负责"点"（它是几何问题）——各用所长。
library;

import '../core/model.dart';
import '../core/parse.dart';
import 'ai_notes.dart';
import 'omr.dart';

/// 本地识别出来的**一行**简谱读数
class LocalOctaveLine {
  /// 这一行在原图里的 y（诊断用）
  final int y;

  /// 音级序列，0 表示休止（占位用，保证和云端序列对得上）
  final List<int> degrees;

  /// 八度序列：null = 这一格没读到点/不确定
  final List<int?> octaves;

  /// 本地行文本（诊断用）
  final String text;

  const LocalOctaveLine({
    required this.y,
    required this.degrees,
    required this.octaves,
    this.text = '',
  });

  int get length => degrees.length;
}

/// 把本地某一行的简谱文本解析成（音级, 八度）序列。
///
/// 直接复用自家解析器：本地 token 文本本来就写成 `1'` / `1,,` 这种形式。
LocalOctaveLine? parseLocalLine(String text, {int y = 0}) {
  final t = text.trim();
  if (t.isEmpty) return null;
  // 本地行可能带小节线/点等噪声，解析失败就当这一行没用
  try {
    final score = parseJianpu('1=C 4/4\n$t');
    final degrees = <int>[];
    final octaves = <int?>[];
    for (final m in score.measures) {
      for (final it in m.items) {
        if (it is NoteItem) {
          degrees.add(it.degree);
          octaves.add(it.octave);
        } else if (it is RestItem) {
          degrees.add(0);
          octaves.add(null);
        }
      }
    }
    if (degrees.length < 2) return null;
    return LocalOctaveLine(y: y, degrees: degrees, octaves: octaves, text: t);
  } catch (_) {
    return null;
  }
}

/// 从本地整页识别结果里取出所有可用的行
List<LocalOctaveLine> localOctaveLines(OmrResult result) {
  final out = <LocalOctaveLine>[];
  for (final band in result.bands) {
    final line = parseLocalLine(band.text, y: band.y0);
    if (line != null) out.add(line);
  }
  return out;
}

/// 纠正结果
class OctaveFix {
  final AiNotesScore score;
  final int aligned; // 对齐上的音符数
  final int changed; // 改掉八度的音符数
  final List<String> diagnostics;
  const OctaveFix({
    required this.score,
    required this.aligned,
    required this.changed,
    this.diagnostics = const [],
  });
}

/// 用本地读数纠正 [ai] 的八度。
///
/// [minMatch] 是"这一行和云端音符序列至少要对上多少比例"才算可信。
/// 对齐分数高（≥0.75）时直接采纳本地读数；中等分数时，如果一行要改的比例
/// 超过 60% 就跳过（那种"整行翻个个儿"的读法更可能是本地认错了）。
OctaveFix fixOctavesFromLocal(
  AiNotesScore ai,
  List<LocalOctaveLine> lines, {
  double minMatch = 0.55,
}) {
  final ki = keyInfoOf(ai.keyName);
  final notes = <AiNoteEvent>[...ai.notes];
  final diag = <String>[];
  var aligned = 0;
  var changed = 0;

  List<int> staffIndex(int staff) =>
      [for (var i = 0; i < notes.length; i++) if (notes[i].staff == staff) i];

  for (final line in lines) {
    double bestScore = 0;
    var bestStaff = 0;
    var bestOffset = 0;
    for (final staff in [1, 2]) {
      final idx = staffIndex(staff);
      if (idx.length < (line.length * 0.5).floor()) continue;
      for (var off = 0; off + line.length <= idx.length; off++) {
        final s = _matchScore(line.degrees, idx, notes, off, ki);
        if (s > bestScore) {
          bestScore = s;
          bestStaff = staff;
          bestOffset = off;
        }
      }
    }
    if (bestScore < minMatch) {
      diag.add('y=${line.y}：没对齐（best=${bestScore.toStringAsFixed(2)}）');
      continue;
    }

    final idx = staffIndex(bestStaff);
    var wouldChange = 0;
    var considered = 0;
    var digitAgree = 0;
    for (var k = 0; k < line.length; k++) {
      final want = line.octaves[k];
      final aiDeg = _degreeOf(notes[idx[bestOffset + k]], ki);
      // **只有数字也对得上才动八度**：数字不一致说明对齐漂了（低音谱上下两条
      // 声部叠在一起时很常见），这时宁可不动
      if (aiDeg != null && line.degrees[k] != 0 && aiDeg == line.degrees[k]) {
        digitAgree++;
      } else {
        continue;
      }
      if (want == null) continue;
      final cur = _octaveOf(notes[idx[bestOffset + k]], ki);
      if (cur == null) continue;
      considered++;
      if (cur != want) wouldChange++;
    }
    if (bestScore < 0.75 && considered > 0 && wouldChange > considered * 0.6) {
      diag.add('y=${line.y}：改动过多（$wouldChange/$considered）跳过');
      continue;
    }

    for (var k = 0; k < line.length; k++) {
      final want = line.octaves[k];
      if (want == null || want.abs() > 3) continue;
      final at = idx[bestOffset + k];
      final aiDeg = _degreeOf(notes[at], ki);
      // 同上：数字对不上就不动
      if (aiDeg == null || line.degrees[k] == 0 || aiDeg != line.degrees[k]) continue;
      final cur = _octaveOf(notes[at], ki);
      if (cur == null || cur == want) continue;
      notes[at] = _withOctave(notes[at], want, ki);
      changed++;
    }
    aligned += digitAgree;
    diag.add('y=${line.y}：对齐 ${line.length} 个音（匹配 '
        '${(bestScore * 100).toStringAsFixed(0)}%，数字一致 $digitAgree），改 $wouldChange 个八度');
  }

  return OctaveFix(
    score: AiNotesScore(
      title: ai.title,
      keyName: ai.keyName,
      beats: ai.beats,
      beatType: ai.beatType,
      tempo: ai.tempo,
      notes: notes,
    ),
    aligned: aligned,
    changed: changed,
    diagnostics: diag,
  );
}

/// 本地音级序列 vs 云端序列（从 [offset] 起）的匹配比例
double _matchScore(
  List<int> local,
  List<int> idx,
  List<AiNoteEvent> notes,
  int offset,
  KeyInfo ki,
) {
  var hit = 0;
  var total = 0;
  for (var k = 0; k < local.length; k++) {
    final aiDeg = _degreeOf(notes[idx[offset + k]], ki);
    if (aiDeg == null) continue;
    total++;
    if (local[k] == 0) continue; // 休止只占位，不参与打分
    if (aiDeg == local[k]) hit++;
  }
  if (total == 0) return 0;
  return hit / total;
}

int? _degreeOf(AiNoteEvent e, KeyInfo ki) =>
    e.degree ?? (e.midi > 0 ? midiToDegree(e.midi, ki).$1 : null);

int? _octaveOf(AiNoteEvent e, KeyInfo ki) =>
    e.octave ?? (e.midi > 0 ? midiToDegree(e.midi, ki).$2 : null);

/// 换一个八度（音级/变音记号不变），并把 midi 一起算对
AiNoteEvent _withOctave(AiNoteEvent e, int octave, KeyInfo ki) {
  var degree = e.degree;
  var accidental = e.accidental ?? '';
  if (degree == null) {
    final d = midiToDegree(e.midi, ki);
    degree = d.$1;
    accidental = d.$3;
  }
  return AiNoteEvent(
    staff: e.staff,
    midi: degreeToMidi(degree, octave, accidental, ki),
    start: e.start,
    dur: e.dur,
    lyric: e.lyric,
    degree: degree,
    octave: octave,
    accidental: accidental,
  );
}
