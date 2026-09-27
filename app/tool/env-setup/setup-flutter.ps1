# Flutter SDK + Bravura (SMuFL music font) to D:
# flutter: storage.googleapis.com (works) ; Bravura: jsdelivr mirror because github.com is blocked
$ErrorActionPreference = 'Continue'
$root = 'D:\android-dev'
$dl = "$root\dl"
New-Item -ItemType Directory -Force -Path $dl | Out-Null
function Log($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---------- 1. Flutter SDK ----------
if (-not (Test-Path "$root\flutter\bin\flutter.bat")) {
    $zipName = 'flutter_windows_stable.zip'
    $zip = "$dl\$zipName"
    $url = 'https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.5-stable.zip'
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 100MB) {
        Log "downloading Flutter SDK ..."
        & curl.exe -L --ssl-no-revoke --fail --retry 2 -o $zip $url 2>&1 | Select-Object -Last 1
        if ($LASTEXITCODE -ne 0) { Log "flutter download FAILED"; exit 1 }
    }
    Log ("flutter zip MB = " + [math]::Round((Get-Item $zip).Length / 1MB, 1))
    Remove-Item "$root\flutter-tmp" -Recurse -Force -ErrorAction SilentlyContinue
    Log "extracting Flutter (takes a few minutes) ..."
    Expand-Archive -Path $zip -DestinationPath "$root\flutter-tmp" -Force
    $d = Get-ChildItem "$root\flutter-tmp" -Directory | Select-Object -First 1
    Move-Item $d.FullName "$root\flutter"
    Remove-Item "$root\flutter-tmp" -Recurse -Force -ErrorAction SilentlyContinue
}
Log ("flutter version: " + (& "$root\flutter\bin\flutter.bat" --version 2>&1 | Select-Object -First 2))

# ---------- 2. Bravura.otf ----------
$fontDir = "$root\assets\fonts"
New-Item -ItemType Directory -Force -Path $fontDir | Out-Null
if (-not (Test-Path "$fontDir\Bravura.otf") -or (Get-Item "$fontDir\Bravura.otf").Length -lt 100KB) {
    Log "downloading Bravura.otf (jsdelivr mirror) ..."
    & curl.exe -L --ssl-no-revoke --fail -o "$fontDir\Bravura.otf" `
        "https://cdn.jsdelivr.net/gh/steinbergmedia/bravura@master/redist/otf/Bravura.otf" 2>&1 | Select-Object -Last 1
}
if (Test-Path "$fontDir\Bravura.otf") { Log ("Bravura.otf KB = " + [math]::Round((Get-Item "$fontDir\Bravura.otf").Length / 1KB)) }
else { Log "Bravura download FAILED" }
Log "FLUTTER_SETUP_DONE"
