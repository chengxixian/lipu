# Patch third-party Flutter plugins that are not yet AGP 9 ready.
#
# Why: AGP 9 removed getDefaultProguardFile('proguard-android.txt') and fails the
# whole build at *configuration* time when a plugin still asks for it:
#   `getDefaultProguardFile('proguard-android.txt')` is no longer supported ...
#   Instead use `getDefaultProguardFile('proguard-android-optimize.txt)`
# flutter_inappwebview_android 1.1.3 (the latest release) still uses the old name,
# and the failure happens while Gradle evaluates the plugin's build.gradle, so an
# init script cannot intercept it -- the file itself has to be patched.
#
# The replacement name is exactly what AGP's message recommends, and it changes
# nothing about the plugin's keep rules (minifyEnabled / proguard-rules.pro stay).
#
# Idempotent: safe to run before every build.
# ASCII only: Windows PowerShell 5.1 mis-parses BOM-less UTF-8 scripts.
$ErrorActionPreference = 'Continue'

$roots = @()
if ($env:LOCALAPPDATA) {
    $roots += (Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted')
}
if ($env:PUB_CACHE) {
    $roots += $env:PUB_CACHE
}
if ($env:APPDATA) {
    $roots += (Join-Path $env:APPDATA 'Pub\Cache\hosted')
}

$old = "getDefaultProguardFile('proguard-android.txt')"
$new = "getDefaultProguardFile('proguard-android-optimize.txt')"
$patched = 0
$scanned = 0

foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    $files = Get-ChildItem $root -Recurse -Filter 'build.gradle' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\android\\build\.gradle$' }
    foreach ($f in $files) {
        $scanned++
        $text = [System.IO.File]::ReadAllText($f.FullName)
        if ($text.Contains($old)) {
            $text = $text.Replace($old, $new)
            [System.IO.File]::WriteAllText($f.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
            Write-Output "patched: $($f.FullName)"
            $patched++
        }
    }
}

Write-Output "scan-plugins: scanned=$scanned patched=$patched"
