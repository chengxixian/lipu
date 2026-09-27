# Fetch the official ONNX Runtime release for the host platform.
# The flutter_onnxruntime Windows build normally downloads this from github.com,
# which is unreachable here, so we stage it locally instead.
# ASCII-only on purpose: Windows PowerShell 5.1 mis-parses BOM-less UTF-8 scripts.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$version = '1.22.0'
# app/tool/ -> app/ -> <repo root>/third_party
$appDir = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $appDir
$thirdParty = Join-Path $repoRoot 'third_party'
$target = Join-Path $thirdParty "onnxruntime-win-x64"
$header = Join-Path $target 'include\onnxruntime_cxx_api.h'

if (Test-Path $header) {
    Write-Host "ONNX Runtime already present: $target"
    exit 0
}

New-Item -ItemType Directory -Path $thirdParty -Force | Out-Null
$zip = Join-Path $thirdParty "onnxruntime-win-x64-$version.zip"
$inner = "onnxruntime-win-x64-$version"

if (-not (Test-Path $zip)) {
    $url = "https://github.com/microsoft/onnxruntime/releases/download/v$version/$inner.zip"
    $mirrors = @(
        "https://ghfast.top/$url",
        "https://ghproxy.net/$url",
        $url
    )
    $ok = $false
    foreach ($m in $mirrors) {
        try {
            Write-Host "downloading $m"
            Invoke-WebRequest -Uri $m -OutFile $zip -TimeoutSec 1800
            $ok = $true
            break
        } catch {
            Write-Host "  failed: $($_.Exception.Message.Split([char]10)[0])"
        }
    }
    if (-not $ok) { throw 'all mirrors failed for ONNX Runtime release zip' }
}

Write-Host 'extracting...'
$tmp = Join-Path $thirdParty '_ort_extract'
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Path $tmp | Out-Null
tar.exe -xf $zip -C $tmp
if (Test-Path $target) { Remove-Item -Recurse -Force $target }
Move-Item (Join-Path $tmp $inner) $target
Remove-Item -Recurse -Force $tmp
# The .pdb files are hundreds of MB and are not needed at runtime.
Get-ChildItem $target -Recurse -Filter '*.pdb' | Remove-Item -Force

Write-Host "done: $target"
