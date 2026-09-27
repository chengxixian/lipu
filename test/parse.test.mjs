import test from 'node:test';
import assert from 'node:assert/strict';
import { parseJianpu, toJianpu } from '../src/core/parse.js';
import {
  keyInfo, parseKeySpec, noteToPitch, notateTicks, measureTicks, degreeToMidi, spellMidi,
} from '../src/core/model.js';

test('调号解析', () => {
  assert.deepEqual(pick(parseKeySpec('C')), { letter: 'C', alter: 0, mode: 'major' });
  assert.deepEqual(pick(parseKeySpec('G')), { letter: 'G', alter: 0, mode: 'major' });
  assert.deepEqual(pick(parseKeySpec('#F')), { letter: 'F', alter: 1, mode: 'major' });
  assert.deepEqual(pick(parseKeySpec('bB')), { letter: 'B', alter: -1, mode: 'major' });
  assert.deepEqual(pick(parseKeySpec('Bb')), { letter: 'B', alter: -1, mode: 'major' });
  assert.deepEqual(pick(parseKeySpec('♭B')), { letter: 'B', alter: -1, mode: 'major' });
  assert.deepEqual(pick(parseKeySpec('Am')), { letter: 'A', alter: 0, mode: 'minor' });
  assert.deepEqual(pick(parseKeySpec('a小调')), { letter: 'A', alter: 0, mode: 'minor' });
  assert.deepEqual(pick(parseKeySpec('C大调')), { letter: 'C', alter: 0, mode: 'major' });
});

function pick(k) { return { letter: k.letter, alter: k.alter, mode: k.mode }; }

test('调号 -> 五线谱升降号数量', () => {
  assert.equal(keyInfo('C').xmlFifths, 0);
  assert.equal(keyInfo('G').xmlFifths, 1);
  assert.equal(keyInfo('D').xmlFifths, 2);
  assert.equal(keyInfo('F').xmlFifths, -1);
  assert.equal(keyInfo('bB').xmlFifths, -2);
  assert.equal(keyInfo('Am').xmlFifths, 0);
  assert.equal(keyInfo('Em').xmlFifths, 1);
});

test('音级 -> MIDI 与拼写', () => {
  const C = keyInfo('C');
  assert.equal(degreeToMidi(1, 0, '', C), 60);   // C4
  assert.equal(degreeToMidi(5, 0, '', C), 67);   // G4
  assert.equal(degreeToMidi(1, 1, '', C), 72);   // 上八度
  assert.equal(degreeToMidi(1, -1, '', C), 48);  // 下八度
  assert.equal(degreeToMidi(4, 0, '#', C), 66);  // #4 = F#4
  assert.equal(degreeToMidi(7, 0, 'b', C), 70);  // b7 = Bb4

  const G = keyInfo('G');
  assert.equal(degreeToMidi(1, 0, '', G), 67);   // G4
  assert.equal(degreeToMidi(7, 0, '', G), 78);   // F#5
  const p = noteToPitch({ degree: 7, octave: 0, accidental: '' }, G);
  assert.deepEqual([p.letter, p.alter, p.octave, p.vexKey], ['F', 1, 5, 'f#/5']);

  const F = keyInfo('F');
  const bb = noteToPitch({ degree: 4, octave: 0, accidental: '' }, F);
  assert.deepEqual([bb.letter, bb.alter, bb.octave, bb.vexKey], ['B', -1, 4, 'bb/4']);
});

test('spellMidi 边界', () => {
  assert.deepEqual(s(spellMidi(61, 0)), { letter: 'C', alter: 1, octave: 4 });
  assert.deepEqual(s(spellMidi(59, 6)), { letter: 'B', alter: 0, octave: 3 });
  assert.deepEqual(s(spellMidi(70, 6)), { letter: 'B', alter: -1, octave: 4 });
  function s(p) { return { letter: p.letter, alter: p.alter, octave: p.octave }; }
});

