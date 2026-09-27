/**
 * 生成可人工检查的示例文件：
 *   samples/example.musicxml
 *   samples/example.mid
 * 运行：node test/make-samples.mjs
 */

import { writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { createScore, createMeasure, makeNote, makeRest } from '../src/core/model.js';
import { toMusicXML } from '../src/core/musicxml.js';
import { toMidiBuffer } from '../src/core/midi.js';

/** createMeasure 不接受 items 选项，这里补一个便捷构造 */
function measureOf(items, opts = {}) {
  const m = createMeasure(opts);
  m.items = items;
  return m;
}

/** 4 小节示例：1=G，4/4，含十六分/附点/延音线/休止/反复/歌词/变音 */
function buildExample() {
  const score = createScore({
    title: '示例旋律',
    composer: 'Lipu',
    lyricist: '佚名',
    keyName: 'G',
    beats: 4,
    beatType: 4,
    tempo: 100,
  });

  // 第 1 小节：四分 | 十六 十六 十六 十六 | 四分 | 十六 十六 十六 十六
  score.measures.push(
    measureOf([
      makeNote(1, 0, 1, { lyric: '一' }),
      makeNote(2, 0, 0.25, { lyric: '闪' }),
      makeNote(3, 0, 0.25, { lyric: '一' }),
      makeNote(4, 0, 0.25, { lyric: '闪' }),
      makeNote(5, 0, 0.25, { lyric: '亮' }),
      makeNote(1, 0, 1, { lyric: '晶' }),
      makeNote(1, 0, 0.25, { lyric: '晶' }),
      makeNote(3, 0, 0.25, { lyric: '哟' }),
      makeNote(5, 0, 0.25, { lyric: '哟' }),
      makeNote(7, 0, 0.25, { accidental: 'n', lyric: '哟' }), // G 大调需写还原号
    ])
  );

  // 第 2 小节：附点十六+三十二分 十六 十六 | 十六×4 | 八分 四分 八分（末音延到下一小节）
  score.measures.push(
    measureOf([
      makeNote(1, 0, 0.375, { lyric: '满' }),
      makeNote(2, 0, 0.125, { lyric: '天' }),
      makeNote(3, 0, 0.25, { lyric: '的' }),
      makeNote(4, 0, 0.25, { accidental: '#', lyric: '星' }), // C#5
      makeNote(5, 0, 0.25, { lyric: '星' }),
      makeNote(6, 0, 0.25, { lyric: '呀' }),
      makeNote(7, 0, 0.25, { accidental: 'n', lyric: '挂' }),
      makeNote(5, 0, 0.25, { lyric: '在' }),
      makeNote(5, 0, 0.5, { lyric: '天' }),
      makeNote(5, 0, 1, { lyric: '上' }),
      makeNote(5, 0, 0.5, { tieToNext: true, lyric: '闪' }),
    ])
  );

  // 第 3 小节：首音承接上一小节延音线
  score.measures.push(
    measureOf([
      makeNote(5, 0, 0.25, { tieToPrev: true, lyric: '亮' }),
      makeNote(6, 0, 0.25, { lyric: '挂' }),
      makeNote(7, 0, 0.25, { lyric: '在' }),
      makeNote(1, 1, 0.25, { lyric: '天' }),
      makeNote(2, 1, 1, { lyric: '上' }),
      makeNote(1, 1, 0.5, { lyric: '闪' }),
      makeRest(1),
      makeNote(1, 0, 0.5, { lyric: '亮' }),
    ])
  );

  // 第 4 小节：反复记号 + 终止线
  score.measures.push(
    measureOf(
      [
        makeNote(3, 0, 1, { lyric: '挂' }),
        makeNote(2, 0, 1, { lyric: '在' }),
        makeNote(1, 0, 0.5, { accidental: 'b', lyric: '天' }), // Gb4，需写降号
        makeRest(1.5),
      ],
      { repeatStart: true, repeatEnd: true, final: true }
    )
  );

  return score;
}

const score = buildExample();
const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, '..', 'samples');
mkdirSync(outDir, { recursive: true });

const xmlPath = join(outDir, 'example.musicxml');
const midPath = join(outDir, 'example.mid');
writeFileSync(xmlPath, toMusicXML(score), 'utf8');
writeFileSync(midPath, toMidiBuffer(score));

console.log(`已写出：${xmlPath}`);
console.log(`已写出：${midPath}`);
console.log(`小节数：${score.measures.length}，MusicXML ${toMusicXML(score).length} 字节，MIDI ${toMidiBuffer(score).length} 字节`);
