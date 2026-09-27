/**
 * 导出模块单元测试：MusicXML（musicxml.js）与 MIDI（midi.js）
 * 运行：node --test
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createScore,
  createMeasure,
  makeNote,
  makeRest,
  keyInfo,
  measureTicks,
  measureFilled,
  notateTicks,
} from '../src/core/model.js';
import { toMusicXML, DIVISIONS } from '../src/core/musicxml.js';
import { toMidi, toMidiBuffer, encodeVLQ, TICKS_PER_QUARTER } from '../src/core/midi.js';

/* ------------------------------------------------------------------ *
 * 测试用 Score：4 小节 4/4，1=G，含十六分/三十二分/附点/连音线/休止/反复/歌词/变音
 * 音符记号共 31 个，其中 1 个为延音延续音（tieToPrev，不重新触发 note-on）
 * ------------------------------------------------------------------ */

/** createMeasure 不接受 items 选项，这里补一个便捷构造 */
function measureOf(items, opts = {}) {
  const m = createMeasure(opts);
  m.items = items;
  return m;
}

function buildSample() {
  const score = createScore({
    title: '小星星变奏 & <测试>',
    composer: 'A. Composer',
    lyricist: 'B. Lyricist',
    keyName: 'G',
    beats: 4,
    beatType: 4,
    tempo: 120,
  });

  // 第 1 小节（4 拍）：四分 | 十六 十六 十六 十六 | 四分 | 十六 十六 十六 十六
  score.measures.push(
    measureOf([
      makeNote(1, 0, 1, { lyric: '一' }), // G4 四分
      makeNote(2, 0, 0.25, { lyric: '闪' }), // A4 十六分
      makeNote(3, 0, 0.25, { lyric: '一' }), // B4 十六分
      makeNote(4, 0, 0.25, { lyric: '闪' }), // C5 十六分
      makeNote(5, 0, 0.25, { lyric: '亮' }), // D5 十六分
      makeNote(1, 0, 1, { lyric: '晶' }), // G4 四分
      makeNote(1, 0, 0.25, { lyric: '晶' }), // G4 十六分
      makeNote(3, 0, 0.25, { lyric: '一' }), // B4 十六分
      makeNote(5, 0, 0.25, { lyric: '哟' }), // D5 十六分
      makeNote(7, 0, 0.25, { accidental: 'n', lyric: '哟' }), // F♮5 十六分（G 大调需写还原号）
    ])
  );

  // 第 2 小节（4 拍）：附点十六+三十二分 十六分 十六分 | 十六 十六 十六 十六 | 八分 四分 八分
  score.measures.push(
    measureOf([
      makeNote(1, 0, 0.375, { lyric: '满' }), // G4 附点十六分
      makeNote(2, 0, 0.125, { lyric: '天' }), // A4 三十二分
      makeNote(3, 0, 0.25, { lyric: '的' }), // B4 十六分
      makeNote(4, 0, 0.25, { accidental: '#', lyric: '星' }), // C#5 十六分，调号未覆盖需写升号
      makeNote(5, 0, 0.25, { lyric: '星' }), // D5 十六分
      makeNote(6, 0, 0.25, { lyric: '呀' }), // E5 十六分
      makeNote(7, 0, 0.25, { accidental: 'n', lyric: '挂' }), // F♮5 十六分
      makeNote(5, 0, 0.25, { lyric: '在' }), // D5 十六分
      makeNote(5, 0, 0.5, { lyric: '天' }), // D5 八分
      makeNote(5, 0, 1, { lyric: '上' }), // D5 四分
      makeNote(5, 0, 0.5, { tieToNext: true, lyric: '闪' }), // D5 八分，延到第 3 小节
    ])
  );

  // 第 3 小节（4 拍）：首音承接上一小节延音线
  score.measures.push(
    measureOf([
      makeNote(5, 0, 0.25, { tieToPrev: true, lyric: '亮' }), // 延续上一音，不重新触发
      makeNote(6, 0, 0.25, { lyric: '挂' }), // E5 十六分
      makeNote(7, 0, 0.25, { lyric: '在' }), // F#5 十六分（调号内，不写升号）
      makeNote(1, 1, 0.25, { lyric: '天' }), // G5 十六分
      makeNote(2, 1, 1, { lyric: '上' }), // A5 四分
      makeNote(1, 1, 0.5, { lyric: '闪' }), // G5 八分
      makeRest(1), // 四分休止
      makeNote(1, 0, 0.5, { lyric: '亮' }), // G4 八分
    ])
  );

  // 第 4 小节（4 拍）：反复记号 + 终止线；G 大调里 1 级为 G，加 b 得 Gb4
  score.measures.push(
    measureOf(
      [
        makeNote(3, 0, 1, { lyric: '挂' }), // B4 四分
        makeNote(2, 0, 1, { lyric: '在' }), // A4 四分
        makeNote(1, 0, 0.5, { accidental: 'b', lyric: '天' }), // Gb4 八分
        makeRest(1.5), // 附点四分休止
      ],
      { repeatStart: true, repeatEnd: true, final: true }
    )
  );

  return score;
}

