# 把构建产物整理成可直接分发的 dist/ 目录
#   .\tool\package-dist.ps1
# 产物：
#   dist\离谱-win-x64\            （解压即用，双击 离谱.exe）
#   dist\离谱-win-x64.zip
#   dist\离谱-android.apk
$ErrorActionPreference = 'Continue'
$app = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $app 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

function Info($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---------- Windows ----------
$winSrc = Join-Path $app 'build\windows\x64\runner\Release'
if (Test-Path $winSrc) {
    $winDst = Join-Path $dist '离谱-win-x64'
    if (Test-Path $winDst) { Remove-Item $winDst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $winDst | Out-Null
    Copy-Item "$winSrc\*" $winDst -Recurse -Force

    # 把 exe 改成中文名（Flutter 需要 exe 与 DLL 同目录，改 exe 名不影响加载）
    $exe = Join-Path $winDst 'jianpu_app.exe'
    if (Test-Path $exe) { Move-Item $exe (Join-Path $winDst '离谱.exe') -Force }

    @'
离谱 Lipu
====================

双击「离谱.exe」即可运行，无需安装、无需联网。

功能
  1. 识谱页：点「选择简谱图片」（可一次选多张）-> AI 逐音转写 -> 点「转化为五线谱」直接出谱
  2. 扒谱页：听歌扒谱（音频文件）/ 哼唱记谱（麦克风）-> Basic Pitch 神经网络离线识别 -> 钢琴卷帘校对 -> 生成乐谱
  3. 乐谱页：五线谱 A4 分页预览、缩放、歌词/标题开关、试听（可调速）
     直接改谱：点一下音符，上下拖改音高、左右拖改位置；再点同一个音符弹出时值条改几分音符；
     和弦里每个符头都能单独拖；改错了点「撤销」
  4. 导出页：MusicXML / MIDI / PNG（每页一张）/ WAV / 简谱文本

说明
  - 扒谱、排版、音频合成都在这台电脑上完成，音频不会上传；
    Basic Pitch 模型（230KB，Apache-2.0）随包发布，完全离线推理。
  - 图片识谱需要联网：点识谱页右上角设置图标填 API Key（默认 DeepSeek 视觉模型）后才能用；
    图片会发送到你填写的服务。
  - 音频文件在 Windows 上直接支持 WAV；mp3/m4a 等在安卓端由系统解码器处理。
  - 五线谱字体：Bravura (SMuFL)，SIL Open Font License 1.1
'@ | Set-Content -Path (Join-Path $winDst '使用说明.txt') -Encoding UTF8

    $zip = Join-Path $dist '离谱-win-x64.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $winDst '*') -DestinationPath $zip -Force
    Info ("Windows 包完成: {0} ({1} MB)" -f $zip, [math]::Round((Get-Item $zip).Length / 1MB, 1))
} else {
    Info "未找到 Windows 构建产物，请先运行 .\tool\build.ps1 -Target windows"
}

# ---------- Android ----------
$apkSrc = Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path $apkSrc) {
    $apkDst = Join-Path $dist '离谱-android.apk'
    Copy-Item $apkSrc $apkDst -Force
    Info ("Android 包完成: {0} ({1} MB)" -f $apkDst, [math]::Round((Get-Item $apkDst).Length / 1MB, 1))
} else {
    Info "未找到 APK，请先运行 .\tool\build.ps1 -Target apk"
}

# ---------- 可选增强包 ----------
# 从 HuggingFace 下载的那些包（钢琴 CRNN、人声分离）不用随包发；
# 但 **Tsumugi 的 ONNX 是本仓库自己导出的**，网上没有，所以放进 dist\packs\ 让用户"从文件导入"。
$packsDir = Join-Path $dist 'packs'
New-Item -ItemType Directory -Force -Path $packsDir | Out-Null
$tsumugi = Join-Path (Split-Path -Parent $app) 'third_party\tsumugi'
if (Test-Path (Join-Path $tsumugi 'tsumugi_amt.onnx')) {
    Copy-Item (Join-Path $tsumugi 'tsumugi_amt.onnx') $packsDir -Force
    if (Test-Path (Join-Path $tsumugi 'tsumugi_amt.onnx.data')) {
        Copy-Item (Join-Path $tsumugi 'tsumugi_amt.onnx.data') $packsDir -Force
    }
    # 用数组拼文本（不用 here-string：混合换行时 PowerShell 会判成"字符串未结束"）
    $lines = @(
        'Tsumugi 增强包（可选）',
        '====================',
        '',
        '这两个文件是「通用乐器（Tsumugi）」增强包：',
        '  tsumugi_amt.onnx        （网络本体）',
        '  tsumugi_amt.onnx.data   （权重，必须与 .onnx 放在同一目录）',
        '',
        '用法：',
        '  1. 把两个文件拷到手机/电脑上（同一目录）；',
        '  2. 打开 离谱 -> 扒谱页 -> 识别引擎旁的「增强包」区块 -> 点「从文件导入」；',
        '  3. 选中 tsumugi_amt.onnx 即可（会自动核对体积与校验值）；',
        '  4. 回到「识别引擎」下拉框选「通用乐器（Tsumugi）」。',
        '',
        '模型：anime-song/tsumugi（MIT，神经半-CRF 乐器无关转写），',
        'ONNX 由本仓库 tools/onnx_export/probe_tsumugi_export.py 导出（数值与 PyTorch 一致到 1e-5）。'
    )
    Set-Content -Path (Join-Path $packsDir 'Tsumugi-增强包-说明.txt') -Value $lines -Encoding UTF8
    Info ("增强包完成: dist\packs\tsumugi_amt.onnx ({0} MB)" -f [math]::Round((Get-Item (Join-Path $packsDir 'tsumugi_amt.onnx')).Length / 1MB, 1))
} else {
    Info "未找到 Tsumugi ONNX（先跑 tools\onnx_export\probe_tsumugi_export.py）"
}

Info "dist 目录:"
Get-ChildItem $dist | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } | Format-Table -AutoSize
