/**
 * ByteDance 高分辨率钢琴转写（CRNN，ONNX）准确率 / 速度探针
 *
 *   node probe.mjs                      # CPU
 *   node probe.mjs --ep dml             # DirectML（Windows 上直接用 N 卡/A 卡，无需装 CUDA）
 *   node probe.mjs --ep webgpu
 *   node probe.mjs --wav 某个.wav       # 只跑一个文件（不给真值时只打印音符）
 *
 * 输入：build/fixtures/chords_*.wav + truth.json（由 app/tool/make_chord_fixtures.dart 生成）
 * 输出：每个和弦的 recall / precision + 逐段耗时，用来和 Basic Pitch 的实测数字对比。
 *
 * 模型 I/O（stelee/piano-transcription-onnx，MIT，Kong et al. 2021）：
 *   输入  audio  float32 [1, 160000]  单声道 16kHz（正好 10 秒）
 *   输出  reg_onset / reg_offset / frame / velocity 各 [1, 1001, 88]（100fps × 88 键，A0=21）
 *         + 踏板相关输出
 * 注意：模型卡明确要求**关掉图优化**跑（ORT 1.20 的 MatMul+BN 融合会把这个图里的
 * rank-3 Gemm 推断错）。
 */
import fs from 'node:fs';
import path from 'node:path';
import { InferenceSession, Tensor } from 'onnxruntime-node';

const SEG = 160000;        // 10 秒 @16kHz
const FRAME_HZ = 100;      // 1001 帧 / 10 秒
const KEY_BASE = 21;       // 第 0 键 = A0 = MIDI 21

const args = process.argv.slice(2);
const getArg = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
};
const ep = getArg('ep', 'cpu');
const modelPath = getArg('model', 'D:/dsh work region/jianpu2staff/third_party/piano_crnn/piano_crnn.onnx');
const fixtureDir = getArg('fixtures', 'D:/dsh work region/jianpu2staff/app/build/fixtures');
const singleWav = getArg('wav', '');

/* ---------------- WAV ---------------- */
function readWav(file) {
  const buf = fs.readFileSync(file);
  let pos = 12, fmt = null, data = null;
  while (pos + 8 <= buf.length) {
    const id = buf.toString('ascii', pos, pos + 4);
    const size = buf.readUInt32LE(pos + 4);
    const body = pos + 8;
    if (id === 'fmt ') {
      fmt = {
        format: buf.readUInt16LE(body),
        channels: buf.readUInt16LE(body + 2),
        sampleRate: buf.readUInt32LE(body + 4),
        bits: buf.readUInt16LE(body + 14),
      };
    } else if (id === 'data') {
      data = buf.subarray(body, body + size);
    }
    pos = body + size + (size % 2);
  }
  if (!fmt || !data) throw new Error(`不是有效 WAV：${file}`);
  const n = Math.floor(data.length / (fmt.bits / 8) / fmt.channels);
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    let acc = 0;
    for (let c = 0; c < fmt.channels; c++) {
      const off = (i * fmt.channels + c) * (fmt.bits / 8);
      acc += fmt.bits === 16 ? data.readInt16LE(off) / 32768 : data.readFloatLE(off);
    }
    out[i] = acc / fmt.channels;
  }
  return { sampleRate: fmt.sampleRate, samples: out };
}

/** 线性重采样到 16k（探针够用；App 里用的是带抗混叠的重采样） */
function resample(samples, from, to) {
  if (from === to) return samples;
  const n = Math.floor((samples.length * to) / from);
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const x = (i * from) / to;
    const i0 = Math.floor(x);
    const i1 = Math.min(i0 + 1, samples.length - 1);
    const f = x - i0;
    out[i] = samples[i0] * (1 - f) + samples[i1] * f;
  }
  return out;
}

/* ---------------- 推理 ---------------- */
let sessionPromise = null;
async function getSession() {
  if (!sessionPromise) {
    sessionPromise = InferenceSession.create(modelPath, {
      // 模型卡要求：关掉图优化（否则 ORT 的 MatMul+BN 融合会推断错这个图）
      graphOptimizationLevel: args.includes('--opt') ? 'all' : 'disabled',
      executionProviders: ep === 'cpu' ? ['cpu'] : [ep, 'cpu'],
      intraOpNumThreads: 4,
    });
  }
  return sessionPromise;
}

let names = null;
async function runSegment(session, audio16k, startSample) {
  if (!names) names = { in: session.inputNames[0], out: session.outputNames };
  const input = new Float32Array(SEG);
  for (let i = 0; i < SEG; i++) {
    const j = startSample + i;
    input[i] = j < audio16k.length ? audio16k[j] : 0;
  }
  const feeds = { [names.in]: new Tensor('float32', input, [1, SEG]) };
  const t0 = performance.now();
  const out = await session.run(feeds);
  const ms = performance.now() - t0;

  const pick = (...cands) => {
    for (const c of cands) {
      for (const k of Object.keys(out)) {
        if (k === c || k.includes(c)) return out[k];
      }
    }
    return null;
  };
  const onset = pick('reg_onset_output', 'reg_onset');
  const offset = pick('reg_offset_output', 'reg_offset');
  const frame = pick('frame_output', 'frame');
  const velocity = pick('velocity_output', 'velocity');
  if (!onset || !offset) {
    throw new Error(`找不到 onset/offset 输出，实际输出：${Object.keys(out).join(', ')}`);
  }
  return {
    ms,
    onset: onset.data,
    offset: offset.data,
    frame: frame ? frame.data : null,
    velocity: velocity ? velocity.data : null,
    dims: onset.dims,
  };
}

