# 开发工具统一入口
#
#   cd devtools
#   .\run.ps1 env            # 环境准备（junction / venv / node）
#   .\run.ps1 check          # 静态检查 + 单元测试
#   .\run.ps1 build          # 出包（APK + Windows）
#   .\run.ps1 dist           # 打发行目录
#   .\run.ps1 verify         # 核对 dist 与构建产物一致
#   .\run.ps1 all            # check + build + dist + verify
#   .\run.ps1 probe <名字>    # 真实模型探针/基准（见 README 第五节）
#   .\run.ps1 model <名字>    # 模型工具链（见 README 第四节）
#
# 设计原则：**不搬动原脚本**（它们的相对路径写死了），只做包装调用，
# 并在这里统一处理"踩过的坑"（junction、ExecutionPolicy、UTF-8 BOM 等）。
#
# 注意：本文件含中文，必须保持 **UTF-8 BOM**，否则 PowerShell 5.1 按 ANSI 读会乱码报错。

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('env', 'check', 'build', 'dist', 'verify', 'all', 'probe', 'model', 'help')]
  [string]$Task = 'help',

  [Parameter(Position = 1)]
  [string]$Name = ''
)

$ErrorActionPreference = 'Stop'
# 工程根定位：脚本在工程内（<root>\devtools）就取上一级；
# 放在工程外（如 D:\tool\lipu）时用显式路径兜底 —— 两处副本都能跑 ✓
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'app\pubspec.yaml'))) {
  $root = 'D:\dsh work region\jianpu2staff'
}
$app = Join-Path $root 'app'
$py = Join-Path $root 'tools\onnx_export\.venv\Scripts\python.exe'
$flutterBin = 'D:\android-dev\flutter\bin'        # 本机 Flutter 路径（没有就依赖 PATH）

function Use-Flutter {
  if ((Test-Path $flutterBin) -and ($env:Path -notlike "*$flutterBin*")) {
    $env:Path = "$flutterBin;$env:Path"
  }
}

function Step($msg) { Write-Host "`n=== $msg" -ForegroundColor Cyan }

function Do-Env {
  Step '重建插件 junction（pub get 会冲掉它们）'
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'tool\make-plugin-junctions.ps1')
  if (-not (Test-Path $py)) {
    Write-Host '缺少 Python venv，按 README 第三节创建（可选，只有模型工具链需要）' -ForegroundColor Yellow
  } else {
    Write-Host 'Python venv: OK'
  }
  $nm = Join-Path $root 'tools\piano_crnn_probe\node_modules'
  Write-Host ("Node 依赖: " + $(if (Test-Path $nm) { 'OK' } else { '缺失（cd tools\piano_crnn_probe; npm.cmd install）' }))
}

function Do-Check {
  Use-Flutter
  Step '重建 junction'
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'tool\make-plugin-junctions.ps1') | Out-Null
  Step 'flutter analyze'
  Push-Location $app
  try {
    flutter analyze
    Step 'flutter test（全部单元测试）'
    flutter test
  } finally { Pop-Location }
}

function Do-Build {
  Use-Flutter
  Step '构建 Android APK + Windows'
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'tool\build.ps1') -Target all
}

function Do-Dist {
  Step '打发行目录 dist/'
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'tool\package-dist.ps1')
}

function Do-Verify {
  Step '核对：dist 的 APK 与构建产物是否逐字节一致'
  $distApk = Join-Path $app 'dist\离谱-android.apk'
  $buildApk = Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk'
  if (-not (Test-Path $distApk) -or -not (Test-Path $buildApk)) {
    Write-Host '缺少 APK，先跑 .\run.ps1 build / dist' -ForegroundColor Yellow
    return
  }
  $same = (Get-FileHash $distApk -Algorithm SHA256).Hash -eq (Get-FileHash $buildApk -Algorithm SHA256).Hash
  Write-Host ("SHA256 一致: " + $same)
  Step '核对：版本号真的进了 AOT（防止跑的是旧包）'
  $tmp = Join-Path $env:TEMP 'lipu_libapp_check.so'
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($distApk)
  try {
    $lib = $zip.Entries | Where-Object { $_.FullName -eq 'lib/arm64-v8a/libapp.so' }
    if ($lib) {
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($lib, $tmp, $true)
      $ver = (Select-String -Path (Join-Path $app 'lib\core\version.dart') -Pattern "kAppVersion = '([^']+)'").Matches[0].Groups[1].Value
      $hit = & findstr /C:"$ver" $tmp
      Write-Host ("版本 $ver 在包里: " + ($LASTEXITCODE -eq 0))
    }
  } finally { $zip.Dispose() }
  Step 'dist 内容'
  Get-ChildItem (Join-Path $app 'dist') -Recurse -File |
    Where-Object { $_.Extension -in '.apk', '.zip', '.onnx', '.data', '.txt' } |
    Select-Object @{n = '文件'; e = { $_.Name } }, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } |
    Format-Table -AutoSize
}

