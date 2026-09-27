/**
 * MusicXML 4.0 partwise 导出
 *
 * 输入：Score IR（见 ./model.js）
 * 输出：MusicXML 4.0 partwise 字符串（单 part、单声部 voice 1）
 *
 * 时值换算约定：
 *   IR ticks 以四分音符 = 1；MusicXML <divisions> 取 16（四分音符 = 16）。
 *   duration = ticks * DIVISIONS_PER_QUARTER，必须为整数。
 */

import { keyInfo, notateTicks, degreeToMidi, spellMidi } from './model.js';

/** <divisions> 取值：四分音符 = 16，可整除到 64 分音符（16/16 = 1） */
export const DIVISIONS = 16;

/** XML 文本/属性转义 */
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/** 缩进拼接多行 */
function block(lines, indent) {
  const pad = ' '.repeat(indent);
  return lines.map((l) => pad + l).join('\n');
}

const ALTER_TEXT = { '': null, '#': 'sharp', b: 'flat', n: 'natural', '♯': 'sharp', '♭': 'flat', '♮': 'natural' };

/**
 * 解析一个音符的记谱音头（step / alter / octave）与所需变音记号。
 *
 * 做法：先用 degreeToMidi 求出目标音高（含调号默认与显式变音），
 * 再用 spellMidi 以"该音级对应的字母"拼写；最后比较拼写升降与调号隐含升降，
 * 决定是否需要写出 <accidental>。
 *   - G 大调（fifths=1）7 级不写记号：目标 F#，调号默认 F# -> 无记号
 *   - G 大调 7 级写 ♮：目标 F♮ -> 拼写 alter 0，调号 F# -> natural
 *   - G 大调 7 级写 ♯：目标 F## -> 拼写 alter +2 -> sharp
 *   - C 大调 4 级写 ♯：目标 F# -> 拼写 alter +1 -> sharp
 *   - B♭ 大调 4 级写 ♭：目标 E♭ -> 拼写 alter -1，调号覆盖 -> 无记号
 *   - C 大调 7 级写 ♮：目标 B♮ -> 拼写 alter 0，调号覆盖 -> 无记号
 *
 * 注意：model.js 的 ACC_OFFSET 把 'n' 视为 0 增量，因此还原号需要显式
 * 减去调号在该音级的隐含升降，才能得到"该字母的自然音级"。
 * @param {object} item IR 音符项
 * @param {ReturnType<import('./model.js').keyInfo>} ki 调号信息
 * @returns {{pitch:object, accidental:string|null}}
 */
function resolveNoteHead(item, ki) {
  const acc = item.accidental || '';
  const degree = Math.min(7, Math.max(1, item.degree | 0));
  const octave = item.octave || 0;
  const letterIdx = ki.letterIdx + (degree - 1);

  const keyMidi = degreeToMidi(degree, octave, '', ki); // 调号默认音高
  const keySpell = spellMidi(keyMidi, letterIdx); // 调号默认拼写
  const keyAlter = keySpell.alter; // 调号在该音级上的隐含升降

  // 显式还原号：目标是该字母的自然音级；其余情况按谱面增量求和
  const targetMidi = (acc === 'n' || acc === '♮')
    ? keyMidi - keyAlter
    : degreeToMidi(degree, octave, acc, ki);

  const sp = spellMidi(targetMidi, letterIdx);
  const pitch = {
    midi: targetMidi,
    letterIdx: ((letterIdx % 7) + 7) % 7,
    letter: sp.letter,
    alter: sp.alter,
    octave: sp.octave,
    vexKey: sp.vexKey,
    xmlStep: sp.letter,
    xmlAlter: sp.alter,
    xmlOctave: sp.octave,
  };

  let accidental = null;
  if (acc && sp.alter !== keyAlter) accidental = ALTER_TEXT[acc] || null;
  return { pitch, accidental };
}

/** <step>/<alter>/<octave>，返回已缩进的多行文本（indent 为 <pitch> 自身缩进） */
function pitchXml(p, indent) {
  // MusicXML 允许省略 alter；这里显式输出（含 0），便于解析方直接取用
  const pad = ' '.repeat(indent);
  const inner = ' '.repeat(indent + 2);
  const L = [
    `${pad}<pitch>`,
    `${inner}<step>${p.xmlStep}</step>`,
    `${inner}<alter>${p.xmlAlter}</alter>`,
    `${inner}<octave>${p.xmlOctave}</octave>`,
    `${pad}</pitch>`,
  ];
  return L.join('\n');
}

