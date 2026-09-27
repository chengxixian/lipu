# JDK 17 (Microsoft OpenJDK, aka.ms mirror -- github.com is blocked here) + Android SDK to D:
$ErrorActionPreference = 'Continue'
$root = 'D:\android-dev'
$dl = "$root\dl"
New-Item -ItemType Directory -Force -Path $dl, "$root\sdk" | Out-Null
function Log($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---------- 1. JDK 17 ----------
if (-not (Test-Path "$root\jdk\bin\java.exe")) {
    $zip = "$dl\msjdk17.zip"
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 50MB) {
        Log "downloading Microsoft OpenJDK 17 ..."
        & curl.exe -L --ssl-no-revoke --fail --retry 2 -o $zip "https://aka.ms/download-jdk/microsoft-jdk-17.0.13-windows-x64.zip" 2>&1 | Select-Object -Last 1
        if ($LASTEXITCODE -ne 0) { Log "JDK download FAILED"; exit 1 }
    }
    Log ("jdk zip MB = " + [math]::Round((Get-Item $zip).Length / 1MB, 1))
    Remove-Item "$root\jdk-tmp" -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath "$root\jdk-tmp" -Force
    $d = Get-ChildItem "$root\jdk-tmp" -Directory | Select-Object -First 1
    Move-Item $d.FullName "$root\jdk"
    Remove-Item "$root\jdk-tmp" -Recurse -Force -ErrorAction SilentlyContinue
}
$env:JAVA_HOME = "$root\jdk"
$env:PATH = "$root\jdk\bin;$env:PATH"
Log ("java = " + (& "$root\jdk\bin\java.exe" -version 2>&1 | Select-Object -First 1))

# ---------- 2. cmdline-tools ----------
if (-not (Test-Path "$root\sdk\cmdline-tools\latest\bin\sdkmanager.bat")) {
    $zip = "$dl\cmdline-tools.zip"
    if (-not (Test-Path $zip)) {
        Log "downloading cmdline-tools ..."
        & curl.exe -L --ssl-no-revoke --fail -o $zip "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" 2>&1 | Select-Object -Last 1
    }
    Remove-Item "$dl\clt" -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath "$dl\clt" -Force
    New-Item -ItemType Directory -Force -Path "$root\sdk\cmdline-tools" | Out-Null
    Move-Item "$dl\clt\cmdline-tools" "$root\sdk\cmdline-tools\latest"
    Remove-Item "$dl\clt" -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- 3. licenses + packages ----------
$sm = "$root\sdk\cmdline-tools\latest\bin\sdkmanager.bat"
Log "accepting licenses ..."
("y`r`n" * 60) | & $sm --sdk_root="$root\sdk" --licenses 2>&1 | Select-Object -Last 2
Log "installing platform-tools / android-34 / build-tools 34 ..."
& $sm --sdk_root="$root\sdk" "platform-tools" "platforms;android-34" "build-tools;34.0.0" 2>&1 | Select-Object -Last 4
Log ("sdkmanager exit = " + $LASTEXITCODE)
Get-ChildItem "$root\sdk" -Directory | Select-Object -ExpandProperty Name | ForEach-Object { Log ("  sdk/" + $_) }
Log "ANDROID_SETUP_DONE"
