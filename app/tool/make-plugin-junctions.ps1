# 用目录联接（junction）替代符号链接，绕过 Windows「开发者模式」限制
# Flutter 只在插件列表变化时强制重建链接；我们先建好，它就不会再去创建 symlink。
$ErrorActionPreference = 'Continue'
$app = 'D:\dsh work region\jianpu2staff\app'
Set-Location $app

$json = node -e "const o=JSON.parse(require('fs').readFileSync('.flutter-plugins-dependencies','utf8'));const l=o.plugins.windows||[];console.log(l.map(p=>p.name+'|'+p.path.replace(/[\\/]+$/,'')).join('\n'));"
$linkDir = Join-Path $app 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Force -Path $linkDir | Out-Null

foreach ($line in ($json -split "`n")) {
    if (-not $line.Trim()) { continue }
    $parts = $line.Split('|')
    $name = $parts[0].Trim()
    $target = $parts[1].Trim()
    if (-not (Test-Path $target)) { Write-Output "SKIP $name (target missing: $target)"; continue }
    $link = Join-Path $linkDir $name
    if (Test-Path $link) { Remove-Item $link -Recurse -Force -ErrorAction SilentlyContinue }
    try {
        New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        Write-Output "JUNCTION $name -> $target"
    } catch {
        Write-Output "FAILED $name : $($_.Exception.Message)"
    }
}
Write-Output "--- result ---"
Get-ChildItem $linkDir -Force | Select-Object Name, LinkType, Target | Format-Table -AutoSize
