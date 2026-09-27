# 示例音频的来源

这里的 `坂本龍一 - Merry Christmas Mr. Lawrence.mp3` 是**用户提供的原始音频**，
只作为「App 内置示例音频」的生成输入，不参与打包（`pubspec.yaml` 里只收
`assets/samples/`，不收 `samples/`）。

内置示例是它转出来的：

```powershell
# 22050Hz / 单声道 / 16bit WAV，掐掉开头静音，取前 90 秒
python tool/make_demo_sample.py "samples/source/坂本龍一 - Merry Christmas Mr. Lawrence.mp3"
# -> assets/samples/merry_christmas.wav  (3.8MB，约 90 秒)
```

为什么不直接内置整个 mp3：

1. 扒谱在 **Windows 端只带 WAV 解码器**（mp3 只有 Android 的系统解码器能读），
   示例要在两端都能用，所以统一转成 WAV；
2. 整首 4 分 49 秒转 WAV 是 **12.7MB**，会让安装包明显变大（现约 72MB），
   所以示例只放前 90 秒 —— 想扒整首用界面上的「选择音频文件」即可。

> 版权提醒：这是商业录音。自己用没问题；要公开分发这个 App，建议把示例换成
> 无版权/自制音频，或干脆只保留「选择音频文件」入口。
