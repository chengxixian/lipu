#!/usr/bin/env python
"""把用户提供的歌曲转成 App 内置的示例音频（22050Hz / 单声道 / 16bit WAV）。

为什么必须转成 WAV：
  扒谱在 Windows 端只带 WAV 解码器（见 lib/transcribe/audio_source.dart），
  mp3 只有 Android 的系统解码器能读。示例音频要在两端都能用，所以统一转 WAV。

为什么要截取：
  整首歌 4 分 49 秒转成 22050Hz 单声道是 12.7MB，会让安装包明显变大。
  示例只是"让人先试一下效果"，截取开头一段就够；想扒整首请用「选择音频文件」。

用法：
  python tool/make_demo_sample.py <输入音频> [输出路径] [时长秒数]
"""
import os
import sys

import librosa
import numpy as np
import soundfile as sf

DEFAULT_OUT = os.path.join("assets", "samples", "merry_christmas.wav")
DEFAULT_SECONDS = 90.0
SR = 22050


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT
    seconds = float(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_SECONDS

    y, _ = librosa.load(src, sr=SR, mono=True)
    total = len(y) / SR

    # 掐掉开头的静音，让示例一进来就是音乐
    peak = float(np.max(np.abs(y))) if len(y) else 0.0
    thresh = max(0.01, peak * 0.02)
    voiced = np.where(np.abs(y) > thresh)[0]
    start = int(voiced[0]) if len(voiced) else 0
    if start > SR:  # 超过 1 秒的静音才裁，避免误伤弱起
        start -= int(0.2 * SR)
    else:
        start = 0

    clip = y[start:start + int(seconds * SR)]
    # 峰值归一化到 -1dB，避免个别设备上削顶
    m = float(np.max(np.abs(clip))) if len(clip) else 0.0
    if m > 0:
        clip = clip * (0.89 / m)

    os.makedirs(os.path.dirname(dst), exist_ok=True)
    sf.write(dst, (clip * 32767).astype(np.int16), SR, subtype="PCM_16")

    size = os.path.getsize(dst)
    print(f"源文件 {os.path.basename(src)}  总长 {total:.1f}s")
    print(f"截取 {start / SR:.1f}s ~ {(start + len(clip)) / SR:.1f}s  "
          f"({len(clip) / SR:.1f}s)")
    print(f"写出 {dst}  {size / 1048576:.2f} MB  {SR}Hz 单声道 16bit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
