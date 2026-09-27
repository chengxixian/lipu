# 开发工具与操作手册

这个目录是**唯一入口**：所有开发/验证/出包操作都在这里查、在这里跑。
原始脚本**不搬家**（`app/tool/`、`tools/` 里的路径是相对自己位置写的，搬了会失效 ✗），
所以这里放**包装脚本** `run.ps1` + 本文档。

---

## 一、先看这里：一条命令做一件事

```powershell
cd devtools

.\run.ps1 env          # 环境准备：重建插件 junction、建 Python venv、装 Node 依赖
.\run.ps1 check        # 静态检查 + 全部单元测试（313 项，约 20 秒）
.\run.ps1 build        # 出包：Android APK + Windows zip（约 1~2 分钟）
.\run.ps1 dist         # 打包发行目录 dist/（APK + Windows zip + packs/ 增强包）
.\run.ps1 verify       # 出包后核对：dist 与构建产物 SHA256 是否一致、版本号是否进包
.\run.ps1 probe <名字> # 跑真实模型探针/基准（见第五节）
.\run.ps1 model <名字> # 模型工具链（导出/校验/量化/MNN 转换，见第四节）
.\run.ps1 all          # check + build + dist + verify（提交前跑这个）
```

---

## 二、目录总览

| 位置 | 内容 |
|---|---|
| **`devtools/run.ps1`** | 统一入口（包装下面的脚本，不重复实现逻辑） |
| `app/tool/build.ps1` | 构建 Flutter（Android/Windows） |
| `app/tool/package-dist.ps1` | 打发行目录（**必须保持 UTF-8 BOM**，见坑 3） |
| `app/tool/make-plugin-junctions.ps1` | 重建插件 junction（`pub get` 会冲掉，见坑 1） |
| `app/tool/fetch-onnxruntime.ps1` | 取 onnxruntime 动态库 |
| `app/tool/patch-plugins.ps1` | 给插件打补丁（依赖覆盖） |
| `app/tool/setup-python-basicpitch.ps1` | Basic Pitch 参考实现的 Python 环境 |
| `app/tool/make_chord_fixtures.dart` | 生成和弦基准用的 wav + 真值 |
| `app/tool/make_*.dart` / `make_demo_sample.py` | 造测试素材（单声部/复调/示例） |
| `app/tool/dbg_transcribe.dart` / `dump_musicxml.dart` | 排查用：跑一次扒谱 / 导出 MusicXML |
| `app/tool/basicpitch_reference.py` | 官方 Basic Pitch 对照 |
| `tools/onnx_export/*.py` | 模型工具链（Tsumugi 导出/校验、CRNN 量化、MNN 转换探针） |
| `tools/piano_crnn_probe/probe.mjs` | Node 侧 onnxruntime 探针（可切 CPU/DirectML/WebGPU） |
| `app/integration_test/*.dart` | **可复跑的真实验证**（真模型、真音频、真 API） |
| `docs/*.md` | 测量记录与结论（所有数字的出处） |
| `third_party/` | 模型与源码（数据，不是工具）：CRNN / Tsumugi / 分离模型 / MNN 库 |
| `dist/` | 发行产物（APK、Windows zip、packs/） |

---

## 三、环境要求

| 依赖 | 本项目实测版本/路径 |
|---|---|
| Flutter | 3.47.5（本机 `D:\android-dev\flutter\bin`，需自行加入 PATH） |
| Python | `tools/onnx_export/.venv`（torch 2.14.0+cpu、numpy、onnx 1.23、onnxruntime 1.30、onnxscript、scipy、soundfile、einops、**MNN**） |
| Node | 系统 Node + `tools/piano_crnn_probe/node_modules`（onnxruntime-node） |
| Android SDK | 本机 `D:\android-dev`（构建 APK 用） |

```powershell
# 手动重建 Python 环境（一般不需要）
cd tools\onnx_export
python -m venv .venv
.venv\Scripts\python.exe -m pip install torch numpy onnx onnxruntime onnxscript scipy soundfile einops MNN
```

---

## 四、模型工具链（`.\run.ps1 model <名字>`）

| 名字 | 作用 | 备注 |
|---|---|---|
| `export-tsumugi` | Tsumugi 权重 → ONNX（3.6MB + 外部权重 55.1MB） | **必须 `dynamo=True`**：老 TorchScript 导出器过不了 CQT 里 `torch.stft` 的复数张量 ✗ |
| `verify-tsumugi` | 导出的 ONNX 与 PyTorch 逐项对数值 | 期望相对误差 ~1e-5；**独立进程复核**才算数 |
| `probe-tsumugi` | 跑一遍 Tsumugi 看耗时/输出 | |
| `quantize-crnn` | CRNN int8 动态量化（147→113MB） | **实测失败**（音符 74→17、慢 11 倍），脚本要 `--yes-really` 才跑；结论见 docs |
| `mnn-onnx` | ONNX → `.mnn`（官方 `MNNConvert`） | 转换能过，但两个模型**运行都失败**（见下） |
| `mnn-tsumugi` | Tsumugi 走 TorchScript → MNN | 报 `Framework Input ERROR or Not Support This Model Type Now!` |
| `mnn-libs` | 查看已就位的 MNN 运行时库 | 安卓 `libMNN.so` 2.34MB、Windows `MNN.dll` 8.65MB（官方 3.6.1） |

