#!/usr/bin/env node
/**
 * 生成 App 内置的钢琴采样（真实录音，非合成）。
 *
 * 音源：Salamander Grand Piano V6.2 "Accurate"（Yamaha C5，立体声近距离录音）
 *       许可证 CC-BY-3.0 —— 作者 Alexander Holm，转存于 HuggingFace 数据集
 *       EinWWW/Accurate-Salamander-Grand-Piano-Yamaha-C5
 *       原始：48kHz / 24bit / 立体声 / 从小字组 A 起每小三度一个音 / 16 个力度层
 *
 * 转换后：44.1kHz / 16bit / 单声道 / 截取 1.7~3.0 秒 + 等功率交叉淡化循环点
 *        （循环长度对齐到基频整数个周期，避免接缝处相位抵消）
 *
 * 用法：
 *   node tool/fetch_piano_samples.mjs              # 全部 30 个音
 *   node tool/fetch_piano_samples.mjs --limit 3    # 只做前 3 个（调试）
 *   node tool/fetch_piano_samples.mjs --vel 10     # 指定力度层 1..16（默认 8）
 *   node tool/fetch_piano_samples.mjs --force      # 忽略缓存重新下载
 *
 * 输出：app/assets/piano/*.wav + app/assets/piano/manifest.json
 * 下载缓存：app/tool/.cache/piano/（可随时删除）
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP = path.resolve(HERE, '..');
const OUT_DIR = path.join(APP, 'assets', 'piano');
const CACHE_DIR = path.join(HERE, '.cache', 'piano');

const HF_BASE =
  'https://huggingface.co/datasets/EinWWW/Accurate-Salamander-Grand-Piano-Yamaha-C5/resolve/main/' +
  'AccurateSalamanderGrandPianoV6.2beta2_48khz24bit/48khz24bit/';

const LICENCE = 'CC-BY-3.0';
const ATTRIBUTION =
  'Salamander Grand Piano V6.2 (Yamaha C5) by Alexander Holm — CC-BY-3.0';
const SOURCE_URL = 'https://huggingface.co/datasets/EinWWW/Accurate-Salamander-Grand-Piano-Yamaha-C5';

const OUT_RATE = 44100;
const TARGET_PEAK = 0.99;

// 采样点：A0(21) 起每小三度一个音，到 C8(108)
const NOTES = [];
for (let m = 21; m <= 108; m += 3) NOTES.push(m);

const NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const noteName = (m) => `${NAMES[m % 12]}${Math.floor(m / 12) - 1}`;

/** 每个音截取多长、循环段多长（秒）：低音共鸣长，高音衰减快 */
function windowSec(midi) {
  if (midi < 48) return { total: 3.0, loop: 1.1 };
  if (midi < 72) return { total: 2.4, loop: 0.9 };
  return { total: 1.7, loop: 0.7 };
}

// ---------------------------------------------------------------- WAV 读取

function readWav(buf) {
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error('不是 WAV 文件');
  }
  let off = 12;
  let fmt = null;
  let data = null;
  while (off + 8 <= buf.length) {
    const id = buf.toString('ascii', off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    const body = off + 8;
    if (id === 'fmt ') {
      fmt = {
        format: buf.readUInt16LE(body),
        channels: buf.readUInt16LE(body + 2),
        sampleRate: buf.readUInt32LE(body + 4),
        bits: buf.readUInt16LE(body + 14),
      };
    } else if (id === 'data') {
      data = { offset: body, size: Math.min(size, buf.length - body) };
    }
    off = body + size + (size % 2);
  }
  if (!fmt || !data) throw new Error('WAV 缺少 fmt/data 块');
  return { fmt, data };
}

/** 解码成单声道 Float32（立体声取平均） */
function decodeMono(buf, fmt, data) {
  const bytes = fmt.bits / 8;
  const frames = Math.floor(data.size / (bytes * fmt.channels));
  const out = new Float32Array(frames);
  let p = data.offset;
  for (let i = 0; i < frames; i++) {
    let acc = 0;
    for (let c = 0; c < fmt.channels; c++) {
      let v;
      if (bytes === 3) {
        v = (buf.readUInt8(p) | (buf.readUInt8(p + 1) << 8) | (buf.readInt8(p + 2) << 16)) / 8388608;
      } else if (bytes === 2) {
        v = buf.readInt16LE(p) / 32768;
      } else if (bytes === 4) {
        v = buf.readInt32LE(p) / 2147483648;
      } else {
        throw new Error(`不支持的位深 ${fmt.bits}`);
      }
      acc += v;
      p += bytes;
    }
    out[i] = acc / fmt.channels;
  }
  return out;
}

// ---------------------------------------------------------------- 重采样

