/**
 * 简谱文本解析器 —— 图片识别结果与人工输入共用同一个入口
 *
 * 语法（宽松，兼容多种写法）：
 *   调号/拍号/速度（放在行首或单独一行）：
 *     1=C   1=G   6=A(小调)   1=bB   1=#F
 *     4/4   3/4   6/8
 *     ♩=96   Q=96   速度=96   T=96
 *   元信息（单独一行）：
 *     标题：小星星     词：张三     曲：李四
 *   音符：
 *     [变音记号][音级][八度][时值][附点][延音][歌词]
 *       变音记号：# b n ♯ ♭ ♮           例：#4  b7  n1
 *       音级：1-7，0 = 休止符
 *       八度：' 或 ^ 上八度（可叠加）    , 或 v 下八度（可叠加）
 *       时值：/ 一条减时线(八分)，// 十六分，/// 三十二分
 *       附点：. （可叠加，1. 附点四分，1/. 附点八分）
 *       延音：- 每个延长一个四分音符（1- 等于二分音符，1-- 等于全音符）
 *       歌词：[啊] 紧跟音符，例：1[啊]
 *   结构：
 *     |  普通小节线      ||  双小节线      |]  终止线
 *     |: 反复开始        :| 反复结束        :||  反复结束+终止
 *     ( … )  连音线/圆滑线（相邻且同音高时按延音处理）
 *     ~      强制把前后两个音连起来（延音线）
 *     //     行内注释
 */

import {
  createScore, createMeasure, makeNote, makeRest,
  keyInfo, parseKeySpec, measureTicks, measureFilled, noteToPitch, ticksToType,
} from './model.js';