> **MNN 现状**：运行时库已进工程，但自带两个模型都过不了转换，所以 App 里 MNN 只作
> "实验槽位"（可导入 `.mnn` 文件管理）。完整结论见 `docs/和弦识别-测量记录.md`。

---

## 五、探针与基准（`.\run.ps1 probe <名字>`）

全部是**真实模型/真实音频**，跑在 Windows 桌面上（`flutter test ... -d windows`）：

| 名字 | 验证什么 | 期望结果 |
|---|---|---|
| `chords` | 和弦准确率基准（三后端同台） | 三后端 recall 均 100%；precision BP ~91% / CRNN 83% / Tsumugi 90% |
| `crnn-pack` | CRNN 增强包端到端（下载/加载/推理） | recall 100% |
| `crnn-real` | CRNN 在真实钢琴上：**检出音高 vs 音频频谱峰值** | 两者一致（这是"音准"的硬对照） |
| `crnn-pipeline` | CRNN → 量化 → 乐谱的**音高保真度** | 音高种类丢失 0 / 多出 0、重合率 100% |
| `tsumugi` | Tsumugi 端到端（真 ONNX + 半-CRF 解码） | recall 100% / precision 90%，0.55× 实时 |
| `separator` | 人声分离链路（STFT→模型→iSTFT） | 可加性通过；**缩放待标定**（人声/混音 ≈7×，未接进 App） |
| `mirror` | 镜像站断点续传 + SHA256（147MB 真实下载） | 走 `hf-mirror.com`，7 秒 / 21MB/s |
| `basic-pitch` | 内置 Basic Pitch 端到端 | recall 100% |
| `ai-lines` | AI 识谱接口（需要 API key） | 需设 `DEEPSEEK_API_KEY` |

模型路径可用环境变量覆盖（不设就用仓库默认位置）：

```powershell
$env:PIANO_CRNN_PATH='D:\...\piano_crnn.onnx'
$env:TSUMUGI_ONNX_PATH='D:\...\tsumugi_amt.onnx'
$env:SEPARATOR_ONNX_PATH='D:\...\uvr_kara2.onnx'
$env:PACK_DOWNLOAD_E2E='1'      # 打开真实下载测试（默认跳过）
$env:DEEPSEEK_API_KEY='sk-...'  # AI 联网测试
```

---

## 六、踩过的坑与对策（**最有用的部分**）

1. **`flutter pub get` 会冲掉插件 junction** → 之后 `flutter test` 报 "Please enable Developer Mode / symlink support"。
   对策：先跑 `app\tool\make-plugin-junctions.ps1`。`run.ps1 env/check/build` 已内置。
2. **`.ps1` 必须用 `-ExecutionPolicy Bypass -File` 调用**，否则被策略拦。
3. **`package-dist.ps1` 必须保持 UTF-8 BOM**：Windows PowerShell 5.1 按 ANSI 读无 BOM 文件，
   中文会乱码成语法错误。改写该文件时用 `UTF8Encoding($true)`。
4. **`.NET` 的 `File`/`Directory` 调用要用绝对路径**：`pwsh` 进程的 CWD 与 shell 的 CWD 不是一回事。
5. **`npm` / `dart` 包装器可能被拦** → 用 `npm.cmd`、
   `D:\android-dev\flutter\bin\cache\dart-sdk\bin\dart.exe`；依赖 Flutter 的脚本用 `flutter test` 跑。
6. **PowerShell 字符串里出现中文引号 `“”` 会让整段脚本解析失败**（而且**整段不执行**）。
   对策：改文件优先用编辑工具，别用 `-replace`/`Replace()` 拼中文。
7. **测试里用的 `Float32List.view` 是连续视图**：行主序的"stride"是列数，别按 stride 索引（踩过一次）。
8. **44.1kHz 音频直接喂 22.05kHz 模型** → 整体低一个八度、时长差 2 倍。测量一律走 App 自己的
   `loadAudioFile()` 重采样 ✓。
9. **别手写模型解码器**：CRNN 与 Tsumugi 的解码都按**官方源码 1:1 移植**才有正确结果
   （手写版本 recall 只有 93%~95%，移植后回到 100%）。
10. **真机/联网测试要显式开**：`-d windows`、`PACK_DOWNLOAD_E2E=1`、`DEEPSEEK_API_KEY=...`，否则会静默跳过 ✓。

---

## 七、新增工具的规范

- 一次性排查脚本 → 放 `tools/<主题>/`，文件头写清：**干什么、怎么跑、期望看到什么**；
- 会被反复用的（构建/打包/验证）→ 放 `app/tool/`，并在本文件第二节表格里登记一行；
- 用真实模型/真实音频的验证 → 写成 `app/integration_test/*_test.dart`，
  用 `markTestSkipped` 在缺模型时优雅跳过 ✓；
- 任何"测量结论"都要落到 `docs/*.md`（数字、命令、失败原因），别只留在对话里。
