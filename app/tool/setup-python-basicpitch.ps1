# Install Python 3.11 + basic-pitch[onnx] as the reference implementation (D: drive, CN mirrors).
# NOTE: keep this file ASCII-only so Windows PowerShell 5.1 parses it without a BOM.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$dst = 'D:\android-dev\python'
$exe = Join-Path $dst 'python.exe'

if (-not (Test-Path $exe)) {
    $inst = Join-Path $env:TEMP 'python-3.11.9-amd64.exe'
    if (-not (Test-Path $inst)) {
        Write-Host 'downloading python installer...'
        Invoke-WebRequest -Uri 'https://registry.npmmirror.com/-/binary/python/3.11.9/python-3.11.9-amd64.exe' -OutFile $inst -TimeoutSec 600
    }
    Write-Host "installing python to $dst ..."
    Start-Process -FilePath $inst -ArgumentList @(
        '/quiet', 'InstallAllUsers=0', "TargetDir=$dst",
        'Include_pip=1', 'Include_test=0', 'PrependPath=0', 'Include_launcher=0'
    ) -Wait
}

if (-not (Test-Path $exe)) { throw "python install failed: $exe missing" }
& $exe --version

$pipArgs = @('-m', 'pip', 'install', '-i', 'https://pypi.tuna.tsinghua.edu.cn/simple', '--disable-pip-version-check')
& $exe @pipArgs --upgrade pip
& $exe @pipArgs 'basic-pitch[onnx]'

$check = 'import basic_pitch, onnxruntime, librosa, pretty_midi; print("basic_pitch OK", onnxruntime.__version__, librosa.__version__)'
& $exe -c $check
