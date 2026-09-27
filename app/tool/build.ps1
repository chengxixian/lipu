# Build helper: sets up the toolchain env (all on D:) and runs flutter builds.
#   .\tool\build.ps1 -Target windows     -> native Windows exe (needs VS Build Tools, already installed)
#   .\tool\build.ps1 -Target apk         -> Android release APK
#   .\tool\build.ps1 -Target all
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less files as
# GBK on this machine, and a multi-byte UTF-8 character can swallow the following
# ASCII quote, which breaks parsing ("TerminatorExpectedAtEndOfString").
param(
    [ValidateSet('windows', 'apk', 'all', 'run', 'test', 'analyze')]
    [string]$Target = 'windows'
)

$ErrorActionPreference = 'Continue'
$root = 'D:\android-dev'

$env:JAVA_HOME = "$root\jdk"
$env:ANDROID_HOME = "$root\sdk"
$env:ANDROID_SDK_ROOT = "$root\sdk"
$env:GRADLE_USER_HOME = "$root\gradle-home"
# Flutter mirrors for CN (storage.googleapis.com is unreliable here)
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
# $root itself is on PATH: nuget.exe sits there and
# flutter_inappwebview_windows downloads the WebView2 SDK with it during the
# CMake configure step.
$env:PATH = "$root\flutter\bin;$root\jdk\bin;$root;$env:PATH"

$flutter = "$root\flutter\bin\flutter.bat"
$app = Split-Path -Parent $PSScriptRoot
Set-Location $app

function Info($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

Info "flutter: $(& $flutter --version 2>&1 | Select-Object -First 1)"
& $flutter config --no-analytics 2>&1 | Out-Null
& $flutter config --android-sdk "$root\sdk" 2>&1 | Out-Null

# Third-party plugins that still target an older AGP need a small patch before
# Gradle configures them (see the script's header for why).
$patch = Join-Path $PSScriptRoot 'patch-plugins.ps1'
if (Test-Path $patch) { & $patch }

# Flutter wants symlinks for plugin discovery (needs Developer Mode); we use
# directory junctions instead. Gradle/pub runs sometimes wipe them, which makes
# later `flutter test -d windows` fail with "requires symlink support", so
# always (re)create them up front.
$junctions = Join-Path $PSScriptRoot 'make-plugin-junctions.ps1'
if (Test-Path $junctions) { & $junctions 2>&1 | Out-Null; Info 'plugin junctions ready' }

switch ($Target) {
    'analyze' { & $flutter analyze }
    'test'    { & $flutter test }
    'run'     { & $flutter run -d windows }
    'windows' {
        Info 'flutter pub get'
        & $flutter pub get
        # pub get WIPES .plugin_symlinks and then tries to create real symlinks,
        # which needs Developer Mode on this machine. So recreate the junctions
        # right after pub get, not only at the start of the script.
        if (Test-Path $junctions) { & $junctions 2>&1 | Out-Null; Info 'plugin junctions re-created' }
        # flutter_onnxruntime downloads ONNX Runtime from github.com during CMake
        # configure; github is unreachable here, so stage the official release
        # locally first (windows/CMakeLists.txt then uses it via
        # USE_SYSTEM_ONNXRUNTIME).
        $fetchOrt = Join-Path $PSScriptRoot 'fetch-onnxruntime.ps1'
        if (Test-Path $fetchOrt) { & $fetchOrt } else { Info "missing: $fetchOrt" }
        Info 'flutter build windows --release'
        & $flutter build windows --release
        $out = Join-Path $app 'build\windows\x64\runner\Release'
        Info "output: $out"
        Get-ChildItem $out -ErrorAction SilentlyContinue | Select-Object Name, Length | Format-Table -AutoSize
    }
    'apk' {
        Info 'flutter pub get'
        & $flutter pub get
        if (Test-Path $junctions) { & $junctions 2>&1 | Out-Null; Info 'plugin junctions re-created' }
        # AGP fails to parse CMake's buildFiles JSON when the path contains spaces
        # (jni/path_provider native build), so build through a junction without spaces.
        $plain = 'D:\tool\lipu-build'
        if ($app -match ' ') {
            if (-not (Test-Path $plain)) {
                New-Item -ItemType Junction -Path $plain -Target (Split-Path -Parent $app) | Out-Null
                Info "created space-free build path: $plain"
            }
            Set-Location (Join-Path $plain 'app')
            Info "building from $((Get-Location).Path)"
        }
        Info 'flutter build apk --release'
        & $flutter build apk --release
        $apk = Join-Path (Get-Location) 'build\app\outputs\flutter-apk\app-release.apk'
        if (Test-Path $apk) { Info ("APK: {0} ({1} MB)" -f $apk, [math]::Round((Get-Item $apk).Length / 1MB, 1)) }
        else { Info 'APK not generated' }
    }
    'all' {
        & $PSCommandPath -Target windows
        & $PSCommandPath -Target apk
    }
}
