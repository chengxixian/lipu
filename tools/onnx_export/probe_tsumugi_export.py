"""验证 Tsumugi 能不能导出成 ONNX（只导出神经网络部分，DP 留在外面）。

    .venv\\Scripts\\python.exe probe_tsumugi_export.py

依据：`probe_tsumugi.py` 已确认 forward 返回的**全是张量**
（interval_query/key/diag/features + instrument_logits + frame_valid_mask），
没有在 forward 里做半-CRF 解码 —— 所以神经网络这段可以整块导出。

导出后用 onnxruntime 重跑一遍，与 PyTorch 输出逐张量比对（max abs diff），
对得上才算"能接"。产物：third_party/tsumugi/tsumugi_amt.onnx
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "third_party" / "tsumugi_src" / "anime-song-tsumugi-020edc1"
CKPT = ROOT / "third_party" / "tsumugi" / "best_model.pth"
OUT = ROOT / "third_party" / "tsumugi" / "tsumugi_amt.onnx"
SAMPLE_RATE = 22050

sys.path.insert(0, str(SRC))

from instrument_agnostic_amt.amt.modeling.checkpoints import (  # noqa: E402
    coerce_model_config,
    extract_model_config,
    select_state_dict,
)
from instrument_agnostic_amt.amt.modeling.model import AudioSemiCRFTransformer  # noqa: E402

# 导出哪些输出（顺序固定，Dart 侧按名字取）
OUTPUT_KEYS = (
    "interval_query",
    "interval_key",
    "interval_diag",
    "interval_features",
    "pitch_query_features",
    "instrument_logits",
    "frame_valid_mask",
)


class ExportWrapper(torch.nn.Module):
    """只把需要的张量按固定顺序吐出来（其余留着也没用）"""

    def __init__(self, model: AudioSemiCRFTransformer) -> None:
        super().__init__()
        self.model = model

    def forward(self, waveform: torch.Tensor) -> tuple[torch.Tensor, ...]:
        out = self.model(waveform)
        return tuple(out[k] for k in OUTPUT_KEYS)


def main() -> int:
    raw = torch.load(str(CKPT), map_location="cpu", weights_only=False)
    cfg = coerce_model_config(extract_model_config(raw))
    model = AudioSemiCRFTransformer(cfg)
    state = select_state_dict(raw, prefer_ema=False)
    report = model.load_state_dict(state, strict=False)
    print(f"权重加载：missing={len(report.missing_keys)} unexpected={len(report.unexpected_keys)}"
          f"（missing 是乐器分类头，本次不用）")
    model.eval()

    wrapper = ExportWrapper(model).eval()
    seconds = 10.0  # 固定段长（CQT 的 reflect padding 在动态形状下导不出来）
    n = int(SAMPLE_RATE * seconds)
    waveform = torch.randn(1, 2, n) * 0.05

    with torch.no_grad():
        ref = wrapper(waveform)
        t0 = time.perf_counter()
        _ = wrapper(waveform)
        torch_ms = (time.perf_counter() - t0) * 1000
    print(f"PyTorch 前向：{torch_ms:.0f}ms / {seconds}s 音频（CPU）")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    print(f"\n导出 ONNX（动态时间轴）→ {OUT.name}")
    t0 = time.perf_counter()
    torch.onnx.export(
        wrapper,
        (waveform,),
        str(OUT),
        input_names=["waveform"],
        output_names=list(OUTPUT_KEYS),
        # 不用 dynamic_axes：CQT 里的 reflect padding 在动态时间轴下无法导出，\n        # 而 App 侧本来就是定长分段（和 CRNN 一样），静态形状完全够用。
        opset_version=17,
        do_constant_folding=True,
        # 老的 TorchScript 导出器不支持 CQT 里 torch.stft 的复数张量；\n        # dynamo 导出器（torch>=2.6）能处理，且对动态形状更宽容。\n        dynamo=True,
    )
    print(f"导出完成，用时 {time.perf_counter() - t0:.0f}s，体积 {OUT.stat().st_size / 1048576:.1f}MB")

    import onnxruntime as ort

    so = ort.SessionOptions()
    sess = ort.InferenceSession(str(OUT), so, providers=["CPUExecutionProvider"])
    print(f"onnxruntime 载入成功：输入 {[i.name for i in sess.get_inputs()]}")
    t0 = time.perf_counter()
    got = sess.run(None, {"waveform": waveform.numpy()})
    ort_ms = (time.perf_counter() - t0) * 1000
    print(f"onnxruntime 前向：{ort_ms:.0f}ms / {seconds}s 音频 "
          f"（实时率 {ort_ms / 1000 / seconds:.2f}×）")

    # 存一份参考输出 + 输入，供独立进程（verify_tsumugi_onnx.py）复核
    ref_path = OUT.parent / "reference_outputs.npz"
    np.savez_compressed(
        ref_path,
        waveform=waveform.numpy(),
        **{k: v.detach().numpy() for k, v in zip(OUTPUT_KEYS, ref)},
    )
    print(f"参考输出写入 {ref_path.name}（{ref_path.stat().st_size / 1048576:.1f}MB）")

    ok = True
    for name, a, b in zip(OUTPUT_KEYS, ref, got):
        if a.dtype == torch.bool:
            same = bool(np.array_equal(a.detach().numpy(), b.astype(bool)))
            print(f"  {'OK ' if same else '不一致'} {name:22s} bool 完全一致={same}")
            ok = ok and same
            continue
        diff = float(np.max(np.abs(a.detach().numpy() - b))) if a.numel() else 0.0
        scale = float(np.max(np.abs(a.detach().numpy()))) if a.numel() else 1.0
        rel = diff / scale if scale > 0 else 0.0
        flag = "OK " if rel < 1e-3 else "差异大"
        if rel >= 1e-3:
            ok = False
        print(f"  {flag} {name:22s} 形状 {tuple(b.shape)}  max|Δ|={diff:.2e} 相对 {rel:.2e}")

    print("\n结论：" + ("导出可用，Dart 侧只需再实现半-CRF 的区间 DP"
                     if ok else "导出数值对不上，需要逐层排查（暂时不能接）"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
