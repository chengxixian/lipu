/**
 * 标准 MIDI 文件（SMF format 0，单轨）导出
 *
 * 输入：Score IR（见 ./model.js）
 * 输出：Uint8Array / Node Buffer
 *
 * 时值换算约定：
 *   IR ticks 以四分音符 = 1；SMF division 取 480（ticks per quarter note）。
 *   所有 delta time 用 7-bit 可变长量（VLQ）编码。
 */

import { keyInfo, noteToPitch } from './model.js';

/** 每四分音符的 MIDI tick 数（SMF division） */
export const TICKS_PER_QUARTER = 480;

const TRACK_NAME = 'Lipu';

/**
 * 7-bit VLQ 编码
 * 0 -> [0x00]；127 -> [0x7F]；128 -> [0x81,0x00]；8192 -> [0xC0,0x00]
 * @param {number} value 非负整数
 * @returns {number[]}
 */
export function encodeVLQ(value) {
  let v = Math.max(0, Math.floor(value));
  const out = [v & 0x7f];
  v >>>= 7;
  while (v > 0) {
    out.unshift((v & 0x7f) | 0x80);
    v >>>= 7;
  }
  return out;
}

/** 把字节数组写入动态数组 */
function pushBytes(arr, bytes) {
  for (const b of bytes) arr.push(b & 0xff);
}

/** 大端 16 位 */
function pushU16(arr, v) {
  arr.push((v >> 8) & 0xff, v & 0xff);
}

