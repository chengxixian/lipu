"""Tsumugi（神经半-CRF，乐器无关转写）能不能接进 App？—— 可行性验证脚本。

    .venv\\Scripts\\python.exe probe_tsumugi.py

回答三个问题：
  1. 权重能不能在 CPU 上加载？（best_model.pth 53.5MB）
  2. `AudioSemiCRFTransformer.forward()` 到底返回什么？有没有"纯神经网络"的那一段
     （帧级 emissions / 区间打分），能不能单独 trace 出来导出 ONNX？
  3. 半-CRF 的解码是不是必须留在 Python 里（动态规划 / Triton / 数据相关控制流）？

结论会直接决定要不要走"只导出骨干 + 在 Dart 里重写 DP"这条路。
"""

from __future__ import annotations

import sys
import traceback
from pathlib import Path

import torch

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "third_party" / "tsumugi_src" / "anime-song-tsumugi-020edc1"
CKPT = ROOT / "third_party" / "tsumugi" / "best_model.pth"

sys.path.insert(0, str(SRC))

print(f"torch {torch.__version__}  checkpoint {CKPT.name} "
      f"({CKPT.stat().st_size / 1048576:.1f}MB)" if CKPT.exists() else f"缺少 {CKPT}")
if not CKPT.exists():
    raise SystemExit(2)

# ---- 1. 加载权重 ----
raw = torch.load(str(CKPT), map_location="cpu", weights_only=False)
print(f"\n[1] checkpoint 顶层键：{list(raw.keys())[:12]}")

state = None
for key in ("model", "state_dict", "model_state_dict", "model_state"):
    if isinstance(raw.get(key), dict):
        state = raw[key]
        print(f"    权重在 raw['{key}']，共 {len(state)} 个张量")
        break
if state is None and all(torch.is_tensor(v) for v in raw.values()):
    state = raw
    print(f"    checkpoint 本身就是 state_dict，共 {len(state)} 个张量")
if state is None:
    raise SystemExit("找不到权重字典")

total = sum(v.numel() for v in state.values() if torch.is_tensor(v))
print(f"    参数量约 {total / 1e6:.1f}M；前 8 个键：{list(state.keys())[:8]}")

# ---- 2. 建模并加载（用仓库自己的 checkpoint 工具，别自己拼 config）----
from instrument_agnostic_amt.amt.modeling.checkpoints import (  # noqa: E402
    coerce_model_config,
    extract_model_config,
    select_state_dict,
)
from instrument_agnostic_amt.amt.modeling.model import AudioSemiCRFTransformer  # noqa: E402

print("\n[2] 用仓库的 extract/coerce 拿 config")
raw_cfg = extract_model_config(raw)
print(f"    model_config 字段：{list(raw_cfg.keys())[:20]}")
cfg = coerce_model_config(raw_cfg)
print(f"    sample_rate={cfg.sample_rate} hop_length={cfg.hop_length} "
      f"semi_crf={cfg.semi_crf_version} head_dim={cfg.semi_crf_head_dim}")
state = select_state_dict(raw, prefer_ema=False)
print(f"    权重张量 {len(state)} 个")

try:
    model = AudioSemiCRFTransformer(cfg)
    report = model.load_state_dict(state, strict=False)
    print(f"    加载结果：missing={len(report.missing_keys)} unexpected={len(report.unexpected_keys)}")
    if report.missing_keys:
        print(f"    missing 前 5 个：{report.missing_keys[:5]}")
    model.eval()
except Exception:  # noqa: BLE001
    traceback.print_exc()
    raise SystemExit(3)

# ---- 3. forward 返回什么 ----
print("\n[3] forward 的输入输出")
for seconds in (1.0, 4.0):
    x = torch.zeros(1, 2, int(22050 * seconds))  # 模型要 [B, 2, T] 双声道 22.05kHz
    try:
        with torch.no_grad():
            out = model(x)
        if isinstance(out, dict):
            print(f"    {seconds}s 输入 → dict，键：{list(out.keys())}")
            for k, v in out.items():
                shape = tuple(v.shape) if torch.is_tensor(v) else type(v).__name__
                print(f"        {k}: {shape}")
        elif isinstance(out, (list, tuple)):
            print(f"    {seconds}s 输入 → {type(out).__name__}，{len(out)} 项："
                  f"{[tuple(o.shape) if torch.is_tensor(o) else type(o).__name__ for o in out]}")
        else:
            print(f"    {seconds}s 输入 → {type(out).__name__} {tuple(out.shape)}")
        break
    except Exception as e:  # noqa: BLE001
        print(f"    {seconds}s 输入失败：{type(e).__name__}: {str(e)[:200]}")

# ---- 4. 能不能 trace 出骨干 ----
print("\n[4] 试着 trace 出可导出的子模块（只看结构，不写文件）")
try:
    names = [n for n, _ in model.named_children()]
    print(f"    顶层子模块：{names}")
    for n in names:
        mod = getattr(model, n)
        params = sum(p.numel() for p in mod.parameters())
        print(f"      {n}: {type(mod).__name__}，{params / 1e6:.2f}M 参数")
except Exception:  # noqa: BLE001
    traceback.print_exc()

print("\n[5] 解码路径（会不会依赖 Triton / CUDA）")
for f in sorted((SRC / "instrument_agnostic_amt" / "amt" / "modeling").rglob("*.py")):
    text = f.read_text(encoding="utf-8", errors="ignore")
    hits = []
    if "triton" in text.lower():
        hits.append("triton")
    if "cuda" in text.lower():
        hits.append("cuda")
    if "@torch.jit.script" in text:
        hits.append("jit.script")
    if hits:
        print(f"    {f.name}: {', '.join(hits)}")
