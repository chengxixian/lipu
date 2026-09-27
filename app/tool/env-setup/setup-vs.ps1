# Install VS Build Tools 2022 (Desktop C++ workload) to D:  -- needed by "flutter build windows"
# NOTE: this triggers a UAC prompt; the user has to click Yes.
$ErrorActionPreference = 'Continue'
$dl = 'D:\android-dev\dl'
$install = 'D:\android-dev\vs2022'
New-Item -ItemType Directory -Force -Path $dl | Out-Null
function Log($m) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

$exe = "$dl\vs_BuildTools.exe"
if (-not (Test-Path $exe)) {
    Log "downloading vs_BuildTools bootstrapper ..."
    & curl.exe -L --ssl-no-revoke --fail -o $exe "https://aka.ms/vs/17/release/vs_BuildTools.exe" 2>&1 | Select-Object -Last 1
}
if (Test-Path $exe) { Log ("bootstrapper KB = " + [math]::Round((Get-Item $exe).Length / 1KB)) }

Log "starting installer -- PLEASE CLICK YES ON THE UAC PROMPT ..."
$vsArgs = @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--includeRecommended',
    '--installPath', $install
)
try {
    $p = Start-Process -FilePath $exe -ArgumentList $vsArgs -Verb RunAs -Wait -PassThru
    Log ("installer exit = " + $p.ExitCode)
} catch {
    Log ("installer launch FAILED: " + $_.Exception.Message)
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    Log "vswhere installationPath:"
    & $vswhere -latest -products * -property installationPath
    Log "vswhere version:"
    & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion
} else {
    Log "vswhere still missing -> VS Build Tools NOT installed"
}
Log "VS_SETUP_DONE"