const blackman = (x, half) =>
  0.42 + 0.5 * Math.cos((Math.PI * x) / half) + 0.08 * Math.cos((2 * Math.PI * x) / half);

/** 带限 sinc 重采样（Blackman 窗，16 个旁瓣） */
function resample(input, inRate, outRate) {
  if (inRate === outRate) return input;
  const ratio = outRate / inRate;
  const outLen = Math.floor(input.length * ratio);
  const out = new Float32Array(outLen);
  const half = 16;
  const cutoff = Math.min(1, ratio) * 0.94;
  for (let i = 0; i < outLen; i++) {
    const center = i / ratio;
    const j0 = Math.max(0, Math.ceil(center - half));
    const j1 = Math.min(input.length - 1, Math.floor(center + half));
    let acc = 0;
    let wsum = 0;
    for (let j = j0; j <= j1; j++) {
      const x = (j - center) * cutoff;
      const s = x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
      const w = s * blackman(x, half);
      acc += input[j] * w;
      wsum += w;
    }
    out[i] = wsum !== 0 ? acc / wsum : 0;
  }
  return out;
}

// ---------------------------------------------------------------- 频谱

function fftInPlace(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang);
    const wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1;
      let ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur = re[i + k];
        const ui = im[i + k];
        const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr;
        im[i + k + len / 2] = ui - vi;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

function spectrum(x, from, len) {
  let n = 1;
  while (n < len) n <<= 1;
  const re = new Float64Array(n);
  const im = new Float64Array(n);
  for (let i = 0; i < len; i++) {
    const t = i < len;
    const w = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (len - 1));
    re[i] = (from + i < x.length ? x[from + i] : 0) * (t ? w : 0);
  }
  fftInPlace(re, im);
  const half = n >> 1;
  const mag = new Float64Array(half);
  for (let i = 0; i < half; i++) mag[i] = Math.hypot(re[i], im[i]);
  return { mag, n };
}

/** 抛物线插值的局部谱峰 */
function findPeaks(mag, n, rate, lo, hi, floorRatio) {
  const binHz = rate / n;
  const a = Math.max(2, Math.floor(lo / binHz));
  const b = Math.min(mag.length - 2, Math.ceil(hi / binHz));
  let maxM = 1e-30;
  for (let i = a; i <= b; i++) maxM = Math.max(maxM, mag[i]);
  const out = [];
  for (let i = a; i <= b; i++) {
    if (mag[i] > mag[i - 1] && mag[i] >= mag[i + 1] && mag[i] >= maxM * floorRatio) {
      const y0 = mag[i - 1];
      const y1 = mag[i];
      const y2 = mag[i + 1];
      const den = y0 - 2 * y1 + y2;
      const d = den !== 0 ? (0.5 * (y0 - y2)) / den : 0;
      out.push({ f: (i + d) * binHz, m: y1 });
    }
  }
  return out;
}

/**
 * 估计基频（用于循环点对齐与音准校正）。
 *
 * 低音的基频很弱（A0 的基频比第 3 分音低 20dB），直接找峰会失败；
 * 而分音因为钢琴的刚性弦有"伸张"，高次分音偏高。做法：把每个谱峰都
 * 当作"第 h 分音"折算出基频，取其中最可信的一个：
 *   - 偏差必须在 ±60 音分内（真实钢琴伸张曲线不会超过这个范围）
 *   - 同样可信时优先低次分音（高次分音被伸张拉偏）
 * 这样 A0 会得到 27.19Hz（=-19.6¢，正是低音区应有的伸张）。
 */
function estimateF0(x, rate, midi) {
  const expected = 440 * Math.pow(2, (midi - 69) / 12);
  const len = Math.min(x.length, Math.floor(rate * 2.5));
  const { mag, n } = spectrum(x, 0, len);
  const peaks = findPeaks(mag, n, rate, expected * 0.9, Math.min(6000, rate / 2 - 200), 0.03);
  let best = null;
  for (const p of peaks) {
    const h = Math.max(1, Math.round(p.f / expected));
    if (h > 8) continue;
    const f0 = p.f / h;
    const cents = Math.abs(1200 * Math.log2(f0 / expected));
    if (cents > 60) continue;
    const cost = cents + 8 * (h - 1);
    if (!best || cost < best.cost) best = { f0, h, cost };
  }
  if (best) return { f0: best.f0, how: best.h === 1 ? '基频' : `第${best.h}分音` };
  return { f0: expected, how: '标称值' };
}

// ---------------------------------------------------------------- 处理

function toMono44k(wavBuf) {
  const { fmt, data } = readWav(wavBuf);
  const mono = decodeMono(wavBuf, fmt, data);
  return { mono: resample(mono, fmt.sampleRate, OUT_RATE), inRate: fmt.sampleRate, fmt };
}

