"""MNN 后端第二条路：Tsumugi 走 **TorchScript 前端**（`-f TORCH`）。

    .venv\\Scripts\\python.exe mnn_tsumugi_probe.py

为什么走这条：直接用 MNN 的 ONNX 前端转 Tsumugi 会在形状推导上失败
（`Compute Shape Error for val_412`，见 `mnn_probe.py` 的实测）。
但 Tsumugi 的**原始 PyTorch 权重我们有**，所以可以自己 trace 成 TorchScript，
再从 TorchScript 转 MNN —— 绕开 ONNX 前端。

流程：加载 checkpoint → jit.trace → 保存 .pt → mnnconvert -f TORCH → MNN 推理
     → 与 onnxruntime 的输出逐项对比。
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "third_party" / "tsumugi_src" / "anime-song-tsumugi-020edc1"
CKPT = ROOT / "third_party" / "tsumugi" / "best_model.pth"
OUT_DIR = ROOT / "third_party" / "tsumugi"
TS_PT = OUT_DIR / "tsumugi_amt_ts.pt"
TS_MNN = OUT_DIR / "tsumugi_amt_ts.mnn"
ONNX = OUT_DIR / "tsumugi_amt.onnx"

sys.path.insert(0, str(SRC))

OUTPUT_KEYS = (
    "interval_query",
    "interval_key",
    "interval_diag",
    "interval_features",
    "pitch_query_features",
    "instrument_logits",
    "frame_valid_mask",
)


class Wrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, waveform: torch.Tensor):
        out = self.model(waveform)
        return tuple(out[k] for k in OUTPUT_KEYS)


def build_model():
    from instrument_agnostic_amt.amt.modeling.checkpoints import (
        coerce_model_config,
        extract_model_config,
        select_state_dict,
    )
    from instrument_agnostic_amt.amt.modeling.model import AudioSemiCRFTransformer

    raw = torch.load(str(CKPT), map_location="cpu", weights_only=False)
    cfg = coerce_model_config(extract_model_config(raw))
    model = AudioSemiCRFTransformer(cfg)
    model.load_state_dict(select_state_dict(raw, prefer_ema=False), strict=False)
    model.eval()
    return Wrapper(model).eval()


def main() -> int:
    if not CKPT.exists():
        print(f"缺少 {CKPT}")
        return 2
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # 1) trace 成 TorchScript
    if not TS_PT.exists():
        print("trace 中（Tsumugi，14M 参数）…")
        m = build_model()
        example = torch.zeros(1, 2, 220500)
        t0 = time.time()
        with torch.no_grad():
            traced = torch.jit.trace(m, (example,), strict=False)
        torch.jit.save(traced, str(TS_PT))
        print(f"TorchScript 保存 {TS_PT.name}（{TS_PT.stat().st_size / 1048576:.1f}MB，{time.time() - t0:.0f}s）")
    else:
        print(f"已有 {TS_PT.name}（{TS_PT.stat().st_size / 1048576:.1f}MB）")

    # 2) TorchScript → MNN
    if not TS_MNN.exists():
        exe = Path(sys.executable).parent / "mnnconvert.exe"
        print("转换为 MNN（-f TORCH）…")
        t0 = time.time()
        r = subprocess.run(
            [str(exe), "-f", "TORCH", "--modelFile", str(TS_PT), "--MNNModel", str(TS_MNN), "--bizCode", "lipu"],
            capture_output=True, text=True,
        )
        if not TS_MNN.exists():
            print(f"转换失败（{r.returncode}）：{(r.stdout or '')[-500:]}")
            return 3
        print(f"转换完成 {TS_MNN.name}（{TS_MNN.stat().st_size / 1048576:.1f}MB，{time.time() - t0:.0f}s）")
    else:
        print(f"已有 {TS_MNN.name}（{TS_MNN.stat().st_size / 1048576:.1f}MB）")

    # 3) 用 MNN 推理
    import MNN

    interp = MNN.Interpreter(str(TS_MNN))
    session = interp.createSession({"backend": "CPU", "numThread": 4})
    inp = interp.getSessionInput(session)
    print(f"MNN 输入 {inp.getShape()}")
    rng = np.random.default_rng(11)
    x = ((rng.random((1, 2, 220500), dtype=np.float32) - 0.5) * 0.1).astype(np.float32)
    tmp = MNN.Tensor(inp.getShape(), MNN.Halide_Type_Float, x.flatten().tolist(), MNN.Tensor_DimensionType_Caffe)
    inp.copyFrom(tmp)
    try:
        t0 = time.time()
        interp.runSession(session)
        mnn_ms = (time.time() - t0) * 1000
        out = interp.getSessionOutput(session)
        got = np.array(out.getData(), dtype=np.float32)
        print(f"MNN 前向 {mnn_ms:.0f}ms，输出 {got.shape} sum={got.sum():.4f} "
              f"min={got.min():.4f} max={got.max():.4f}")
    except Exception as e:  # noqa: BLE001
        print(f"MNN 推理失败：{type(e).__name__}: {str(e)[:200]}")
        return 4

    # 4) 与 onnxruntime 对比同一份输入
    try:
        import onnxruntime as ort

        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        sess = ort.InferenceSession(str(ONNX), so, providers=["CPUExecutionProvider"])
        t0 = time.time()
        ref = sess.run(None, {sess.get_inputs()[0].name: x})
        ort_ms = (time.time() - t0) * 1000
        flat = np.concatenate([r.flatten() for r in ref])
        print(f"ORT 前向 {ort_ms:.0f}ms，输出合计 {flat.shape[0]} 个元素")
        if flat.shape[0] == got.shape[0]:
            d = float(np.max(np.abs(flat - got)))
            s = float(np.max(np.abs(flat))) or 1.0
            print(f"⚠️ 逐元素对比：max|Δ|={d:.3e}（相对 {d / s:.2e}）")
        else:
            print(f"⚠️ 元素数不同（MNN {got.shape[0]} vs ORT {flat.shape[0]}）——"
                  "MNN 只返回了部分输出，需要按名字取（getSessionOutput(name)）")
            names = interp.getSessionOutputAll(session)
            print(f"MNN 会话输出名：{list(names.keys())[:10]}")
    except Exception as e:  # noqa: BLE001
        print(f"与 ORT 对比失败：{type(e).__name__}: {str(e)[:160]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
