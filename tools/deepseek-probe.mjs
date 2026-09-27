/**
 * 用 DeepSeek 的视觉模型测试简谱识谱（临时脚本）
 *   DEEPSEEK_API_KEY=sk-xxx node tools/test-deepseek.mjs 图片路径
 */
import { readFileSync } from 'node:fs';

const key = process.env.DEEPSEEK_API_KEY;
if (!key) {
  console.error('缺少 DEEPSEEK_API_KEY');
  process.exit(1);
}
const imagePath = process.argv[2] || 'app/samples/real/春风吹_p1.jpg';
const bytes = readFileSync(imagePath);
const b64 = bytes.toString('base64');
const mime = imagePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';

const prompt = `你是简谱识谱专家。请把图片里的简谱逐行转写成纯文本，规则：
- 音级用 1-7，休止符用 0；
- 上加点写 '（可叠加），下加点写 ,（可叠加）；
- 减时线（下划线）写成 / ，两条写 //，三条写 ///；
- 延音线（横线）写成 - ，每个 - 表示延长一个四分音符；
- 附点写成 . ；升号写 #，降号写 b，还原号写 n；
- 小节线写 | ，终止线写 |] ，反复记号写 |: 和 :| ；
- 调号/拍号单独一行，写成 1=C 4/4 这样的形式。
只输出简谱文本本身，不要解释、不要 Markdown 代码块。
注意这是一页可能包含上下两条声部的简谱：请分别输出，每条声部一行（或按小节换行），不要混在一起。`;

const body = {
  model: process.env.DEEPSEEK_MODEL || 'deepseek-flash',
  messages: [
    {
      role: 'user',
      content: [
        { type: 'text', text: prompt },
        { type: 'image_url', image_url: { url: `data:${mime};base64,${b64}` } },
      ],
    },
  ],
  temperature: 0,
  max_tokens: Number(process.env.DEEPSEEK_MAX_TOKENS || 16000),
  // 这是推理模型：不限制推理量的话 token 会被推理吃光，正文为空
  ...(process.env.DEEPSEEK_EFFORT ? { reasoning_effort: process.env.DEEPSEEK_EFFORT } : {}),
  ...(process.env.DEEPSEEK_EFFORT_ALT ? { effort: process.env.DEEPSEEK_EFFORT_ALT } : {}),
};

const started = Date.now();
const res = await fetch('https://api.deepseek.com/chat/completions', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
  body: JSON.stringify(body),
});
const text = await res.text();
console.log(`HTTP ${res.status}  用时 ${((Date.now() - started) / 1000).toFixed(1)}s`);
try {
  const json = JSON.parse(text);
  if (json.error) {
    console.log('API 错误:', JSON.stringify(json.error));
  } else {
    const content = json.choices?.[0]?.message?.content ?? '';
    console.log('--- 模型输出 ---');
    console.log(typeof content === 'string' ? content : JSON.stringify(content));
    console.log('--- 用量 ---', JSON.stringify(json.usage ?? {}));
  }
} catch {
  console.log('原始返回:', text.slice(0, 800));
}