const NOTE_TOKEN = /^([#b♯♭♮]?)([0-7])([\^v',\/\.\-\+]*)(?:\[([^\]]*)\])?$/;
const HEADER_KEY = /^([1-7])\s*=\s*([#b♯♭]?[A-Ga-g](?:\s*(?:大调|小调|maj|min|m))?)/i;
const HEADER_TIME = /^(\d{1,2})\s*\/\s*(\d{1,2})$/;
const HEADER_TEMPO = /^(?:♩|Q|T|BPM|速度|节拍)\s*[=:：]\s*(\d{1,3})$/i;
const META_LINE = /^\s*(标题|曲名|歌名|title)\s*[:：]\s*(.+?)\s*$/i;
const LYRICIST_LINE = /^\s*(作词|词|lyricist)\s*[:：]\s*(.+?)\s*$/i;
const COMPOSER_LINE = /^\s*(作曲|曲|composer)\s*[:：]\s*(.+?)\s*$/i;

const VALID_BEAT_TYPES = [1, 2, 4, 8, 16];

function stripComment(line) {
  const t = line.trim();
  // 整行注释：以 // 或 ; 开头（注意 "/" 本身是减时线记号，不能随处当注释）
  if (t.startsWith('//') || t.startsWith(';')) return '';
  // 行内注释：分号之后
  const i = line.indexOf(';');
  return i >= 0 ? line.slice(0, i) : line;
}

/**
 * 解析简谱文本
 * @param {string} text
 * @param {object} [opts]
 * @returns {import('./model.js').Score & {meta:any}}
 */
export function parseJianpu(text, opts = {}) {
  const score = createScore(opts);
  const warn = (msg, line) => score.meta.warnings.push(line == null ? msg : `第${line}行: ${msg}`);

  const rawLines = String(text == null ? '' : text).replace(/\r\n?/g, '\n').split('\n');
  const measures = [];
  let cur = createMeasure();
  let pendingTieGroup = 0;          // >0 表示在括号分组内
  let tieNext = false;              // 下一个音符需要与上一个连起来
  let lastTieable = null;           // 位置：当前分组内上一个音符
  let groupNotes = [];
  let posInMeasure = 0;             // 小节内已用 ticks（用于时值拆分校验）

  const finishMeasure = (opts2 = {}) => {
    if (cur.items.length === 0 && !cur.repeatStart && !cur.repeatEnd && !opts2.force) return;
    measures.push(cur);
    cur = createMeasure();
    posInMeasure = 0;
  };

  const pushItem = (item, lineNo) => {
    if (item.kind === 'note' || item.kind === 'rest') {
      const cap = measureTicks(score.meta.beats, score.meta.beatType);
      if (posInMeasure + item.ticks > cap + 1e-6) {
        // 超出小节容量：先收尾，再放入新小节（不丢音）
        warn(`第${measures.length + 1}小节时值超出拍号容量（${posInMeasure + item.ticks} > ${cap}），已自动新起小节`, lineNo);
        finishMeasure({ force: true });
      }
    }
    cur.items.push(item);
    if (item.kind === 'note' || item.kind === 'rest') posInMeasure += item.ticks;
  };

  for (let li = 0; li < rawLines.length; li++) {
    let line = stripComment(rawLines[li]);
    if (!line.trim()) continue;
    const lineNo = li + 1;

    // ---- 元信息行 ----
    let m;
    if ((m = line.match(META_LINE))) { score.meta.title = m[2]; continue; }
    if ((m = line.match(LYRICIST_LINE))) { score.meta.lyricist = m[2]; continue; }
    if ((m = line.match(COMPOSER_LINE))) { score.meta.composer = m[2]; continue; }

    // ---- 行首的调号 / 拍号 / 速度（可连续出现多个）----
    let rest = line.trim();
    for (let guard = 0; guard < 8; guard++) {
      const t = rest.trim();
      const words = t.split(/\s+/);
      const head = words[0] || '';
      if ((m = head.match(HEADER_KEY))) {
        const spec = parseKeySpec(m[2]);
        if (m[1] === '6' && !/小调|min/i.test(m[2])) spec.mode = 'minor';
        score.meta.keyName = spec.text;
        score.meta.mode = spec.mode;
        rest = words.slice(1).join(' ');
        continue;
      }
      if ((m = head.match(HEADER_TIME)) && VALID_BEAT_TYPES.includes(+m[2]) && +m[1] >= 1 && +m[1] <= 16) {
        score.meta.beats = +m[1];
        score.meta.beatType = +m[2];
        rest = words.slice(1).join(' ');
        continue;
      }
      if ((m = head.match(HEADER_TEMPO))) {
        score.meta.tempo = +m[1];
        rest = words.slice(1).join(' ');
        continue;
      }
      break;
    }

    // ---- 正文 token ----
    const tokens = rest.match(/\[[^\]]*\]|[#b♯♭♮]?[0-7][\^v',\/\.\-\+]*|\|\:|\:\|\]|\:\|\||\:\||\|\||\|\]|\||\(|\)|~|-|\S+/g) || [];
    for (const tk of tokens) {
      if (tk === '|' ) { finishMeasure(); continue; }
      if (tk === '||') { finishMeasure(); continue; }
      if (tk === '|]' || tk === ':||') { cur.final = true; finishMeasure(); continue; }
      if (tk === ':|]') { cur.repeatEnd = true; cur.final = true; finishMeasure(); continue; }
      if (tk === '|:') { finishMeasure(); cur.repeatStart = true; continue; }
      if (tk === ':|') { cur.repeatEnd = true; finishMeasure(); continue; }
      if (tk === '(') { pendingTieGroup++; groupNotes = []; continue; }
      if (tk === ')') {
        pendingTieGroup = Math.max(0, pendingTieGroup - 1);
        // 组内相邻同音高 -> 延音线
        for (let i = 0; i + 1 < groupNotes.length; i++) {
          const a = groupNotes[i], b = groupNotes[i + 1];
          if (a && b && a.kind === 'note' && b.kind === 'note' && a.degree === b.degree && a.octave === b.octave) {
            a.tieToNext = true; b.tieToPrev = true;
          }
        }
        groupNotes = [];
        continue;
      }
      if (tk === '~') {
        tieNext = true;
        const prev = findLastSounding(cur);
        if (prev && prev.kind === 'note') prev.tieToNext = true;
        continue;
      }
      if (tk === '-') {
        // 独立延音线：延长上一个音
        const last = findLastSounding(cur);
        if (last) { last.ticks += 1; posInMeasure += 1; }
        else warn('延音线 "-" 前面没有音符，已忽略', lineNo);
        continue;
      }

      const nm = tk.match(NOTE_TOKEN);
      if (!nm) {
        if (tk.startsWith('[')) { // 试图作为歌词附着到上一个音
          const last = findLastSounding(cur);
          if (last) last.lyric = tk.slice(1, -1);
          else warn(`歌词 "${tk}" 没有对应音符，已忽略`, lineNo);
          continue;
        }
        warn(`无法识别的记号 "${tk}"，已忽略`, lineNo);
        continue;
      }

      const accidental = normAccidental(nm[1]);
      const digit = +nm[2];
      let octave = 0, underlines = 0, dots = 0, dashes = 0, lyric = nm[4] == null ? null : nm[4];
      for (const ch of nm[3]) {
        if (ch === "'" || ch === '^') octave += 1;
        else if (ch === ',' || ch === 'v') octave -= 1;
        else if (ch === '/') underlines += 1;
        else if (ch === '.') dots += 1;
        else if (ch === '-') dashes += 1;
        else if (ch === '+') octave += 1;
      }

      let ticks = 1 / Math.pow(2, underlines);
      if (dots > 0) ticks *= 2 - Math.pow(2, -dots);
      ticks += dashes;

      const item = digit === 0
        ? makeRest(ticks)
        : makeNote(digit, octave, ticks, { accidental, lyric });
      if (digit !== 0 && tieNext) { item.tieToPrev = true; tieNext = false; }
      if (digit !== 0 && pendingTieGroup > 0) groupNotes.push(item);
      pushItem(item, lineNo);
    }
  }

  finishMeasure();
  // 空谱保护
  if (measures.length === 0) measures.push(createMeasure({ final: true }));
  measures[measures.length - 1].final = true;
  score.measures = measures;

  // ---- 后处理 ----
  autoClef(score);
  validateMeasures(score, warn);
  return score;
}

function findLastSounding(measure) {
  for (let i = measure.items.length - 1; i >= 0; i--) {
    const it = measure.items[i];
    if (it.kind === 'note' || it.kind === 'rest') return it;
  }
  return null;
}

function normAccidental(a) {
  if (!a) return '';
  if (a === '♯') return '#';
  if (a === '♭') return 'b';
  if (a === '♮') return 'n';
  return a;
}

/** 音域偏低时自动改用低音谱号 */
function autoClef(score) {
  if (score.meta.clef && score.meta.clef !== 'auto') return;
  const ki = keyInfo(score.meta.keyName);
  let sum = 0, n = 0;
  for (const m of score.measures) {
    for (const it of m.items) {
      if (it.kind !== 'note') continue;
      sum += noteToPitch(it, ki).midi;
      n++;
    }
  }
  score.meta.clef = n > 0 && sum / n < 55 ? 'bass' : 'treble';
}

function validateMeasures(score, warn) {
  const cap = measureTicks(score.meta.beats, score.meta.beatType);
  score.measures.forEach((m, i) => {
    const filled = measureFilled(m);
    const isLast = i === score.measures.length - 1;
    if (filled === 0) return;
    if (filled > cap + 1e-6) warn(`第${i + 1}小节时值超出拍号（${round(filled)} / ${cap}）`);
    else if (filled < cap - 1e-6 && !(isLast && filled < cap)) {
      warn(`第${i + 1}小节时值不足拍号（${round(filled)} / ${cap}）`);
    }
  });
}

function round(x) { return Math.round(x * 1000) / 1000; }

/* ------------------------------------------------------------------ *
 * 反向：乐谱模型 -> 简谱文本（编辑框回写 / 识别结果呈现）
 * ------------------------------------------------------------------ */

export function toJianpu(score, opts = {}) {
  const lines = [];
  const meta = score.meta;
  if (meta.title) lines.push(`标题：${meta.title}`);
  if (meta.lyricist) lines.push(`词：${meta.lyricist}`);
  if (meta.composer) lines.push(`曲：${meta.composer}`);
  const header = [`1=${keyHeaderText(meta.keyName)}`, `${meta.beats}/${meta.beatType}`];
  if (meta.tempo) header.push(`♩=${meta.tempo}`);
  lines.push(header.join(' '));

  const perLine = opts.measuresPerLine || 4;
  for (let i = 0; i < score.measures.length; i++) {
    const m = score.measures[i];
    const parts = [];
    if (m.repeatStart) parts.push('|:');
    for (const it of m.items) {
      parts.push(itemToJianpu(it));
    }
    let tail = '|';
    if (m.repeatEnd) tail = ':|';
    if (m.final) tail = '|]';
    parts.push(tail);
    lines.push(parts.filter(Boolean).join(' '));
    if ((i + 1) % perLine === 0 && i !== score.measures.length - 1) lines.push('');
  }
  return lines.join('\n');
}

function keyHeaderText(keyName) {
  const ki = keyInfo(keyName);
  const base = ki.letter + (ki.alter > 0 ? '#'.repeat(ki.alter) : ki.alter < 0 ? 'b'.repeat(-ki.alter) : '');
  return base;
}

export function itemToJianpu(it) {
  if (it.kind === 'rest') return '0' + durationSuffix(it.ticks);
  const acc = it.accidental === '#' ? '#' : it.accidental === 'b' ? 'b' : it.accidental === 'n' ? 'n' : '';
  const oct = it.octave > 0 ? "'".repeat(it.octave) : it.octave < 0 ? ','.repeat(-it.octave) : '';
  const lyric = it.lyric ? `[${it.lyric}]` : '';
  return `${acc}${it.degree}${oct}${durationSuffix(it.ticks)}${lyric}`;
}

function durationSuffix(ticks) {
  if (ticks >= 1 - 1e-9) {
    const whole = Math.round(ticks);
    if (Math.abs(ticks - whole) < 1e-9) return whole > 1 ? ' ' + '- '.repeat(whole - 1).trim() : '';
  }
  const rep = ticksToType(ticks);
  if (rep) {
    const slashes = { q: '', '8': '/', '16': '//', '32': '///', '64': '////' }[rep.type];
    if (slashes != null) return slashes + '.'.repeat(rep.dots);
  }
  // 兜底：整数部分用延音线
  const whole = Math.floor(ticks + 1e-9);
  const frac = ticks - whole;
  const repF = ticksToType(frac);
  const slashPart = repF ? ({ q: '', '8': '/', '16': '//', '32': '///' }[repF.type] || '') + '.'.repeat(repF.dots) : '';
  return slashPart + (whole > 0 ? ' ' + '- '.repeat(whole).trim() : '');
}
