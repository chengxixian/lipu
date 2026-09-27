/**
 * 统一乐谱模型（Score IR）+ 音高/时值工具
 *
 * 时值单位约定：以四分音符 = 1 tick。
 *
 * Score = {
 *   meta: { title, composer, lyricist, keyName, mode, beats, beatType, tempo, clef, warnings[] },
 *   measures: [ Measure ]
 * }
 * Measure = { items: Item[], repeatStart: bool, repeatEnd: bool, final: bool }
 * Item =
 *   { kind:'note', degree:1..7, octave:int, accidental:''|'#'|'b'|'n', ticks:number,
 *     lyric:string|null, tieToPrev:bool, tieToNext:bool, src?:{confidence,bbox,raw} }
 * | { kind:'rest', ticks:number, src? }
 */

export const LETTERS = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
export const NATURAL_PC = [0, 2, 4, 5, 7, 9, 11];
export const MAJOR_STEPS = [0, 2, 4, 5, 7, 9, 11];
export const MINOR_STEPS = [0, 2, 3, 5, 7, 8, 10];

/** 每八度半音数 */
export const OCTAVE = 12;
/** 中音区（简谱不带点）的基准八度：1 = C4 = MIDI 60 */
export const BASE_OCTAVE = 4;
export const MIDI_BASE = 12 * (BASE_OCTAVE + 1); // 60

const ACC_OFFSET = { '': 0, '#': 1, b: -1, n: 0, '♯': 1, '♭': -1, '♮': 0 };

/** 调号显示名 -> 升降号数量（正=升号数，负=降号数） */
const KS_MAJOR = { 0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6, 1: -5, 10: -2, 3: -3, 8: -4, 5: -1 };
const KS_MINOR = { 9: 0, 4: 1, 11: 2, 6: 3, 1: 4, 8: 5, 3: 6, 10: 7, 2: -1, 7: -2, 0: -3, 5: -4, 10: -5, 3: -6, 8: -7 };

/**
 * 解析调号写法，兼容 "C" "#F" "F#" "bB" "Bb" "♯F" "♭B" "Am" "a小调" "C大调" "6=A"
 * @returns {{letter:string, alter:number, mode:'major'|'minor', text:string}}
 */