/** 大端 32 位 */
function pushU32(arr, v) {
  arr.push((v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff);
}

/** 把带绝对时间的轨道事件（meta/sysex + MIDI 消息）序列化为 MTrk 数据 */
function serializeTrack(events) {
  const data = [];
  let last = 0;
  for (const ev of events) {
    const t = Math.max(last, Math.round(ev.tick));
    pushBytes(data, encodeVLQ(t - last));
    last = t;
    pushBytes(data, ev.bytes);
  }
  // end of track（与上一事件同刻，delta = 0）
  pushBytes(data, encodeVLQ(0));
  pushBytes(data, [0xff, 0x2f, 0x00]);
  return data;
}

/**
 * Score -> 标准 MIDI 文件字节（format 0，单轨）
 * @param {object} score Score IR
 * @param {object} [opts] { velocity, trackName, program }
 * @returns {Uint8Array}
 */
export function toMidi(score, opts = {}) {
  if (!score || !score.meta || !Array.isArray(score.measures)) {
    throw new TypeError('toMidi: 需要合法的 Score IR（meta + measures）');
  }
  const meta = score.meta;
  const ki = keyInfo(meta.keyName);
  const velocity = Number.isFinite(opts.velocity) ? Math.max(1, Math.min(127, Math.round(opts.velocity))) : 100;
  const program = Number.isFinite(opts.program) ? Math.max(0, Math.min(127, Math.round(opts.program))) : 0;

  const ptt = TICKS_PER_QUARTER; // 每四分音符 tick 数
  const toMidiTicks = (t) => Math.round((Number(t) || 0) * ptt);

  /* ---------------- 头部 meta 事件 ---------------- */
  const head = [];
  let abs = 0;
  const pushMeta = (bytes) => head.push({ tick: abs, bytes });

  // track name
  pushMeta([0xff, 0x03, TRACK_NAME.length, ...Array.from(TRACK_NAME, (c) => c.charCodeAt(0))]);

  // tempo：微秒/四分音符（3 字节大端）
  const bpm = Number.isFinite(meta.tempo) && meta.tempo > 0 ? meta.tempo : 96;
  const usPerQuarter = Math.max(1, Math.round(60000000 / bpm));
  pushMeta([0xff, 0x51, 0x03, (usPerQuarter >> 16) & 0xff, (usPerQuarter >> 8) & 0xff, usPerQuarter & 0xff]);

  // time signature：numerator, 2^denominator, midi-clocks/click, 32nds/quarter
  const beats = Math.max(1, Math.round(meta.beats || 4));
  const beatType = Math.max(1, Math.round(meta.beatType || 4));
  const denPow = Math.max(0, Math.round(Math.log2(beatType)));
  const clocksPerMetronome = Math.max(1, Math.round(24 * (4 / beatType)));
  pushMeta([0xff, 0x58, 0x04, beats & 0xff, denPow, clocksPerMetronome, 8]);

  // key signature：有符号字节（负数为降号数），第二字节 0=major / 1=minor
  const fifths = ki.xmlFifths | 0;
  pushMeta([0xff, 0x59, 0x02, fifths < 0 ? fifths + 256 : fifths, meta.mode === 'minor' ? 1 : 0]);

  // program change（在 0 时刻）
  head.push({ tick: abs, bytes: [0xc0 | 0x00, program] });

  /* ---------------- 音符事件 ---------------- */
  /** @type {{tick:number, on:boolean, pitch:number}[]} */
  const notes = [];
  /** 当前打开的发音（连音线合并目标） */
  let active = null; // { pitch, startTick, endTick }

  const flush = () => {
    if (!active) return;
    notes.push({ tick: active.startTick, on: true, pitch: active.pitch });
    notes.push({ tick: active.endTick, on: false, pitch: active.pitch });
    active = null;
  };

  for (const measure of score.measures) {
    for (const item of measure.items || []) {
      const ticks = Number(item.ticks) || 0;
      if (item.kind === 'rest') {
        // 休止符：仅推进时间（前一个音已在其符号结束时收尾）
        abs += toMidiTicks(ticks);
        continue;
      }
      if (item.kind !== 'note') continue;

      const len = toMidiTicks(ticks);
      const pitch = noteToPitch(item, ki).midi;

      if (item.tieToPrev && active) {
        // 连音线延续：不重新触发 note-on，只延长前一个音
        active.endTick += len;
        abs += len;
        if (!item.tieToNext) flush();
        continue;
      }

      // 前一个音未闭合（异常 IR：缺 tieToPrev），先收尾
      flush();
      active = { pitch, startTick: abs, endTick: abs + len };
      abs += len;
      if (!item.tieToNext) flush();
    }
  }
  flush();

  // 同刻事件：note-off 先于 note-on，避免同音高被立刻关掉
  notes.sort((a, b) => (a.tick - b.tick) || (a.on === b.on ? (a.pitch - b.pitch) : (a.on ? 1 : -1)));

  const track = head.slice();
  for (const n of notes) {
    if (n.on) {
      track.push({ tick: n.tick, bytes: [0x90, n.pitch & 0x7f, velocity] });
    } else {
      // 统一用 note-on velocity 0 作为 note-off，兼容性最好
      track.push({ tick: n.tick, bytes: [0x90, n.pitch & 0x7f, 0x00] });
    }
  }

  const trk = serializeTrack(track);

  /* ---------------- 组装 MThd + MTrk ---------------- */
  const out = [];
  pushBytes(out, [0x4d, 0x54, 0x68, 0x64]); // 'MThd'
  pushU32(out, 6);
  pushU16(out, 0); // format 0
  pushU16(out, 1); // ntrks
  pushU16(out, TICKS_PER_QUARTER);
  pushBytes(out, [0x4d, 0x54, 0x72, 0x6b]); // 'MTrk'
  pushU32(out, trk.length);
  pushBytes(out, trk);
  return Uint8Array.from(out);
}

/**
 * 同 toMidi，但返回 Node Buffer
 * @returns {Buffer}
 */
export function toMidiBuffer(score, opts = {}) {
  if (typeof Buffer === 'undefined') {
    throw new Error('toMidiBuffer 需要 Node 运行环境（Buffer 不可用）');
  }
  return Buffer.from(toMidi(score, opts));
}