function Do-Probe([string]$which) {
  Use-Flutter
  $map = @{
    'chords'         = 'chord_accuracy_test.dart'
    'crnn-pack'      = 'crnn_pack_e2e_test.dart'
    'crnn-real'      = 'crnn_real_audio_probe_test.dart'
    'crnn-pipeline'  = 'crnn_pipeline_fidelity_test.dart'
    'tsumugi'        = 'tsumugi_e2e_test.dart'
    'separator'      = 'separator_e2e_test.dart'
    'basic-pitch'    = 'basic_pitch_e2e_test.dart'
    'ai-lines'       = 'ai_lines_api_test.dart'
    'verovio'        = 'verovio_e2e_test.dart'
    'preview'        = 'preview_audio_e2e_test.dart'
    'score-edit'     = 'score_edit_e2e_test.dart'
  }
  if ([string]::IsNullOrWhiteSpace($which)) {
    Write-Host '可用探针：' -ForegroundColor Yellow
    $map.Keys | Sort-Object | ForEach-Object { Write-Host "  $_" }
    return
  }
  if ($which -eq 'mirror') {
    Write-Host '镜像下载测试需要显式打开（147MB 真实下载）'
    $env:PACK_DOWNLOAD_E2E = '1'
    $f = 'pack_mirror_download_test.dart'
    Push-Location $app
    try { flutter test "test\$f" } finally { Pop-Location }
    return
  }
  if (-not $map.ContainsKey($which)) {
    throw "未知探针 '$which'，跑 .\run.ps1 probe 看列表"
  }
  $file = $map[$which]
  Write-Host "跑 integration_test\$file（真实模型，-d windows）" -ForegroundColor Cyan
  Push-Location $app
  try { flutter test "integration_test\$file" -d windows } finally { Pop-Location }
}

function Do-Model([string]$which) {
  if (-not (Test-Path $py)) { throw "缺少 Python venv：$py（见 README 第三节）" }
  Push-Location (Join-Path $root 'tools\onnx_export')
  try {
    switch ($which) {
      'export-tsumugi'  { & $py probe_tsumugi_export.py }
      'verify-tsumugi'  { & $py verify_tsumugi_onnx.py }
      'probe-tsumugi'   { & $py probe_tsumugi.py }
      'quantize-crnn'   { Write-Host '注意：int8 动态量化实测失败，脚本需 --yes-really' -ForegroundColor Yellow; & $py quantize_crnn.py }
      'mnn-onnx'        { & $py mnn_probe.py piano_crnn }
      'mnn-tsumugi'     { & $py mnn_tsumugi_probe.py }
      'mnn-libs'        { Get-ChildItem (Join-Path $root 'third_party\mnn') -File | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } }
      default {
        Write-Host '可用模型工具：export-tsumugi / verify-tsumugi / probe-tsumugi / quantize-crnn / mnn-onnx / mnn-tsumugi / mnn-libs' -ForegroundColor Yellow
      }
    }
  } finally { Pop-Location }
}

function Show-Help {
  # 必须显式 -Encoding UTF8：PowerShell 5.1 默认按 ANSI 读，中文会全乱码（本仓库踩过）
  Get-Content (Join-Path $PSScriptRoot 'README.md') -Encoding UTF8 -TotalCount 26
}

switch ($Task) {
  'env'    { Do-Env }
  'check'  { Do-Check }
  'build'  { Do-Build }
  'dist'   { Do-Dist }
  'verify' { Do-Verify }
  'all'    { Do-Check; Do-Build; Do-Dist; Do-Verify }
  'probe'  { Do-Probe $Name }
  'model'  { Do-Model $Name }
  default  { Show-Help }
}