/** 去掉开头的静音（保留 1ms 起音前量） */
function trimOnset(x) {
  let peak = 0;
  for (let i = 0; i < x.length; i++) peak = Math.max(peak, Math.abs(x[i]));
  const thr = peak * 0.004;
  let start = 0;
  for (let i = 0; i < x.length; i++) {
    if (Math.abs(x[i]) > thr) {
      start = i;
      break;
    }
  }
  return Math.max(0, start - Math.round(OUT_RATE * 0.001));
}

/**
 * 循环起点的相位对齐：
 * 交叉淡化是把"结尾 fade 个样本"和"循环起点前 fade 个样本"混合，
 * 两段必须是同相位才不会有梳状抵消，所以在 ±半周期内微调循环起点，
 * 取两段归一化相关最大的位置。
 */
function alignLoop(out, loopStart, fade, period) {
  const half = Math.max(1, Math.round(period / 2));
  let best = loopStart;
  let bestR = -Infinity;
  for (let d = -half; d <= half; d++) {
    const s = loopStart + d;
    if (s - fade < 0 || s + fade > out.length) continue;
    let num = 0;
    let d1 = 0;
    let d2 = 0;
    for (let i = 0; i < fade; i++) {
      const a = out[out.length - fade + i];
      const b = out[s - fade + i];
      num += a * b;
      d1 += a * a;
      d2 += b * b;
    }
    const r = num / Math.sqrt(d1 * d2 || 1e-30);
    if (r > bestR) {
      bestR = r;
      best = s;
    }
  }
  return best;
}

/**
 * 处理一个音：
 *   截取 -> 归一化相对响度（全局） -> 交叉淡化循环点
 * 循环点做法：把结尾 X 个样本与"循环起点前 X 个样本"等功率混合，
 * 使结尾自然衔接回循环起点；循环长度取基频整数个周期，保证相位对齐。
 */
function processNote(x, midi, f0) {
  const { total, loop } = windowSec(midi);
  const start = trimOnset(x);
  const frames = Math.min(x.length - start, Math.round(total * OUT_RATE));
  const out = Float32Array.from(x.subarray(start, start + frames));

  // 相对响度：整首曲子共用同一个系数，保留钢琴本身的强弱关系
  let peak = 0;
  for (let i = 0; i < out.length; i++) peak = Math.max(peak, Math.abs(out[i]));

  // 循环长度对齐到整数个周期
  const period = OUT_RATE / f0;
  const wantLoop = Math.round(loop * OUT_RATE);
  const periods = Math.max(2, Math.round(wantLoop / period));
  let loopLen = Math.round(periods * period);
  loopLen = Math.min(loopLen, out.length - Math.round(OUT_RATE * 0.15));
  const fade = Math.min(Math.round(OUT_RATE * 0.12), Math.floor(loopLen / 4));
  let loopStart = alignLoop(out, out.length - loopLen, fade, period);
  loopLen = out.length - loopStart;

  for (let i = 0; i < fade; i++) {
    const t = i / fade;
    const w = Math.sin((t * Math.PI) / 2); // 等功率
    const a = out.length - fade + i;
    const b = loopStart - fade + i;
    out[a] = out[a] * (1 - w) + out[b] * w;
  }
  return { pcm: out, peak, loopStart, loopEnd: out.length, loopLen, frames };
}

function writeWav16(pcm, rate) {
  const data = Buffer.alloc(pcm.length * 2);
  for (let i = 0; i < pcm.length; i++) {
    const v = Math.max(-32768, Math.min(32767, Math.round(pcm[i] * 32767)));
    data.writeInt16LE(v, i * 2);
  }
  const head = Buffer.alloc(44);
  head.write('RIFF', 0, 'ascii');
  head.writeUInt32LE(36 + data.length, 4);
  head.write('WAVE', 8, 'ascii');
  head.write('fmt ', 12, 'ascii');
  head.writeUInt32LE(16, 16);
  head.writeUInt16LE(1, 20);
  head.writeUInt16LE(1, 22);
  head.writeUInt32LE(rate, 24);
  head.writeUInt32LE(rate * 2, 28);
  head.writeUInt16LE(2, 32);
  head.writeUInt16LE(16, 34);
  head.write('data', 36, 'ascii');
  head.writeUInt32LE(data.length, 40);
  return Buffer.concat([head, data]);
}

// ---------------------------------------------------------------- 主流程