/** 由 IR ticks 得到 MusicXML duration（整数，必要时断言） */
function durationOf(ticks) {
  const v = ticks * DIVISIONS;
  const r = Math.round(v);
  if (Math.abs(v - r) > 1e-6) {
    throw new Error(`duration 非整数：ticks=${ticks} -> ${v}（<divisions>=${DIVISIONS} 不足）`);
  }
  return r;
}

/** 写一个 <note>（音符或休止符）；内部行统一以 2 空格相对缩进，最后整体缩进 */
function noteXml(frag, ctx) {
  const { p, isRest, tieStart, tieStop, accidental, lyric, indent } = ctx;
  const t = frag.type;
  const dots = frag.dots || 0;
  const L = [];
  L.push('<note>');
  if (isRest) {
    L.push('  <rest/>');
  } else {
    // <pitch> 子块：先按 2 空格相对缩进拼好，再整体参与 block()
    const inner = pitchXml(p, 0).split('\n').map((l) => '  ' + l);
    L.push(...inner);
  }
  L.push(`  <duration>${durationOf(frag.ticks)}</duration>`);
  if (!isRest && tieStart) L.push('  <tie type="start"/>');
  if (!isRest && tieStop) L.push('  <tie type="stop"/>');
  L.push('  <voice>1</voice>');
  L.push(`  <type>${t}</type>`);
  for (let i = 0; i < dots; i++) L.push('  <dot/>');
  if (!isRest && accidental) L.push(`  <accidental>${accidental}</accidental>`);
  if (!isRest && (tieStart || tieStop)) {
    L.push('  <notations>');
    if (tieStart) L.push('    <tied type="start"/>');
    if (tieStop) L.push('    <tied type="stop"/>');
    L.push('  </notations>');
  }
  if (!isRest && lyric) {
    L.push('  <lyric number="1">');
    L.push('    <syllable>');
    L.push(`      <text>${esc(lyric)}</text>`);
    L.push('    </syllable>');
    L.push('  </lyric>');
  }
  L.push('</note>');
  return block(L, indent);
}

/** 属性（调号/拍号/谱号），首小节完整，其余小节仅补 divisions 便于稳健解析 */
function attributesXml(ki, meta, full, indent) {
  const L = ['<attributes>', `  <divisions>${DIVISIONS}</divisions>`];
  if (full) {
    L.push(`  <key><fifths>${ki.xmlFifths}</fifths><mode>${meta.mode === 'minor' ? 'minor' : 'major'}</mode></key>`);
    L.push(`  <time><beats>${meta.beats}</beats><beat-type>${meta.beatType}</beat-type></time>`);
    const clef = meta.clef === 'bass'
      ? ['<sign>F</sign>', '<line>4</line>']
      : ['<sign>G</sign>', '<line>2</line>'];
    L.push('  <clef>');
    for (const c of clef) L.push('    ' + c);
    L.push('  </clef>');
  }
  L.push('</attributes>');
  return block(L, indent);
}

/** 速度标记（metronome + sound） */
function directionXml(meta, indent) {
  const per = Number.isFinite(meta.tempo) && meta.tempo > 0 ? Math.round(meta.tempo) : 96;
  return block(
    [
      '<direction placement="above">',
      '  <direction-type>',
      '    <metronome>',
      '      <beat-unit>quarter</beat-unit>',
      `      <per-minute>${per}</per-minute>`,
      '    </metronome>',
      '  </direction-type>',
      `  <sound tempo="${per}"/>`,
      '</direction>',
    ],
    indent
  );
}

/** 左小节线（反复开始） */
function leftBarlineXml(measure, indent) {
  if (!measure.repeatStart) return '';
  return block(
    [
      '<barline location="left">',
      '  <bar-style>heavy-light</bar-style>',
      '  <repeat direction="forward"/>',
      '</barline>',
    ],
    indent
  );
}

/** 右小节线（反复结束 / 终止线）；重复时反复记号优先，必要时两者并列 */
function rightBarlineXml(measure, indent) {
  const out = [];
  if (measure.repeatEnd) {
    out.push(
      block(
        [
          '<barline location="right">',
          '  <bar-style>light-heavy</bar-style>',
          '  <repeat direction="backward"/>',
          '</barline>',
        ],
        indent
      )
    );
  }
  if (measure.final) {
    out.push(
      block(
        ['<barline location="right">', '  <bar-style>light-heavy</bar-style>', '</barline>'],
        indent
      )
    );
  }
  return out.join('\n');
}