/* ------------------------------------------------------------------ *
 * 工具：XML 标签配平 / duration 提取
 * ------------------------------------------------------------------ */

/**
 * 简易但严格的 XML 良构检查（单遍扫描，正确处理引号内的 '>'、注释、PI、CDATA、自闭合）。
 * 返回 { ok, error }。
 */
function checkXmlBalance(xml) {
  const stack = [];
  let i = 0;
  let rootSeen = false;
  let rootClosed = false;
  let depth = 0;
  while (i < xml.length) {
    const lt = xml.indexOf('<', i);
    if (lt < 0) break;
    // 文本段里不允许出现裸 '<' 或未转义的 '&'
    const text = xml.slice(i, lt);
    for (const m of text.matchAll(/&([^;\s&]*);?/g)) {
      const ent = m[0];
      if (!/^&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);$/.test(ent)) {
        return { ok: false, error: `未转义的 & ：${JSON.stringify(ent)}` };
      }
    }
    if (xml.startsWith('<!--', lt)) {
      const end = xml.indexOf('-->', lt + 4);
      if (end < 0) return { ok: false, error: '注释未闭合' };
      i = end + 3;
      continue;
    }
    if (xml.startsWith('<![CDATA[', lt)) {
      const end = xml.indexOf(']]>', lt + 9);
      if (end < 0) return { ok: false, error: 'CDATA 未闭合' };
      i = end + 3;
      continue;
    }
    if (xml.startsWith('<?', lt)) {
      const end = xml.indexOf('?>', lt + 2);
      if (end < 0) return { ok: false, error: 'PI 未闭合' };
      i = end + 2;
      continue;
    }
    if (xml.startsWith('<!', lt)) {
      const end = xml.indexOf('>', lt + 2);
      if (end < 0) return { ok: false, error: '声明未闭合' };
      i = end + 1;
      continue;
    }
    // 普通标签：扫描到引号外的 '>'
    let j = lt + 1;
    let quote = null;
    while (j < xml.length) {
      const c = xml[j];
      if (quote) {
        if (c === quote) quote = null;
      } else if (c === '"' || c === "'") {
        quote = c;
      } else if (c === '>') {
        break;
      }
      j++;
    }
    if (j >= xml.length) return { ok: false, error: '标签未闭合（缺少 >）' };
    if (quote) return { ok: false, error: '属性引号未闭合' };
    const raw = xml.slice(lt + 1, j);
    const closing = raw.startsWith('/');
    const selfClose = raw.endsWith('/');
    const name = raw.replace(/^\//, '').replace(/\/$/, '').split(/[\s/]/)[0];
    if (!name) return { ok: false, error: `空标签名：<${raw}>` };
    if (closing) {
      const top = stack.pop();
      if (top !== name) return { ok: false, error: `标签不匹配：</${name}> 对 <${top || '(空)'}>` };
      depth--;
      if (depth === 0) rootClosed = true;
      if (rootClosed && /<[^!?]/.test(xml.slice(j + 1))) {
        return { ok: false, error: `根元素闭合后仍有内容：${name}` };
      }
    } else {
      if (rootClosed) return { ok: false, error: '根元素闭合后仍有标签' };
      if (depth === 0) {
        if (rootSeen) return { ok: false, error: '存在多个根元素' };
        rootSeen = true;
      }
      if (!selfClose) {
        stack.push(name);
        depth++;
      } else if (depth === 0) {
        rootClosed = true;
      }
    }
    i = j + 1;
  }
  if (stack.length) return { ok: false, error: `未闭合标签：${stack.join(', ')}` };
  if (!rootSeen) return { ok: false, error: '没有根元素' };
  return { ok: true, error: '' };
}