export function parseKeySpec(raw) {
  let s = String(raw == null ? 'C' : raw).trim();
  if (!s) s = 'C';
  let mode = null;
  if (/小调|minor|^m$|min/i.test(s)) mode = 'minor';
  if (/大调|major|maj/i.test(s)) mode = 'major';
  s = s.replace(/小调|大调|minor|major|maj|min/gi, '').trim();
  // 末尾单独的 m（Am）
  if (/^[A-Ga-g][#b♯♭]?m$/.test(s)) { mode = 'minor'; s = s.slice(0, -1); }
  s = s.replace(/\s+/g, '');
  let alter = 0;
  // 前置或后置升降号
  if (s.startsWith('#')) { alter += 1; s = s.slice(1); }
  if (s.startsWith('b') && s.length > 1) { alter -= 1; s = s.slice(1); }
  if (s.startsWith('♯')) { alter += 1; s = s.slice(1); }
  if (s.startsWith('♭')) { alter -= 1; s = s.slice(1); }
  let m;
  if ((m = s.match(/^([A-Ga-g])([#b♯♭]?)$/))) {
    let letter = m[1].toUpperCase();
    const acc = m[2];
    if (acc === '#' || acc === '♯') alter += 1;
    if (acc === 'b' || acc === '♭') alter -= 1;
    if (!mode) mode = 'major';
    return { letter, alter, mode, text: letter + (alter > 0 ? '#'.repeat(alter) : alter < 0 ? 'b'.repeat(-alter) : '') + (mode === 'minor' ? 'm' : '') };
  }
  // 简谱 1=x 形式中的数字调式提示：6=A → 小调
  if ((m = s.match(/^([1-7])\s*=\s*(.+)$/))) {
    const inner = parseKeySpec(m[2]);
    if (m[1] === '6') inner.mode = 'minor';
    return inner;
  }
  return { letter: 'C', alter: 0, mode: mode || 'major', text: 'C' };
}

/**
 * 由调号得到音阶信息
 * @returns {{letter,letterIdx,alter,mode,tonicPc,tonicMidi,steps:number[],keySignature:number,vexKey:string,xmlFifths:number,display:string}}
 */
export function keyInfo(spec) {
  const s = typeof spec === 'string' ? parseKeySpec(spec) : (spec || parseKeySpec('C'));
  const letterIdx = Math.max(0, LETTERS.indexOf(s.letter));
  const tonicPc = (((NATURAL_PC[letterIdx] + s.alter) % 12) + 12) % 12;
  const ks = (s.mode === 'minor' ? KS_MINOR : KS_MAJOR)[tonicPc];
  const keySignature = ks == null ? 0 : ks;
  const display = s.letter + (s.alter > 0 ? '#'.repeat(s.alter) : s.alter < 0 ? 'b'.repeat(-s.alter) : '') + (s.mode === 'minor' ? 'm' : '');
  return {
    letter: s.letter,
    letterIdx,
    alter: s.alter,
    mode: s.mode,
    tonicPc,
    tonicMidi: MIDI_BASE + tonicPc,
    steps: s.mode === 'minor' ? MINOR_STEPS : MAJOR_STEPS,
    keySignature,
    vexKey: display,          // VexFlow addKeySignature 接受 'C','G','F','Am','Bb' 等
    xmlFifths: keySignature,
    display,
  };
}

export function accidentalOffset(acc) {
  const v = ACC_OFFSET[acc == null ? '' : acc];
  return v == null ? 0 : v;
}

/**
 * 简谱音级 -> MIDI
 * @param {number} degree 1..7
 * @param {number} octave 相对中音区的八度（上加点 +1，下加点 -1）
 * @param {string} accidental '' | '#' | 'b' | 'n'
 * @param {ReturnType<keyInfo>} ki
 */
export function degreeToMidi(degree, octave, accidental, ki) {
  const d = Math.min(7, Math.max(1, degree | 0));
  const off = ki.steps[d - 1] + accidentalOffset(accidental);
  return ki.tonicMidi + off + OCTAVE * (octave | 0);
}

/**
 * 把 MIDI 拼写成五线谱上的字母音名（保持音级的字母，使调号内音符自然）
 * @param {number} midi
 * @param {number} letterIdx 该音级应对应的字母序号（0=C）
 */
export function spellMidi(midi, letterIdx) {
  const idx = ((letterIdx % 7) + 7) % 7;
  const pc = NATURAL_PC[idx];
  const letter = LETTERS[idx];
  // 目标音所在的八度，再用该八度内该字母的自然音高求升降
  let octave = Math.floor(midi / OCTAVE) - 1;
  let natural = OCTAVE * (octave + 1) + pc;
  let alter = midi - natural;
  // 升降跨过八度时把八度移回最近的拼写：
  // MIDI 70 配字母 B 得 Bb4（而不是 alter=+11 的 B2）；MIDI 71 配字母 C 得 Cb5
  if (alter > 6) {
    alter -= OCTAVE;
    octave -= 1;
  } else if (alter < -6) {
    alter += OCTAVE;
    octave += 1;
  }
  return { letter, alter, octave, vexKey: vexKeyOf(letter, alter, octave), midi };
}

export function vexKeyOf(letter, alter, octave) {
  const acc = alter > 0 ? '#'.repeat(alter) : alter < 0 ? 'b'.repeat(-alter) : '';
  return letter.toLowerCase() + acc + '/' + octave;
}

/**
 * 简谱音符 -> 完整音高信息
 */
export function noteToPitch(item, ki) {
  const letterIdx = ki.letterIdx + (item.degree - 1);
  const midi = degreeToMidi(item.degree, item.octave || 0, item.accidental || '', ki);
  const sp = spellMidi(midi, letterIdx);
  return {
    midi,
    letterIdx: ((letterIdx % 7) + 7) % 7,
    letter: sp.letter,
    alter: sp.alter,
    octave: sp.octave,
    vexKey: sp.vexKey,
    xmlStep: sp.letter,
    xmlAlter: sp.alter,
    xmlOctave: sp.octave,
  };
}

/* ------------------------------------------------------------------ *
 * 时值
 * ------------------------------------------------------------------ */

/** 可记谱时值表（ticks 以四分音符 = 1） */
export const DUR_TABLE = [
  { ticks: 4, type: 'w', dots: 0 },
  { ticks: 3, type: 'h', dots: 1 },
  { ticks: 2, type: 'h', dots: 0 },
  { ticks: 1.5, type: 'q', dots: 1 },
  { ticks: 1, type: 'q', dots: 0 },
  { ticks: 0.75, type: '8', dots: 1 },
  { ticks: 0.5, type: '8', dots: 0 },
  { ticks: 0.375, type: '16', dots: 1 },
  { ticks: 0.25, type: '16', dots: 0 },
  { ticks: 0.1875, type: '32', dots: 1 },
  { ticks: 0.125, type: '32', dots: 0 },
  { ticks: 0.0625, type: '64', dots: 0 },
];

const EPS = 1e-6;

export function ticksToType(ticks) {
  for (const d of DUR_TABLE) if (Math.abs(d.ticks - ticks) < EPS) return { type: d.type, dots: d.dots };
  return null;
}

/** 不超过 ticks 的最大可记谱时值 */
function largestFitting(ticks) {
  for (const d of DUR_TABLE) if (d.ticks <= ticks + EPS) return d;
  return DUR_TABLE[DUR_TABLE.length - 1];
}

/**
 * 把一段时间拆成规范可记谱的音符片段（必要时用连音线连接）
 *
 * 规则：起始于强拍分组开头时可整段保留（如 4/4 首拍的二分音符）；
 * 否则不得跨越分组边界，需要在边界处切开并用延音线连接。
 *
 * @param {number} ticks 总时值
 * @param {number} startOffset 在小节内的起始位置（ticks）
 * @param {number} beatTicks 一拍的时值
 * @param {number} [groupTicks] 强拍分组长度（默认两拍）
 * @returns {{ticks:number,type:string,dots:number,tieToNext:boolean}[]}
 */
export function notateTicks(ticks, startOffset = 0, beatTicks = 1, groupTicks) {
  const group = groupTicks == null ? beatTicks * 2 : groupTicks;
  const out = [];
  let remaining = ticks;
  let pos = startOffset;
  let guard = 0;
  while (remaining > EPS && guard++ < 64) {
    const groupStart = Math.floor(pos / group) * group;
    const groupEnd = groupStart + group;
    const startsAtZero = Math.abs(pos) < EPS;
    const fitsGroup = pos + remaining <= groupEnd + EPS;
    const exact = ticksToType(remaining);
    let chunk = remaining;
    if (!exact || !(startsAtZero || fitsGroup)) {
      const toGroupEnd = groupEnd - pos;
      if (toGroupEnd > EPS && toGroupEnd < remaining - EPS) {
        chunk = toGroupEnd;
      } else {
        chunk = largestFitting(remaining).ticks;
      }
      if (!ticksToType(chunk)) chunk = largestFitting(chunk).ticks;
    }
    const rep = ticksToType(chunk) || largestFitting(chunk);
    out.push({ ticks: chunk, type: rep.type, dots: rep.dots, tieToNext: remaining - chunk > EPS });
    pos += chunk;
    remaining -= chunk;
  }
  return out;
}

/** 依据拍号算出小节容量（ticks） */
export function measureTicks(beats, beatType) {
  const beatTicks = 4 / beatType;
  return beats * beatTicks;
}

/* ------------------------------------------------------------------ *
 * 构造函数
 * ------------------------------------------------------------------ */

export function createScore(opts = {}) {
  const key = keyInfo(opts.keyName || 'C');
  return {
    meta: {
      title: opts.title || '',
      composer: opts.composer || '',
      lyricist: opts.lyricist || '',
      keyName: key.display,
      mode: key.mode,
      beats: opts.beats || 4,
      beatType: opts.beatType || 4,
      tempo: opts.tempo || 96,
      clef: opts.clef || 'auto',
      warnings: [],
    },
    measures: [],
  };
}

export function createMeasure(opts = {}) {
  return { items: [], repeatStart: !!opts.repeatStart, repeatEnd: !!opts.repeatEnd, final: !!opts.final };
}

export function makeNote(degree, octave, ticks, opts = {}) {
  return {
    kind: 'note',
    degree,
    octave: octave || 0,
    accidental: opts.accidental || '',
    ticks: ticks == null ? 1 : ticks,
    lyric: opts.lyric == null ? null : opts.lyric,
    tieToPrev: !!opts.tieToPrev,
    tieToNext: !!opts.tieToNext,
    ...(opts.src ? { src: opts.src } : {}),
  };
}

export function makeRest(ticks, opts = {}) {
  return { kind: 'rest', ticks: ticks == null ? 1 : ticks, ...(opts.src ? { src: opts.src } : {}) };
}

/** 小节内实际音符时值合计 */
export function measureFilled(measure) {
  let s = 0;
  for (const it of measure.items) if (it.kind === 'note' || it.kind === 'rest') s += it.ticks;
  return s;
}

/** 遍历所有发音事件（用于 MIDI / 播放） */
export function* iterateNotes(score) {
  const ki = keyInfo(score.meta.keyName);
  for (let mi = 0; mi < score.measures.length; mi++) {
    for (const it of score.measures[mi].items) {
      if (it.kind === 'note') yield { measure: mi, item: it, pitch: noteToPitch(it, ki) };
    }
  }
}

/** 统计信息，用于校验与测试 */
export function scoreStats(score) {
  let notes = 0, rests = 0, ticks = 0, measures = score.measures.length, lowConf = 0;
  for (const m of score.measures) {
    for (const it of m.items) {
      if (it.kind === 'note') notes++;
      else if (it.kind === 'rest') rests++;
      if (it.kind === 'note' || it.kind === 'rest') {
        ticks += it.ticks;
        if (it.src && it.src.confidence != null && it.src.confidence < 0.75) lowConf++;
      }
    }
  }
  return { measures, notes, rests, ticks, lowConfidence: lowConf };
}