async function download(filePath, force) {
  if (!force && fs.existsSync(filePath) && fs.statSync(filePath).size > 100000) return;
  const url = HF_BASE + encodeURIComponent(path.basename(filePath));
  const res = await fetch(url);
  if (!res.ok) throw new Error(`下载失败 ${res.status} ${url}`);
  const buf = Buffer.from(await res.arrayBuffer());
  fs.writeFileSync(filePath, buf);
}

async function main() {
  const argv = process.argv.slice(2);
  const argVal = (name, dflt) => {
    const i = argv.indexOf(name);
    return i >= 0 && argv[i + 1] ? Number(argv[i + 1]) : dflt;
  };
  const limit = argVal('--limit', NOTES.length);
  const vel = argVal('--vel', 8);
  const force = argv.includes('--force');

  fs.mkdirSync(CACHE_DIR, { recursive: true });
  fs.mkdirSync(OUT_DIR, { recursive: true });
  for (const f of fs.readdirSync(OUT_DIR)) {
    if (f.endsWith('.wav')) fs.unlinkSync(path.join(OUT_DIR, f));
  }

  const notes = NOTES.slice(0, limit);
  const processed = [];
  console.log(`力度层 v${String(vel).padStart(2, '0')}，共 ${notes.length} 个音\n`);
  console.log('音名   MIDI  原采样率  时长     峰值dB   基频Hz    音准偏差   循环点');
  console.log('----   ----  --------  -------  -------  --------  ---------  ----------');

  for (const midi of notes) {
    const name = noteName(midi);
    const src = path.join(CACHE_DIR, `${String(midi).padStart(3, '0')}_${name.replace('#', '#')}v${String(vel).padStart(2, '0')}.wav`);
    await download(src, force);
    const { mono, inRate } = toMono44k(fs.readFileSync(src));
    const { f0, how } = estimateF0(mono, OUT_RATE, midi);
    const p = processNote(mono, midi, f0);
    const expected = 440 * Math.pow(2, (midi - 69) / 12);
    const cents = 1200 * Math.log2(f0 / expected);
    const dur = p.frames / OUT_RATE;
    console.log(
      `${name.padEnd(5)}  ${String(midi).padStart(3)}   ${String(inRate).padStart(7)}  ` +
        `${dur.toFixed(2)}s    ${(20 * Math.log10(p.peak || 1e-9)).toFixed(1).padStart(6)}  ` +
        `${f0.toFixed(2).padStart(8)}  ${(cents >= 0 ? '+' : '') + cents.toFixed(1)}¢(${how})  ` +
        `${p.loopStart}~${p.loopEnd}`,
    );
    processed.push({ midi, name, ...p, f0 });
  }

  // 全局归一化：最大峰值对齐到 TARGET_PEAK，保留音与音之间的强弱关系
  let maxPeak = 0;
  for (const p of processed) maxPeak = Math.max(maxPeak, p.peak);
  const gain = maxPeak > 0 ? TARGET_PEAK / maxPeak : 1;

  const manifestNotes = [];
  let totalBytes = 0;
  for (const p of processed) {
    const scaled = Float32Array.from(p.pcm, (v) => v * gain);
    let peak = 0;
    for (let i = 0; i < scaled.length; i++) peak = Math.max(peak, Math.abs(scaled[i]));
    const file = `p${String(p.midi).padStart(3, '0')}_${p.name.replace('#', 's')}.wav`;
    const wav = writeWav16(scaled, OUT_RATE);
    fs.writeFileSync(path.join(OUT_DIR, file), wav);
    totalBytes += wav.length;
    manifestNotes.push({
      midi: p.midi,
      file,
      frames: p.frames,
      loopStart: p.loopStart,
      loopEnd: p.loopEnd,
      freq: Number(p.f0.toFixed(4)),
      peak: Number(peak.toFixed(4)),
    });
  }

  const manifest = {
    version: 1,
    sampleRate: OUT_RATE,
    source: 'Salamander Grand Piano V6.2 (Accurate) — Yamaha C5, Alexander Holm',
    sourceUrl: SOURCE_URL,
    license: LICENCE,
    attribution: ATTRIBUTION,
    velocityLayer: vel,
    notes: manifestNotes,
  };
  fs.writeFileSync(path.join(OUT_DIR, 'manifest.json'), JSON.stringify(manifest, null, 1));

  console.log(
    `\n写出 ${manifestNotes.length} 个采样 -> ${OUT_DIR}\n` +
      `总大小 ${(totalBytes / 1024 / 1024).toFixed(2)} MB（单声道 44.1kHz 16bit）\n` +
      `全局归一化系数 ${gain.toFixed(3)}（原始最大峰值 ${(20 * Math.log10(maxPeak)).toFixed(1)} dBFS）`,
  );
}

main().catch((e) => {
  console.error('失败：', e);
  process.exit(1);
});
