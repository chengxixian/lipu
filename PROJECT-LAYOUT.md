# 工程结构与资料索引

> 目的：**所有与本项目相关的资料都在工作区内**（`D:\dsh work region\`），
> D 盘根目录只保留一个工具入口 `D:\tool\lipu\`。本文档说明"什么在哪、怎么用"。

---

## 一、D 盘根目录：只留一个工具入口

| 位置 | 内容 | 说明 |
|---|---|---|
| **`D:\tool\lipu\`** | `run.ps1` + `README.md` | **唯一入口**：构建/测试/出包/探针/模型工具（手册在它的 README 里） |
| **`D:\tool\lipu-build\`** | 指向工程根的无空格 **junction** | AGP 无法解析含空格路径下的 CMake 产物 ✗，所以留这个入口（本身不占数据） |
| `D:\tool\`（其余） | cmake / gradle / jdk / PortableGit / gh | 你搭的通用开发链，与本项目共用 |
| `D:\android-dev\` | Flutter SDK、Android SDK、VS2022 | 系统级工具链（你的，不动） |

> 已完成清理：原先散在 D 盘根目录的 **9 个旧版本副本**（约 300MB）、`jianpu2staff_models`（288MB）、
> `verovio_pkg`（34MB）、`verovio_probe`（7.6MB）、以及旧构建入口 `D:\jianpu2staff_build`
> 全部**移入工作区归档**（同盘移动，秒完成，无复制开销）：
> `D:\dsh work region\_archive\{jianpu2staff-old-versions, jianpu2staff_models, verovio_pkg, verovio_probe}`

---

## 二、工作区内的工程结构

```
D:\dsh work region\
├── jianpu2staff\                     ← 工程主体（Flutter App + 文档 + 模型）
│   ├── app\                          Flutter 应用
│   │   ├── lib\
│   │   │   ├── core\                 基础：版本、路径、和弦分析、乐谱模型
│   │   │   ├── transcribe\           **扒谱引擎层**
│   │   │   │   ├── backends.dart     后端注册表（内置算法/Basic Pitch/CRNN/Tsumugi/MuScriptor）
│   │   │   │   ├── model_packs.dart  可选增强包：下载/校验/导入/删除
│   │   │   │   ├── crnn_engine.dart  ByteDance 钢琴 CRNN（官方解码器移植）
│   │   │   │   ├── tsumugi_engine.dart Tsumugi 半-CRF（官方解码器移植）
│   │   │   │   ├── fft_mixed.dart    混合基 FFT（5120 = 5×1024，分离模型要的）
│   │   │   │   ├── stft.dart         分离用 STFT/ISTFT（含 overlap-add）
│   │   │   │   └── separator.dart    人声分离引擎（缩放待标定，未接进 App）
│   │   │   ├── ui\                   界面（识谱/扒谱/乐谱/导出 + 主题）
│   │   │   ├── render\               Verovio 渲染（五线谱 → SVG → 分页）
│   │   │   └── omr\                  图片识谱（含 AI 识谱）
│   │   ├── test\                     313 项单元测试
│   │   ├── integration_test\         **真实模型/真实音频的验证**（11 个可复跑探针）
│   │   ├── tool\                     构建与素材脚本（build/package-dist/junction/造素材）
│   │   ├── dist\                     ★ 发行产物（APK、Windows zip、packs/ 增强包）
│   │   └── android\app\src\main\jniLibs\arm64-v8a\  MNN 运行时（libMNN.so 2.34MB）
│   ├── tools\
│   │   ├── onnx_export\              模型工具链（Tsumugi 导出/校验、CRNN 量化、MNN 探针）
│   │   └── piano_crnn_probe\         Node 侧 onnxruntime 探针（CPU/DirectML/WebGPU）
│   ├── third_party\                  模型与源码（数据，非工具）
│   │   ├── piano_crnn\               CRNN ONNX 147MB + 转好的 .mnn
│   │   ├── tsumugi\                  自导出 ONNX 3.6MB + 外部权重 55.1MB
│   │   ├── tsumugi_src\              官方源码（解码器移植的依据）
│   │   ├── piano_transcription_inference\  官方解码器原件（对照用）
│   │   ├── separators\               UVR-MDX KARA2 ONNX 50.8MB
│   │   ├── mnn\                      MNN 官方库（Android/Windows）
│   │   └── onnxruntime-win-x64\
│   ├── docs\                         ★ 测量记录与结论（所有数字的出处）
│   │   ├── 和弦识别-测量记录.md        和弦基准、CRNN/Tsumugi 实测、MNN 结论、CRNN"音不对"排查
│   │   ├── 八度点识别-测量结论.md
│   │   └── 连音修复记录-build16.md
│   ├── devtools\                     工程内的同一份工具入口（让仓库自足）
│   ├── README.md                     用户向说明（功能、用法、变更记录）
│   └── PROJECT-LAYOUT.md             本文件
└── _archive\                         ★ 历史归档（旧版本、旧模型、旧探针）
```

---

## 三、找东西的快捷索引

| 我要找… | 去哪 |
|---|---|
| 怎么构建/测试/出包 | `D:\tool\lipu\README.md`（或 `devtools\README.md`） |
| 某个数字是怎么测出来的 | `docs\和弦识别-测量记录.md` |
| 增强包（CRNN/Tsumugi/分离）怎么下载或导入 | 手册第五节 + `app\lib\transcribe\model_packs.dart` |
| 怎么加一个新扒谱模型 | `backends.dart` 的注册表：**加一个 `TranscribeBackend` + 一条 `ModelPackSpec`**，界面自动出现 |
| 出包产物在哪 | `app\dist\`（APK 82.3MB / Windows zip 28.4MB / `packs\` 增强包） |
| 真实模型怎么验证 | `app\integration_test\`（11 个探针，`run.ps1 probe <名字>` 调） |
| 模型怎么导出/转换 | `tools\onnx_export\`（`run.ps1 model <名字>` 调） |
| 旧版本/旧模型 | `_archive\` |

---

## 四、收纳规则（以后照着做）

1. **一切资料进工作区**：模型、数据、截图、旧版本 → `jianpu2staff\`（在用）或 `_archive\`（归档）；
2. **D 盘根目录只允许出现** `D:\tool\lipu`（入口）与 `D:\tool\lipu-build`（无空格构建 junction）；
3. **临时文件**放工作区内（如 `_tmp_audio\`），别用 `D:\tmp` 或系统临时目录堆东西；
4. **构建产物**：工程内 `app\build\`、发行目录 `app\dist\`；需要无空格路径时走 `D:\tool\lipu-build`（junction，不复制数据）；
5. **测量结论必须落文档**（`docs\*.md`），别只留在对话或控制台里；
6. 新增脚本按手册第七节的规范放（一次性探针 → `tools\`；常用 → `app\tool\` 并在手册登记）。
