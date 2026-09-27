"""MNN 后端可行性探针：把 ONNX 转成 .mnn，用 MNN 跑一遍，和 onnxruntime 对数值/速度。

    .venv\\Scripts\\python.exe mnn_probe.py [模型名...]

做法照 MNN 官方文档：
  · 转换：`MNNConvert -f ONNX --modelFile X.onnx --MNNModel X.mnn`（Python 里是 `MNN.tools.mnnconvert`）
  · 推理：MNN 的 Python API（`MNN.Interpreter`），CPU 后端

为什么先做这一步：MNN 运行时**只吃 .mnn**，所以"接 MNN 后端"的前提是模型能转过来且数值不跑偏；
在安卓真机上验证 NPU 之前，这一步在本机就能做完、也必须有数字。
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "piano_crnn": (ROOT / "third_party" / "piano_crnn" / "piano_crnn.onnx", (1, 160000)),
    "tsumugi": (ROOT / "third_party" / "tsumugi" / "tsumugi_amt.onnx", (1, 2, 220500)),
}


def convert(name: str, onnx: Path) -> Path | None:
    mnn = onnx.with_suffix(".mnn")
    if mnn.exists():
        print(f"[{name}] 已有 {mnn.name}（{mnn.stat().st_size / 1048576:.1f}MB）")
        return mnn
    # 官方文档的写法：MNNConvert -f ONNX --modelFile X.onnx --MNNModel X.mnn --bizCode biz
    # `pip install MNN` 会带一个 mnnconvert.exe 在 venv\Scripts 下，直接用它（比 Python API 稳）
    exe = Path(sys.executable).parent / "mnnconvert.exe"
    if not exe.exists():
        print(f"[{name}] 找不到 {exe}")
        return None
    import subprocess

    print(f"[{name}] 转换中：{onnx.name} ({onnx.stat().st_size / 1048576:.1f}MB) …")
    t0 = time.time()
    r = subprocess.run(
        [str(exe), "-f", "ONNX", "--modelFile", str(onnx), "--MNNModel", str(mnn), "--bizCode", "lipu"],
        capture_output=True, text=True,
    )
    if not mnn.exists():
        print(f"[{name}] 转换失败（退出码 {r.returncode}）: {(r.stdout or '')[-300:]} {(r.stderr or '')[-200:]}")
        return None
    print(f"[{name}] 转换完成 {mnn.name}（{mnn.stat().st_size / 1048576:.1f}MB，{time.time() - t0:.0f}s）")
    return mnn


def run_mnn(name: str, mnn: Path, shape: tuple[int, ...]) -> None:
    import MNN

    t0 = time.time()
    interp = MNN.Interpreter(str(mnn))
    session = interp.createSession({"backend": "CPU", "numThread": 4})
    print(f"[{name}] MNN 载入+建会话 {time.time() - t0:.1f}s；输入 {interp.getSessionInput(session).getShape()}")

    rng = np.random.default_rng(7)
    x = (rng.random(shape, dtype=np.float32) - 0.5) * 0.2
    inp = interp.getSessionInput(session)
    tmp = MNN.Tensor(inp.getShape(), MNN.Halide_Type_Float, x.flatten().tolist(), MNN.Tensor_DimensionType_Caffe)
    inp.copyFrom(tmp)

    t0 = time.time()
    interp.runSession(session)
    ms = (time.time() - t0) * 1000
    print(f"[{name}] MNN 前向 {ms:.0f}ms")

    out = interp.getSessionOutput(session)
    got = np.array(out.getData(), dtype=np.float32)
    print(f"[{name}] MNN 输出 {got.shape} sum={got.sum():.4f} min={got.min():.4f} max={got.max():.4f}")

    # 与 onnxruntime 对比（同一份随机输入）
    try:
        import onnxruntime as ort

        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        sess = ort.InferenceSession(str(CASES[name][0]), so, providers=["CPUExecutionProvider"])
        iname = sess.get_inputs()[0].name
        feed = x
        if len(shape) == 3:  # tsumugi: [1,2,T] → ORT 要 [1,2,T] 一致
            feed = x
        t0 = time.time()
        ref = sess.run(None, {iname: feed})
        ms2 = (time.time() - t0) * 1000
        flat_ref = np.concatenate([r.flatten() for r in ref])
        same = flat_ref.shape[0] == got.shape[0]
        if same:
            diff = float(np.max(np.abs(flat_ref - got)))
            scale = float(np.max(np.abs(flat_ref))) or 1.0
            print(f"[{name}] ORT 前向 {ms2:.0f}ms；与 MNN 输出 max|Δ|={diff:.3e}（相对 {diff / scale:.2e}）")
        else:
            print(f"[{name}] ORT 前向 {ms2:.0f}ms；元素数不同（MNN {got.shape[0]} vs ORT {flat_ref.shape[0]}），只比速度")
    except Exception as e:  # noqa: BLE001
        print(f"[{name}] 与 ORT 对比失败：{type(e).__name__}: {str(e)[:120]}")


def main() -> int:
    names = sys.argv[1:] or ["piano_crnn"]
    for name in names:
        onnx, shape = CASES[name]
        if not onnx.exists():
            print(f"[{name}] 缺少 {onnx}")
            continue
        mnn = convert(name, onnx)
        if mnn:
            run_mnn(name, mnn, shape)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