/** 回归式解码：onset 用 reg_onset>0.5 的位置、offset 用之后第一个 reg_offset>0.5 */
function decodeNotes(head, segStartSec) {
  const [d0, frames, keys] = head.dims;
  void d0;
  const notes = [];
  for (let k = 0; k < keys; k++) {
    const onsets = [];
    const offsets = [];
    for (let t = 0; t < frames; t++) {
      const idx = t * keys + k;
      if (head.onset[idx] > 0.5) onsets.push(t);
      if (head.offset[idx] > 0.5) offsets.push(t);
    }
    for (const t of onsets) {
      const o = offsets.find((x) => x > t);
      const endFrame = o === undefined ? frames - 1 : o;
      const start = segStartSec + (t + head.onset[t * keys + k]) / FRAME_HZ;
      const end = segStartSec + (endFrame + head.offset[endFrame * keys + k]) / FRAME_HZ;
      if (end - start < 0.02) continue;
      notes.push({
        midi: KEY_BASE + k,
        start,
        end,
        velocity: head.velocity ? head.velocity[t * keys + k] : 0,
      });
    }
  }
  notes.sort((a, b) => a.start - b.start || a.midi - b.midi);
  return notes;
}

const NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const nameOf = (m) => `${NAMES[m % 12]}${Math.floor(m / 12) - 1}`;

/* ---------------- 主流程 ---------------- */
const session = await getSession().catch((e) => {
  console.error(`创建会话失败（EP=${ep}）：${e.message.split('\n')[0]}`);
  process.exit(2);
});
console.log(`模型：${path.basename(modelPath)}   EP：${ep}   ` +
  `输入 ${session.inputNames.join(',')} → 输出 ${session.outputNames.length} 个`);

if (singleWav) {
  const wav = readWav(singleWav);
  const a = resample(wav.samples, wav.sampleRate, 16000);
  const segs = Math.max(1, Math.ceil(a.length / SEG));
  let total = 0;
  const all = [];
  for (let s = 0; s < segs; s++) {
    const head = await runSegment(session, a, s * SEG);
    total += head.ms;
    all.push(...decodeNotes(head, (s * SEG) / 16000));
  }
  console.log(`音频 ${(a.length / 16000).toFixed(1)}s → ${segs} 段，推理共 ${(total / 1000).toFixed(2)}s ` +
    `（实时率 ${(total / 1000 / (a.length / 16000)).toFixed(2)}×），音符 ${all.length} 个`);
  for (const n of all.slice(0, 40)) {
    console.log(`   ${nameOf(n.midi)} ${n.start.toFixed(2)}~${n.end.toFixed(2)}s vel=${n.velocity.toFixed(2)}`);
  }
  process.exit(0);
}

const truthPath = path.join(fixtureDir, 'truth.json');
if (!fs.existsSync(truthPath)) {
  console.error(`缺少真值文件 ${truthPath}，先跑 flutter test test/_make_fixtures_test.dart`);
  process.exit(2);
}
const truth = JSON.parse(fs.readFileSync(truthPath, 'utf8'));

const rows = [];
let sumTp = 0, sumDet = 0, sumTruth = 0, sumMs = 0, sumSec = 0;
for (const [caseName, chords] of Object.entries(truth.cases)) {
  const wav = readWav(path.join(fixtureDir, `chords_${caseName}.wav`));
  const a16 = resample(wav.samples, wav.sampleRate, 16000);
  const head = await runSegment(session, a16, 0);
  sumMs += head.ms;
  sumSec += a16.length / 16000;
  const notes = decodeNotes(head, 0);

  let tp = 0, det = 0, tot = 0;
  const lines = [];
  for (const ch of chords) {
    const win = notes.filter((n) => n.start >= ch.start - 0.25 && n.start <= ch.start + ch.dur * 0.6);
    const found = new Set(win.map((n) => n.midi));
    const want = new Set(ch.midis);
    const hit = [...found].filter((m) => want.has(m));
    const miss = [...want].filter((m) => !found.has(m));
    const extra = [...found].filter((m) => !want.has(m));
    tp += hit.length;
    det += found.size;
    tot += want.size;
    lines.push(`   ${ch.start.toFixed(1)}s [${[...want].map(nameOf).join(' ')}] 检出 ${found.size}：` +
      `${[...found].map(nameOf).join(' ')}` +
      `${miss.length ? `  漏:${miss.map(nameOf).join(',')}` : ''}` +
      `${extra.length ? `  多:${extra.map(nameOf).join(',')}` : ''}`);
  }
  sumTp += tp; sumDet += det; sumTruth += tot;
  const recall = tot ? Math.round((tp / tot) * 100) : 0;
  const precision = det ? Math.round((tp / det) * 100) : 0;
  rows.push(`== ${caseName}：recall=${recall}% precision=${precision}%（真值 ${tot} 音，检出 ${det} 音，命中 ${tp}）`);
  rows.push(...lines);
}
console.log(rows.join('\n'));
const recall = sumTruth ? Math.round((sumTp / sumTruth) * 100) : 0;
const precision = sumDet ? Math.round((sumTp / sumDet) * 100) : 0;
console.log(`\n合计：recall=${recall}%  precision=${precision}%（真值 ${sumTruth}，检出 ${sumDet}，命中 ${sumTp}）`);
console.log(`速度：${(sumMs / 1000).toFixed(2)}s 处理 ${sumSec.toFixed(1)}s 音频 → ` +
  `实时率 ${(sumMs / 1000 / sumSec).toFixed(2)}×（EP=${ep}，单段 10 秒窗口）`);
