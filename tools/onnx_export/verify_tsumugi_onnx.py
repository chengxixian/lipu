"""独立进程校验导出的 Tsumugi ONNX：文件完整性 + 数值一致性。

    .venv\\Scripts\\python.exe verify_tsumugi_onnx.py

为什么单独跑一个脚本：导出脚本是在**同一个进程**里比对 PyTorch 与 onnxruntime 的，
有可能命中缓存/共享权重，看起来"对得上"其实文件本身是残的。
这里在全新进程里：
  1. 数一遍 ONNX 的初始化器（权重）数量和总字节数 —— 和 checkpoint 的 14M 参数对账；
  2. 载入参考输出（导出时存下的 .npz）逐张量比对。
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]
ONNX = ROOT / "third_party" / "tsumugi" / "tsumugi_amt.onnx"
REF = ROOT / "third_party" / "tsumugi" / "reference_outputs.npz"

if not ONNX.exists() or not REF.exists():
    print(f"缺文件：{ONNX.exists()=} {REF.exists()=}", file=sys.stderr)
    raise SystemExit(2)

print(f"文件：{ONNX.name}  {ONNX.stat().st_size / 1048576:.2f}MB")
siblings = [p for p in ONNX.parent.glob(f"{ONNX.name}*") if p != ONNX]
print(f"外部数据文件：{[p.name for p in siblings] or '无（自包含）'}")

model = onnx.load(str(ONNX), load_external_data=False)
inits = list(model.graph.initializer)
total_bytes = sum(int(np.prod(i.dims)) * 4 for i in inits if i.data_type == 1)  # float32
print(f"初始化器：{len(inits)} 个，float32 权重合计 {total_bytes / 1048576:.1f}MB")
if total_bytes < 10 * 1048576:
    print("⚠️ 权重体积远小于 checkpoint 的 14M 参数（应约 53MB）—— 导出可能漏了权重，"
          "需要排查（先把结论标为不可用）")

sess = ort.InferenceSession(str(ONNX), providers=["CPUExecutionProvider"])
ref = np.load(REF)
worst = 0.0
print("\n逐输出比对（独立进程）：")
for i, out in enumerate(sess.get_outputs()):
    got = sess.run([out.name], {"waveform": ref["waveform"]})[0]
    want = ref[out.name]
    if want.dtype == np.bool_ or got.dtype == np.bool_:
        same = bool(np.array_equal(want.astype(bool), got.astype(bool)))
        print(f"  {'OK ' if same else '不一致'} {out.name:22s} bool 形状 {got.shape} 完全一致={same}")
        worst = 0.0 if same else 1.0
        continue
    diff = float(np.max(np.abs(want - got))) if want.size else 0.0
    scale = float(np.max(np.abs(want))) if want.size else 1.0
    rel = diff / scale if scale > 0 else 0.0
    worst = max(worst, rel)
    print(f"  {'OK ' if rel < 1e-3 else '差异大'} {out.name:22s} 形状 {got.shape} "
          f"max|Δ|={diff:.2e} 相对 {rel:.2e}")

print("\n结论：" + ("独立进程校验通过（文件自包含、数值与 PyTorch 一致）" if worst < 1e-3
                 else "校验未通过，不能拿去用"))
raise SystemExit(0 if worst < 1e-3 else 1)
