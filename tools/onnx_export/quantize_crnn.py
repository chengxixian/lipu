"""把 ByteDance 钢琴 CRNN 的 fp32 ONNX 量化成 int8，供"可选包"分发。

    .venv\\Scripts\\python.exe quantize_crnn.py

⚠️ **实测结论（2026-09，本机）：int8 动态量化在这个模型上不可用，已放弃。**

    |          | fp32      | int8 动态量化 |
    |----------|-----------|---------------|
    | 体积     | 147.1MB   | 113.5MB（只有 1.3×，不是 4×）|
    | 音符数   | 74        | 17 ✗ |
    | 起音一致 | —         | 10/74 ✗ |
    | 单段耗时 | 1192ms    | 13050ms（慢 11 倍）✗ |

    原因：这个网络的参数大头在 **Conv**（CRNN 的 CNN 部分），而 ORT 的
    `quantize_dynamic` 只量化 MatMul/Attention 的权重，所以体积几乎没降；
    同时 RNN/Conv 混合图在 CPU 上跑动态量化权重反而更慢。

    还想继续压体积的话，正确的下一步是 **`quantize_static` + 校准集**（静态量化能覆盖 Conv），
    但那需要准备校准音频并验证精度——在验证通过之前，可选包就用 fp32（147MB，按需下载）。
    本脚本保留下来是为了：① 记录这次失败；② 将来要试静态量化时有个现成的对比口径。

产物：app/dist/packs/piano_crnn_int8.onnx（**当前默认不产出**，见上）
"""

from __future__ import annotations

import hashlib
import json
import sys
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
from onnxruntime.quantization import QuantType, quantize_dynamic

ROOT = Path(__file__).resolve().parents[2]          # jianpu2staff/
SRC = ROOT / "third_party" / "piano_crnn" / "piano_crnn.onnx"
OUT_DIR = ROOT / "app" / "dist" / "packs"
OUT = OUT_DIR / "piano_crnn_int8.onnx"
SEGMENT = 160_000          # 10 秒 @16kHz
FRAMES, KEYS, KEY_BASE = 1001, 88, 21


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def make_session(path: Path) -> ort.InferenceSession:
    # 模型卡要求关掉图优化跑（ORT 1.20 的融合会把这个图里的 rank-3 Gemm 推断错）；
    # 这里保守照做，两边用同一套设置对比才公平。
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    return ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])


def decode(onset: np.ndarray, offset: np.ndarray, frames: int, keys: int) -> list[tuple[int, float, float]]:
    """与 Dart 端 decodeCrnnNotes 同口径：逐帧判 onset/offset + 贴脸 offset 跳过"""
    notes: list[tuple[int, float, float]] = []
    for k in range(keys):
        col_on = np.nonzero(onset[:, k] > 0.5)[0]
        col_off = np.nonzero(offset[:, k] > 0.5)[0]
        oi = 0
        for t in col_on:
            while oi < len(col_off) and col_off[oi] <= t + 3:
                oi += 1
            end = int(col_off[oi]) if oi < len(col_off) else frames - 1
            notes.append((KEY_BASE + k, t / 100.0, end / 100.0))
    return notes


def run(sess: ort.InferenceSession, audio: np.ndarray) -> tuple[list[tuple[int, float, float]], float]:
    name = sess.get_inputs()[0].name
    x = np.zeros((1, SEGMENT), dtype=np.float32)
    n = min(SEGMENT, audio.shape[0])
    x[0, :n] = audio[:n]
    t0 = time.perf_counter()
    outs = sess.run(None, {name: x})
    ms = (time.perf_counter() - t0) * 1000
    names = [o.name for o in sess.get_outputs()]
    get = lambda *cands: next(outs[i] for i, nm in enumerate(names) if any(c in nm for c in cands))
    onset = np.squeeze(get("reg_onset_output", "reg_onset"))
    offset = np.squeeze(get("reg_offset_output", "reg_offset"))
    return decode(onset, offset, onset.shape[0], onset.shape[1]), ms


def main() -> int:
    if not SRC.exists():
        print(f"缺少原始模型 {SRC}（先下载可选包）", file=sys.stderr)
        return 2
    if "--yes-really" not in sys.argv:
        print(__doc__)
        print("实测这个模型的 int8 动态量化不可用（精度崩、还更慢），因此默认不产出。")
        print("确实要重跑对比实验就加 --yes-really。")
        return 0
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"源模型 {SRC.name}：{SRC.stat().st_size / 1048576:.1f}MB")
    t0 = time.perf_counter()
    quantize_dynamic(str(SRC), str(OUT), weight_type=QuantType.QInt8)
    print(f"量化完成：{OUT.name} {OUT.stat().st_size / 1048576:.1f}MB "
          f"（{SRC.stat().st_size / OUT.stat().st_size:.1f}× 压缩，用时 {time.perf_counter() - t0:.0f}s）")

    # ---- 用同一段音频对比 fp32 / int8 的输出与耗时 ----
    fixture = ROOT / "app" / "build" / "fixtures" / "chords_triad.wav"
    if not fixture.exists():
        print("（没有测试音频，跳过精度对比：先跑 flutter test test/_make_fixtures_test.dart）")
    else:
        import wave

        with wave.open(str(fixture)) as w:
            sr = w.getframerate()
            raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
        # 线性重采样到 16k（探针口径）
        idx = np.arange(int(len(raw) * 16000 / sr)) * sr / 16000
        audio = np.interp(idx, np.arange(len(raw)), raw).astype(np.float32)

        sess_fp32, sess_int8 = make_session(SRC), make_session(OUT)
        n_fp32, ms_fp32 = run(sess_fp32, audio)
        n_int8, ms_int8 = run(sess_int8, audio)
        set_fp32 = {(m, round(s, 2)) for m, s, _ in n_fp32}
        set_int8 = {(m, round(s, 2)) for m, s, _ in n_int8}
        same = len(set_fp32 & set_int8)
        print(f"fp32：{len(n_fp32)} 个音 / {ms_fp32:.0f}ms；"
              f"int8：{len(n_int8)} 个音 / {ms_int8:.0f}ms；"
              f"起音一致 {same}/{max(len(set_fp32), len(set_int8))}")

    print(f"\nSHA256(int8) = {sha256(OUT)}")
    print(f"字节数(int8) = {OUT.stat().st_size}")
    meta = {
        "file": OUT.name,
        "bytes": OUT.stat().st_size,
        "sha256": sha256(OUT),
        "source": SRC.name,
        "sourceSha256": sha256(SRC),
        "note": "int8 动态量化的 ByteDance 钢琴 CRNN；与 fp32 同口径解码对比见 quantize_crnn.py",
    }
    (OUT_DIR / "piano_crnn_int8.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"元信息写入 {OUT_DIR / 'piano_crnn_int8.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