/** 抽取所有 <duration>（排除 <divisions>） */
function allDurations(xml) {
  const body = xml.replace(/<divisions>[\s\S]*?<\/divisions>/g, '');
  return [...body.matchAll(/<duration>([^<]*)<\/duration>/g)].map((m) => Number(m[1]));
}

/** 按小节切分 XML 片段（跳过 <measure number=" 之前的头部） */
function measureChunks(xml) {
  return xml
    .split(/<measure number="\d+">/)
    .slice(1)
    .map((c) => c.split('</measure>')[0]);
}

/* ------------------------------------------------------------------ *
 * MusicXML
 * ------------------------------------------------------------------ */

test('MusicXML：基础结构、divisions、调号、速度、谱号', () => {
  const score = buildSample();
  const xml = toMusicXML(score);

  assert.ok(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'), '应有 XML 声明');
  assert.match(xml, /<!DOCTYPE score-partwise PUBLIC "-\/\/Recordare\/\/DTD MusicXML 4\.0 Partwise\/\/EN"/);
  assert.match(xml, /<score-partwise version="4\.0">/);
  assert.match(xml, /<divisions>16<\/divisions>/);
  assert.match(xml, /<fifths>1<\/fifths>/);
  assert.match(xml, /<mode>major<\/mode>/);
  assert.match(xml, /<time><beats>4<\/beats><beat-type>4<\/beat-type><\/time>/);
  assert.match(xml, /<clef>\s*<sign>G<\/sign>\s*<line>2<\/line>\s*<\/clef>/);
  assert.match(xml, /<software>离谱<\/software>/);
  // 标题与创作者需转义
  assert.match(xml, /<work-title>小星星变奏 &amp; &lt;测试&gt;<\/work-title>/);
  assert.match(xml, /<creator type="composer">A\. Composer<\/creator>/);
  assert.match(xml, /<creator type="lyricist">B\. Lyricist<\/creator>/);
  // 速度
  assert.match(xml, /<metronome>\s*<beat-unit>quarter<\/beat-unit>\s*<per-minute>120<\/per-minute>/);
  assert.match(xml, /<sound tempo="120"\/>/);
  assert.equal(DIVISIONS, 16);
});

test('MusicXML：小节数与 duration 均为正整数', () => {
  const score = buildSample();
  const xml = toMusicXML(score);

  const measures = [...xml.matchAll(/<measure number="(\d+)">/g)].map((m) => Number(m[1]));
  assert.deepEqual(measures, [1, 2, 3, 4], '小节数应为 4 且编号递增');

  const durs = allDurations(xml);
  assert.ok(durs.length > 10, '应输出多个 note/rest');
  for (const d of durs) {
    assert.ok(Number.isInteger(d), `duration 必须为整数，实际 ${d}`);
    assert.ok(d > 0, `duration 必须为正，实际 ${d}`);
  }

  // 每小节 duration 合计应等于小节容量 × DIVISIONS
  const perMeasure = measureChunks(xml).map((chunk) => allDurations(chunk).reduce((a, b) => a + b, 0));
  const expect = measureTicks(4, 4) * DIVISIONS;
  assert.deepEqual(perMeasure, [expect, expect, expect, expect], '每小节时值合计应为 4 拍 = 64');
});

test('MusicXML：小节线（反复开始/结束、终止线）', () => {
  const score = buildSample();
  const xml = toMusicXML(score);

  assert.match(
    xml,
    /<barline location="right">\s*<bar-style>light-heavy<\/bar-style>\s*<repeat direction="backward"\/>\s*<\/barline>/
  );
  assert.match(
    xml,
    /<barline location="left">\s*<bar-style>heavy-light<\/bar-style>\s*<repeat direction="forward"\/>\s*<\/barline>/
  );
  assert.match(xml, /<barline location="right">\s*<bar-style>light-heavy<\/bar-style>\s*<\/barline>/);

  const m1 = xml.split(/<measure number="/)[1];
  assert.ok(!m1.includes('<barline'), '第 1 小节不应有小节线');
});

test('MusicXML：变音记号按调号去重，连音片段不重复写 accidental', () => {
  const score = buildSample();
  const xml = toMusicXML(score);

  // G 大调：F♮ 需写 natural；Gb 需写 flat；C# 需写 sharp
  assert.match(xml, /<accidental>natural<\/accidental>/);
  assert.match(xml, /<accidental>flat<\/accidental>/);
  assert.match(xml, /<accidental>sharp<\/accidental>/);

  // C 大调里的 F#（4 级 + #）必须写升号
  const cScore = createScore({ keyName: 'C', beats: 4, beatType: 4 });
  cScore.measures.push(measureOf([makeNote(4, 0, 1, { accidental: '#' }), makeNote(4, 0, 1)]));
  assert.match(toMusicXML(cScore), /<accidental>sharp<\/accidental>/);

  // G 大调里 7 级本身就是 F#，若再显式写 '#' 则实际音高为 F##，仍须写出升号
  // （IR 约定：显式 accidental 是相对调号默认音级的增量）
  const gScore = createScore({ keyName: 'G', beats: 4, beatType: 4 });
  gScore.measures.push(measureOf([makeNote(7, 0, 1, { accidental: '#' })]));
  assert.match(toMusicXML(gScore), /<accidental>sharp<\/accidental>/, '显式升号必须写出');

  // C 大调里 7 级本身为 B，写 'n' 与调号默认一致 -> 不写 accidental
  const c2 = createScore({ keyName: 'C', beats: 4, beatType: 4 });
  c2.measures.push(measureOf([makeNote(7, 0, 1, { accidental: 'n' })]));
  assert.ok(!toMusicXML(c2).includes('<accidental>'), 'C 大调 B♮ 与调号一致，不应写 accidental');

  // B♭ 大调（fifths = -2）：2 级为 C，加 'b' 得 C♭，调号未覆盖 -> 必须写降号
  const bbScore = createScore({ keyName: 'Bb', beats: 4, beatType: 4 });
  bbScore.measures.push(measureOf([makeNote(2, 0, 1, { accidental: 'b' })]));
  assert.match(toMusicXML(bbScore), /<accidental>flat<\/accidental>/, 'B♭ 大调 2 级写 b 得 C♭，须写降号');

  // B♭ 大调 4 级默认已是 E♭，不写降号
  const bbPlain = createScore({ keyName: 'Bb', beats: 4, beatType: 4 });
  bbPlain.measures.push(measureOf([makeNote(4, 0, 1)]));
  assert.ok(!toMusicXML(bbPlain).includes('<accidental>'), 'B♭ 大调 4 级为调号内 E♭，不应写 accidental');

  // 跨拍拆分产生的连音片段：accidental 只出现一次
  const splitScore = createScore({ keyName: 'C', beats: 4, beatType: 4 });
  splitScore.measures.push(measureOf([makeNote(4, 0, 3.5, { accidental: '#' })]));
  const sXml = toMusicXML(splitScore);
  assert.equal(
    (sXml.match(/<accidental>sharp<\/accidental>/g) || []).length,
    1,
    '拆分为多个 <note> 时 accidental 只能写一次'
  );
  assert.match(sXml, /<tie type="start"\/>/);
  assert.match(sXml, /<tie type="stop"\/>/);
  assert.match(sXml, /<notations>\s*<tied type="start"\/>\s*<\/notations>/);
});

test('MusicXML：连音线、歌词、休止符', () => {
  const score = buildSample();
  const xml = toMusicXML(score);

  assert.match(xml, /<tie type="start"\/>/);
  assert.match(xml, /<tie type="stop"\/>/);
  assert.match(xml, /<notations>[\s\S]*?<tied type="start"\/>/);
  assert.match(xml, /<rest\/>/);
  assert.match(xml, /<lyric number="1">\s*<syllable>\s*<text>一<\/text>/);

  const lyricCount = (xml.match(/<lyric number="1">/g) || []).length;
  const noteHeads = (xml.match(/<note>/g) || []).length;
  assert.ok(lyricCount <= noteHeads, '歌词数量不应超过音符数量');
});

test('MusicXML：标签配平且自闭合标签数量合理', () => {
  const score = buildSample();
  const xml = toMusicXML(score);

  const res = checkXmlBalance(xml);
  assert.equal(res.ok, true, res.error);

  for (const tag of ['score-partwise', 'part', 'measure', 'note', 'attributes', 'work', 'identification', 'lyric']) {
    const open = (xml.match(new RegExp(`<${tag}(?:\\s[^>]*)?>`, 'g')) || []).length;
    const close = (xml.match(new RegExp(`</${tag}>`, 'g')) || []).length;
    assert.equal(open, close, `<${tag}> 开闭数量应一致`);
  }
  assert.ok(xml.trimEnd().endsWith('</score-partwise>'));
});

test('MusicXML：谱号 bass / 非法小节时值不抛异常', () => {
  const bassScore = createScore({ keyName: 'F', beats: 3, beatType: 4, clef: 'bass' });
  bassScore.measures.push(measureOf([makeNote(1, -1, 2), makeRest(1)]));
  const xml = toMusicXML(bassScore);
  assert.match(xml, /<clef>\s*<sign>F<\/sign>\s*<line>4<\/line>\s*<\/clef>/);
  assert.match(xml, /<fifths>-1<\/fifths>/);

  // 时值不足 / 超出：照常输出，不抛异常
  const badScore = createScore({ keyName: 'C', beats: 4, beatType: 4 });
  badScore.measures.push(measureOf([makeNote(1, 0, 0.5)]));
  badScore.measures.push(measureOf([makeNote(1, 0, 9)]));
  assert.doesNotThrow(() => toMusicXML(badScore));
});

test('MusicXML/MIDI：边界情形（空谱、空小节、小调、6/8、64 分音符、XML 转义）', () => {
  // 空谱：仍输出一个占位小节
  const empty = createScore({ keyName: 'C' });
  assert.equal([...toMusicXML(empty).matchAll(/<measure /g)].length, 1);
  assert.doesNotThrow(() => toMidi(empty));
  // 空小节
  const emptyMeasure = createScore({ keyName: 'C', beats: 4, beatType: 4 });
  emptyMeasure.measures.push(measureOf([]));
  assert.doesNotThrow(() => toMusicXML(emptyMeasure));
  assert.doesNotThrow(() => toMidi(emptyMeasure));

  // 小调：fifths 与 mode
  const am = createScore({ keyName: 'Am', beats: 4, beatType: 4 });
  am.measures.push(measureOf([makeNote(1, 0, 1)]));
  const amXml = toMusicXML(am);
  assert.match(amXml, /<fifths>0<\/fifths>/);
  assert.match(amXml, /<mode>minor<\/mode>/);
  assert.deepEqual(parseTrack(toMidi(am)).find((e) => e.meta === 0x59).data, [0, 1], '小调 key meta 第二字节应为 1');

  // 6/8：一小节 3.0 ticks = 48 duration
  const s68 = createScore({ keyName: 'C', beats: 6, beatType: 8 });
  s68.measures.push(
    measureOf([makeNote(1, 0, 0.5), makeNote(2, 0, 0.25), makeRest(0.25), makeNote(3, 0, 1), makeNote(4, 0, 1)])
  );
  const xml68 = toMusicXML(s68);
  assert.match(xml68, /<beats>6<\/beats><beat-type>8<\/beat-type>/);
  assert.equal(allDurations(xml68).reduce((a, b) => a + b, 0), 48);

  // 64 分音符：divisions=16 下仍为整数 duration 1
  const tiny = createScore({ keyName: 'C', beats: 4, beatType: 4 });
  tiny.measures.push(measureOf([makeNote(1, 0, 0.0625)]));
  const tinyXml = toMusicXML(tiny);
  assert.match(tinyXml, /<duration>1<\/duration>/);
  assert.match(tinyXml, /<type>64<\/type>/);

  // XML 转义：标题/歌词中的 & < > " '
  const escScore = createScore({ title: 'A & B <c> "d"', composer: 'x & y' });
  escScore.measures.push(measureOf([makeNote(1, 0, 1, { lyric: 'l & m < n' })]));
  const escXml = toMusicXML(escScore);
  assert.match(escXml, /<work-title>A &amp; B &lt;c&gt; &quot;d&quot;<\/work-title>/);
  assert.match(escXml, /<text>l &amp; m &lt; n<\/text>/);
  // 正文中不得残留未转义的 &
  const body = escXml.replace(/<!DOCTYPE[^>]*>/, '');
  assert.ok(!/&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/.test(body), '存在未转义的 &');

  // 非法输入应抛 TypeError，而不是产出坏文件
  for (const bad of [null, undefined, {}, { meta: {} }]) {
    assert.throws(() => toMusicXML(bad), TypeError);
    assert.throws(() => toMidi(bad), TypeError);
  }
});

/* ------------------------------------------------------------------ *
 * notateTicks / measureTicks 一致性
 * ------------------------------------------------------------------ */

test('notateTicks：拆分片段之和等于小节容量，且片段均为可记谱时值', () => {
  const beatTicks = 4 / 4; // 4/4，一拍 = 1 tick
  const cap = measureTicks(4, 4);
  assert.equal(cap, 4);

  const cases = [
    { ticks: 1, offset: 0 },
    { ticks: 3.5, offset: 0 },
    { ticks: 0.75, offset: 0.5 },
    { ticks: 1.25, offset: 0.75 },
    { ticks: 4, offset: 0 },
    { ticks: 0.0625, offset: 3.9375 },
    { ticks: 2.5, offset: 1.5 },
  ];
  for (const c of cases) {
    const frags = notateTicks(c.ticks, c.offset, beatTicks);
    const sum = frags.reduce((a, f) => a + f.ticks, 0);
    assert.ok(Math.abs(sum - c.ticks) < 1e-6, `ticks=${c.ticks} 拆分和 ${sum} 不一致`);
    for (const f of frags) {
      assert.ok(f.ticks > 0);
      assert.match(f.type, /^(w|h|q|8|16|32|64)$/);
      assert.ok(f.dots === 0 || f.dots === 1);
    }
    frags.slice(0, -1).forEach((f) => assert.equal(f.tieToNext, true, '中间片段应有连音线'));
    assert.equal(frags[frags.length - 1].tieToNext, false, '最后一片不应有连音线');
  }

  // 整小节填满：拆分结果合计等于容量
  const full = notateTicks(cap, 0, beatTicks);
  assert.equal(full.reduce((a, f) => a + f.ticks, 0), cap);
});

test('notateTicks：跨拍的长音按拍点切开', () => {
  const frags = notateTicks(3.5, 0, 1);
  assert.ok(frags.length >= 2, '附点二分跨拍应被切开');
  assert.equal(frags[0].ticks + frags[1].ticks, 3.5);
});

/* ------------------------------------------------------------------ *
 * MIDI
 * ------------------------------------------------------------------ */

/** 解析 MTrk 事件序列 -> [{ delta, tick, status, meta?, data }] */
function parseTrack(bytes) {
  let p = 14; // 跳过 MThd（14 字节）
  assert.equal(String.fromCharCode(...bytes.slice(p, p + 4)), 'MTrk');
  const len = (bytes[p + 4] << 24) | (bytes[p + 5] << 16) | (bytes[p + 6] << 8) | bytes[p + 7];
  p += 8;
  const end = p + len;
  const events = [];
  let tick = 0;
  while (p < end) {
    let delta = 0;
    for (;;) {
      const b = bytes[p++];
      delta = (delta << 7) | (b & 0x7f);
      if (!(b & 0x80)) break;
    }
    tick += delta;
    const status = bytes[p];
    if (status === 0xff) {
      const type = bytes[p + 1];
      const mlen = bytes[p + 2];
      const data = Array.from(bytes.slice(p + 3, p + 3 + mlen));
      events.push({ delta, tick, status, meta: type, data });
      p += 3 + mlen;
    } else {
      const hi = status & 0xf0;
      const nbytes = hi === 0xc0 || hi === 0xd0 ? 2 : 3;
      const data = Array.from(bytes.slice(p, p + nbytes));
      events.push({ delta, tick, status, data });
      p += nbytes;
    }
  }
  assert.equal(p, end, 'MTrk 长度应与实际事件字节数一致');
  return events;
}

const isOn = (e) => (e.status & 0xf0) === 0x90 && e.data[2] > 0;
const isOff = (e) => (e.status & 0xf0) === 0x90 && e.data[2] === 0;

test('MIDI：MThd 头、format 0、单轨、division 480', () => {
  const bytes = toMidi(buildSample());

  assert.equal(String.fromCharCode(...bytes.slice(0, 4)), 'MThd');
  assert.deepEqual(Array.from(bytes.slice(4, 8)), [0, 0, 0, 6], 'MThd 长度应为 6');
  assert.equal((bytes[8] << 8) | bytes[9], 0, 'format 应为 0');
  assert.equal((bytes[10] << 8) | bytes[11], 1, 'ntrks 应为 1');
  assert.equal((bytes[12] << 8) | bytes[13], 480, 'division 应为 480');
  assert.equal(TICKS_PER_QUARTER, 480);
  assert.equal(String.fromCharCode(...bytes.slice(14, 18)), 'MTrk');
  assert.deepEqual(Array.from(bytes.slice(-3)), [0xff, 0x2f, 0x00], '应以 EOT 结尾');
  assert.ok(bytes instanceof Uint8Array);
});

test('MIDI：轨道事件顺序与 meta 内容', () => {
  const events = parseTrack(toMidi(buildSample()));

  // 1. track name
  assert.equal(events[0].status, 0xff);
  assert.equal(events[0].meta, 0x03);
  assert.equal(String.fromCharCode(...events[0].data), 'Lipu');
  // 2. tempo：120 BPM -> 500000 us/quarter = 07 A1 20
  assert.equal(events[1].meta, 0x51);
  assert.deepEqual(events[1].data, [0x07, 0xa1, 0x20]);
  // 3. time signature 4/4
  assert.equal(events[2].meta, 0x58);
  assert.deepEqual(events[2].data.slice(0, 2), [4, 2]);
  // 4. key signature：G 大调 fifths = 1，major -> 0
  assert.equal(events[3].meta, 0x59);
  assert.deepEqual(events[3].data, [1, 0]);
  // 5. program change 0xC0 program 0，位于 0 时刻
  assert.equal(events[4].status, 0xc0);
  assert.equal(events[4].data[1], 0);
  assert.equal(events[4].tick, 0);

  // 事件 tick 单调不减
  for (let i = 1; i < events.length; i++) assert.ok(events[i].tick >= events[i - 1].tick);

  // 结尾 end of track
  const last = events[events.length - 1];
  assert.equal(last.meta, 0x2f);
  assert.equal(last.tick, events[events.length - 2].tick, 'EOT 与上一事件同刻');
});

test('MIDI：note-on 数量 = 音符数 - 延音延续数，时值换算正确', () => {
  const score = buildSample();
  const events = parseTrack(toMidi(score));

  const ons = events.filter(isOn);
  const offs = events.filter(isOff);
  const totalNotes = score.measures.reduce((a, m) => a + m.items.filter((i) => i.kind === 'note').length, 0);
  const tieContinuations = score.measures.reduce(
    (a, m) => a + m.items.filter((i) => i.kind === 'note' && i.tieToPrev).length,
    0
  );

  assert.equal(totalNotes, 31, '样例共 31 个音符记号');
  assert.equal(tieContinuations, 1, '样例含 1 个延音延续音');
  assert.equal(ons.length, totalNotes - tieContinuations, 'note-on 数 = 音符数 - 延音延续数');
  assert.equal(offs.length, ons.length, 'note-on / note-off 数量应相等');

  for (const e of ons) assert.equal(e.data[2], 100, '默认 velocity = 100');

  // 第一个音是 G4（MIDI 67），起始于 tick 0，四分音符 -> 480 ticks
  assert.equal(ons[0].data[1], 67);
  assert.equal(ons[0].tick, 0);
  const firstOff = offs.find((e) => e.data[1] === 67 && e.tick > 0);
  assert.equal(firstOff.tick, 480);

  // 自定义 velocity
  const ons2 = parseTrack(toMidi(score, { velocity: 64 })).filter(isOn);
  for (const e of ons2) assert.equal(e.data[2], 64);
});

test('MIDI：连音线延长前一个音（不重新触发），休止符只推进时间', () => {
  const score = createScore({ keyName: 'C', beats: 4, beatType: 4, tempo: 60 });
  score.measures.push(
    measureOf([makeNote(1, 0, 2, { tieToNext: true }), makeNote(1, 0, 1, { tieToPrev: true }), makeRest(1)])
  );
  const events = parseTrack(toMidi(score));
  const ons = events.filter(isOn);
  const offs = events.filter(isOff);

  assert.equal(ons.length, 1, '连音线延音不应产生新的 note-on');
  assert.equal(offs.length, 1);
  assert.equal(ons[0].tick, 0);
  assert.equal(offs[0].tick, 3 * 480, '合并时值 = 二分 + 四分 = 3 个四分音符');
});

test('MIDI：同刻 note-off 先于 note-on，且无负 delta', () => {
  const score = createScore({ keyName: 'C', beats: 4, beatType: 4 });
  score.measures.push(measureOf([makeNote(1, 0, 1), makeNote(1, 0, 1), makeNote(1, 0, 1)]));
  const notes = parseTrack(toMidi(score)).filter((e) => (e.status & 0xf0) === 0x90);

  for (const e of notes) assert.ok(e.delta >= 0, 'delta 必须非负');
  const at480 = notes.filter((e) => e.tick === 480);
  assert.ok(at480.length >= 2);
  assert.equal(at480[0].data[2], 0, '同刻先发 note-off');
  assert.ok(at480[1].data[2] > 0, '随后才发 note-on');
});

test('encodeVLQ：0 / 127 / 128 / 8192 / 1000000 的编码字节数与值', () => {
  const cases = [
    { v: 0, bytes: [0x00] },
    { v: 127, bytes: [0x7f] },
    { v: 128, bytes: [0x81, 0x00] },
    { v: 8192, bytes: [0xc0, 0x00] },
    { v: 1000000, bytes: [0xbd, 0x84, 0x40] },
  ];
  for (const c of cases) {
    const enc = encodeVLQ(c.v);
    assert.deepEqual(enc, c.bytes, `encodeVLQ(${c.v}) 字节不符`);
    assert.equal(enc.length, c.bytes.length, `encodeVLQ(${c.v}) 字节数不符`);
    let dec = 0;
    for (const b of enc) dec = (dec << 7) | (b & 0x7f);
    assert.equal(dec, c.v, `encodeVLQ(${c.v}) 解码回读不一致`);
  }
  assert.ok(encodeVLQ(480 * 20000).length >= 4, '大 delta 需要多字节');
});

test('MIDI：toMidiBuffer 返回 Node Buffer', () => {
  const score = buildSample();
  const buf = toMidiBuffer(score);
  assert.ok(Buffer.isBuffer(buf));
  assert.deepEqual(Array.from(buf), Array.from(toMidi(score)));
});

test('MIDI：小节时值不足/超出不抛异常', () => {
  const score = createScore({ keyName: 'C', beats: 4, beatType: 4 });
  score.measures.push(measureOf([makeNote(1, 0, 0.25)]));
  score.measures.push(measureOf([makeNote(1, 0, 12)]));
  assert.doesNotThrow(() => toMidi(score));
  assert.equal(measureFilled(score.measures[1]), 12);
  assert.equal(keyInfo('G').xmlFifths, 1);
});

/* ------------------------------------------------------------------ *
 * 端到端：写出文件并回读
 * ------------------------------------------------------------------ */

test('端到端：示例文件可写出、可回读解析', async () => {
  const { toMidiBuffer } = await import('../src/core/midi.js');
  const { mkdtempSync, writeFileSync, readFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');

  const score = buildSample();
  const dir = mkdtempSync(join(tmpdir(), 'jianpu-export-'));
  try {
    const xmlPath = join(dir, 'example.musicxml');
    const midPath = join(dir, 'example.mid');
    writeFileSync(xmlPath, toMusicXML(score), 'utf8');
    writeFileSync(midPath, toMidiBuffer(score));

    // MusicXML 文件应良构，且能从中恢复出结构信息
    const xml = readFileSync(xmlPath, 'utf8');
    const res = checkXmlBalance(xml);
    assert.equal(res.ok, true, res.error);
    assert.equal([...xml.matchAll(/<measure number="\d+">/g)].length, score.measures.length);

    // MIDI 文件应能按 SMF 结构完整走完
    const bytes = new Uint8Array(readFileSync(midPath));
    assert.equal(String.fromCharCode(...bytes.slice(0, 4)), 'MThd');
    const events = parseTrack(bytes);
    const last = events[events.length - 1];
    assert.equal(last.meta, 0x2f);
    assert.ok(bytes[bytes.length - 1] === 0x00 && bytes[bytes.length - 2] === 0x2f);
    assert.ok(events.filter(isOn).length > 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
