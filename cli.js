#!/usr/bin/env node
/**
 * 离谱 · 命令行转换工具（无需 GUI，可批量）
 *
 *   node cli.js 小星星.jianpu                      -> 生成 小星星.musicxml 与 小星星.mid
 *   node cli.js 曲谱/*.jianpu -o out/ --format all
 *   node cli.js in.jianpu --format jianpu -o out.txt   (规范化简谱文本)
 *
 * 输入为简谱文本（语法见 README）；图片识谱请使用 Flutter 应用。
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync, readdirSync } from 'node:fs';
import { basename, extname, join } from 'node:path';
import process from 'node:process';

import { parseJianpu, toJianpu } from './src/core/parse.js';
import { toMusicXML } from './src/core/musicxml.js';
import { toMidi } from './src/core/midi.js';

const HELP = `离谱 命令行工具

用法:
  node cli.js <输入.jianpu|目录> [...] [选项]

选项:
  -o, --out <路径>       输出文件或目录（默认与输入同目录）
  -f, --format <类型>    musicxml | midi | jianpu | all（默认 all）
  -q, --quiet            只输出错误
  -h, --help             显示帮助

示例:
  node cli.js 小星星.jianpu
  node cli.js songs/ -o build/ -f musicxml
`;

function parseArgs(argv) {
  const opts = { inputs: [], out: null, format: 'all', quiet: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') { opts.help = true; }
    else if (a === '-o' || a === '--out') { opts.out = argv[++i]; }
    else if (a === '-f' || a === '--format') { opts.format = (argv[++i] || 'all').toLowerCase(); }
    else if (a === '-q' || a === '--quiet') { opts.quiet = true; }
    else if (!a.startsWith('-')) { opts.inputs.push(a); }
  }
  return opts;
}

function collectInputs(paths) {
  const files = [];
  for (const p of paths) {
    if (!existsSync(p)) {
      console.error(`找不到输入：${p}`);
      continue;
    }
    if (statSync(p).isDirectory()) {
      for (const name of readdirSync(p)) {
        const full = join(p, name);
        if (statSync(full).isFile() && ['.jianpu', '.txt', '.jp'].includes(extname(full).toLowerCase())) {
          files.push(full);
        }
      }
    } else {
      files.push(p);
    }
  }
  return files;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help || opts.inputs.length === 0) {
    console.log(HELP);
    process.exit(opts.help ? 0 : 1);
  }
  const files = collectInputs(opts.inputs);
  if (files.length === 0) {
    console.error('没有可处理的简谱文件');
    process.exit(1);
  }

  // 输出多种格式时 -o 视作目录；只输出一种格式且指定了具体文件时才当作文件
  const singleOutput = opts.format !== 'all';
  const outIsDir = opts.out
    ? (existsSync(opts.out) ? statSync(opts.out).isDirectory() : !singleOutput)
    : false;
  if (outIsDir && !existsSync(opts.out)) mkdirSync(opts.out, { recursive: true });

  let failed = 0;
  for (const file of files) {
    const stem = basename(file, extname(file));
    const dir = opts.out;
    const write = (ext, content) => {
      const target = outIsDir
        ? join(dir, stem + ext)
        : (opts.out && files.length === 1 ? opts.out : join(file, '..', stem + ext));
      writeFileSync(target, content);
      if (!opts.quiet) console.log(`  → ${target}`);
    };

    try {
      const text = readFileSync(file, 'utf8');
      const score = parseJianpu(text);
      if (!opts.quiet) {
        console.log(`\n${file}`);
        console.log(`  调号 ${score.meta.keyName} · ${score.meta.beats}/${score.meta.beatType} · ♩=${score.meta.tempo}`
          + ` · ${score.measures.length} 小节 · ${score.measures.reduce((a, m) => a + m.items.filter((i) => i.kind === 'note').length, 0)} 个音`);
        for (const w of score.meta.warnings) console.log(`  ! ${w}`);
      }
      const fmt = opts.format;
      if (fmt === 'all' || fmt === 'musicxml') write('.musicxml', toMusicXML(score));
      if (fmt === 'all' || fmt === 'midi') write('.mid', Buffer.from(toMidi(score)));
      if (fmt === 'all' || fmt === 'jianpu') write('.normalized.jianpu', toJianpu(score));
    } catch (e) {
      failed++;
      console.error(`${file}: 转换失败 -> ${e.message}`);
    }
  }
  if (!opts.quiet) console.log(`\n完成：${files.length - failed} 个成功，${failed} 个失败`);
  process.exit(failed > 0 ? 1 : 0);
}

main();