test('时值拆分', () => {
  assert.deepEqual(notateTicks(4, 0, 1).map(x => [x.type, x.dots, x.tieToNext]), [['w', 0, false]]);
  assert.deepEqual(notateTicks(3, 0, 1).map(x => [x.type, x.dots]), [['h', 1]]);
  assert.deepEqual(notateTicks(1.5, 0, 1).map(x => [x.type, x.dots]), [['q', 1]]);
  // 从第 2 拍起、跨拍的 3 拍：切分为 1 + 2
  const seg = notateTicks(3, 1, 1);
  assert.equal(seg.length, 2);
  assert.equal(seg.reduce((a, b) => a + b.ticks, 0), 3);
  assert.equal(seg[0].tieToNext, true);
  // 弱起位置的八分音符
  assert.deepEqual(notateTicks(0.5, 0.5, 1).map(x => x.type), ['8']);
});

test('解析简单谱例', () => {
  const score = parseJianpu(`
标题：小星星
1=C 4/4 ♩=96
1 1 5 5 | 6 6 5 - | 4 4 3 3 | 2 2 1 - |]
`);
  assert.equal(score.meta.title, '小星星');
  assert.equal(score.meta.keyName, 'C');
  assert.equal(score.meta.beats, 4);
  assert.equal(score.meta.tempo, 96);
  assert.equal(score.measures.length, 4);
  assert.equal(score.measures[0].items.length, 4);
  assert.equal(score.measures[1].items.length, 3);
  assert.equal(score.measures[1].items[2].ticks, 2);   // 5 - 合并成一个二分音符
  assert.equal(score.measures[3].final, true);
  assert.equal(score.meta.warnings.length, 0);
});

test('解析八度/减时线/附点/变音/休止', () => {
  const score = parseJianpu(`1=G 4/4
1' 7, #4 b7 | 1/ 2// 3/. 0 |]`);
  const ki = keyInfo('G');
  const m0 = score.measures[0];
  assert.equal(m0.items[0].octave, 1);
  assert.equal(m0.items[1].octave, -1);
  assert.equal(m0.items[2].accidental, '#');
  assert.equal(m0.items[3].accidental, 'b');
  const m1 = score.measures[1];
  assert.equal(m1.items[0].ticks, 0.5);
  assert.equal(m1.items[1].ticks, 0.25);
  assert.equal(m1.items[2].ticks, 0.75);
  assert.equal(m1.items[3].kind, 'rest');
  assert.equal(measureTicks(4, 4), 4);
  assert.deepEqual(m1.items[0].ticks + m1.items[1].ticks, 0.75);
  assert.equal(noteToPitch(m0.items[0], ki).midi, 79); // 1' in G = G5
});

test('连音线与反复记号', () => {
  const score = parseJianpu(`1=C 4/4
|: 1 2 (3 3) | 6~ 6 - - :|]`);
  const m0 = score.measures[0];
  assert.equal(m0.repeatStart, true);
  const a = m0.items[2], b = m0.items[3];
  assert.equal(a.tieToNext, true);
  assert.equal(b.tieToPrev, true);
  const m1 = score.measures[1];
  assert.equal(m1.items[0].tieToNext, true);
  assert.equal(m1.items[1].tieToPrev, true);
  assert.equal(m1.repeatEnd, true);
  assert.equal(score.meta.warnings.length, 0);
});

test('小节时值异常给出告警但不丢音', () => {
  const score = parseJianpu('1=C 4/4\n1 2 3 4 5 | 1 2 3 4 |]');
  assert.ok(score.meta.warnings.length > 0);
  const total = score.measures.reduce((a, m) => a + m.items.length, 0);
  assert.ok(total >= 9);
});

test('文本回写往返一致', () => {
  const src = `1=G 4/4 ♩=88
5 5 6 5 | 1' 7 1' - | 4/ 4/ 3 2 | 1 - - - |]`;
  const score = parseJianpu(src);
  const text = toJianpu(score);
  const again = parseJianpu(text);
  const flat = (s) => s.measures.map(m => m.items.map(i => [i.kind, i.degree, i.octave, i.accidental, i.ticks].join(':')).join(','));
  assert.deepEqual(flat(again), flat(score));
  assert.equal(again.meta.keyName, score.meta.keyName);
});