/**
 * Score -> MusicXML 4.0 partwise 字符串
 * @param {object} score Score IR
 * @param {object} [opts] { software, doctype }
 */
export function toMusicXML(score, opts = {}) {
  if (!score || !score.meta || !Array.isArray(score.measures)) {
    throw new TypeError('toMusicXML: 需要合法的 Score IR（meta + measures）');
  }
  const meta = score.meta;
  const ki = keyInfo(meta.keyName);
  const software = opts.software || '离谱';
  // 每拍 ticks：拍号分母决定一拍长度（四分音符 = 1）
  const beatTicks = 4 / (meta.beatType || 4);

  const out = [];
  out.push('<?xml version="1.0" encoding="UTF-8"?>');
  if (opts.doctype !== false) {
    out.push(
      '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">'
    );
  }
  out.push('<score-partwise version="4.0">');

  // ---- work / identification ----
  out.push('  <work>');
  out.push(`    <work-title>${esc(meta.title || 'Untitled')}</work-title>`);
  out.push('  </work>');
  out.push('  <identification>');
  if (meta.composer) out.push(`    <creator type="composer">${esc(meta.composer)}</creator>`);
  if (meta.lyricist) out.push(`    <creator type="lyricist">${esc(meta.lyricist)}</creator>`);
  out.push('    <encoding>');
  out.push(`      <software>${esc(software)}</software>`);
  out.push(`      <encoding-date>${new Date().toISOString().slice(0, 10)}</encoding-date>`);
  out.push('    </encoding>');
  out.push('  </identification>');

  // ---- part list ----
  out.push('  <part-list>');
  out.push('    <score-part id="P1">');
  out.push(`      <part-name>${esc(meta.title || 'Music')}</part-name>`);
  out.push('    </score-part>');
  out.push('  </part-list>');

  out.push('  <part id="P1">');

  const measures = score.measures.length ? score.measures : [{ items: [], repeatStart: false, repeatEnd: false, final: true }];

  measures.forEach((measure, mi) => {
    out.push(`    <measure number="${mi + 1}">`);
    // 首小节：完整属性 + 速度；其余小节：补 divisions
    out.push(attributesXml(ki, meta, mi === 0, 6));
    if (mi === 0) out.push(directionXml(meta, 6));

    const lb = leftBarlineXml(measure, 6);
    if (lb) out.push(lb);

    let offset = 0; // 小节内已写时值（ticks）
    for (const item of measure.items || []) {
      const ticks = Number(item.ticks) || 0;
      if (item.kind === 'rest') {
        // 休止符同样按拍点拆分（跨拍的休止会拆成多个 <note><rest/></note>）
        const frags = notateTicks(ticks, offset, beatTicks);
        for (const frag of frags) {
          out.push(
            noteXml(frag, {
              isRest: true,
              tieStart: false,
              tieStop: false,
              accidental: null,
              lyric: null,
              indent: 6,
            })
          );
        }
        offset += ticks;
        continue;
      }
      if (item.kind !== 'note') continue;

      // 音头与变音记号一次性解析，避免 <pitch> 与 <accidental> 互相矛盾
      const { pitch: p, accidental } = resolveNoteHead(item, ki);

      const frags = notateTicks(ticks, offset, beatTicks);
      frags.forEach((frag, fi) => {
        const tiePrevState = fi === 0 ? !!item.tieToPrev : true;
        const tieNextState = fi === frags.length - 1 ? !!item.tieToNext : true;
        out.push(
          noteXml(frag, {
            p,
            isRest: false,
            tieStart: tieNextState,
            tieStop: tiePrevState,
            // 只在第一个片段写变音记号，后续连音片段不重复
            accidental: fi === 0 ? accidental : null,
            // 歌词只挂在第一个片段，避免重复歌词
            lyric: fi === 0 ? item.lyric : null,
            indent: 6,
          })
        );
      });
      offset += ticks;
    }

    const rb = rightBarlineXml(measure, 6);
    if (rb) out.push(rb);
    out.push('    </measure>');
  });

  out.push('  </part>');
  out.push('</score-partwise>');
  return out.join('\n') + '\n';
}
