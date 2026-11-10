<#
.SYNOPSIS
    宿主客户端版本回退：把版本号指针指回可用版本，缺目录就从备份拷回。

.DESCRIPTION
    前置条件：
      1. 完全退出宿主客户端（脚本会检查进程，在跑就拒绝执行）
      2. 事先把"可用版本的整个程序目录"做过一次备份

    做四件事：
      1. 备份当前的版本配置文件（config.json）
      2. 目标版本目录不存在 -> 从备份拷回
      3. 把 baseVersion / curVersion 指回目标版本，清空 readyVersion 等升级状态
      4. 把残留的 *.zip 安装包全部作废

    用 -DryRun 先看它要干什么，不会动任何文件。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File revert-host.ps1 `
        -VersionsDir "C:\Program Files\YourApp\versions" `
        -TargetVersion "1.2.3" `
        -BackupDir "D:\backup\app-versions\1.2.3" -DryRun

.EXAMPLE
    # 确认无误后去掉 -DryRun 真跑
#>
param(
    [Parameter(Mandatory = $true)][string]$VersionsDir,
    [Parameter(Mandatory = $true)][string]$TargetVersion,
    [Parameter(Mandatory = $true)][string]$BackupDir,
    [string]$ConfigName = "config.json",
    [string[]]$ProcessNames = @("QQ", "QQEX"),
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
function Say($m) { Write-Host $m }

if (-not (Test-Path $VersionsDir)) { Say "[x] 版本目录不存在：$VersionsDir"; exit 1 }

# 0) 进程检查
$running = Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue
if ($running) {
    Say "[x] 宿主客户端正在运行（$($running[0].ProcessName)），请先完全退出再运行本脚本。"
    exit 1
}

$cfgPath = Join-Path $VersionsDir $ConfigName
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$dst = Join-Path $VersionsDir $TargetVersion

if ($DryRun) {
    Say "[dry] 版本目录：$VersionsDir"
    Say "[dry] 目标版本：$TargetVersion"
    Say "[dry] 备份来源：$BackupDir（存在：$(Test-Path $BackupDir)）"
    Say "[dry] 目标目录已存在：$(Test-Path $dst)"
    Say "[dry] 配置文件存在：$(Test-Path $cfgPath)"
    Get-ChildItem $VersionsDir -Filter "*.zip" -File -ErrorAction SilentlyContinue | ForEach-Object { Say "[dry] 将作废：$($_.Name)" }
    Say "[dry] 以上为预览，未改动任何文件。"
    exit 0
}

# 1) 备份配置
if (Test-Path $cfgPath) {
    Copy-Item $cfgPath "$cfgPath.bak-$stamp" -Force
    Say "[1] 已备份 $ConfigName"
}

# 2) 恢复程序目录
if (-not (Test-Path $dst)) {
    if (-not (Test-Path $BackupDir)) { Say "[x] 备份目录不存在：$BackupDir"; exit 1 }
    Copy-Item -Path $BackupDir -Destination $dst -Recurse -Force
    Say "[2] 已从备份恢复程序目录 $TargetVersion"
} else {
    Say "[2] 程序目录已存在，跳过"
}

# 3) 改版本指针
if (Test-Path $cfgPath) { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $cfg = [pscustomobject]@{} }
$props = @{
    baseVersion      = $TargetVersion
    curVersion       = $TargetVersion
    prevVersion      = ""
    readyVersion     = ""
    readyInstaller   = ""
    unzipRetryCount  = 0
}
foreach ($k in $props.Keys) {
    if (-not $cfg.PSObject.Properties[$k]) { $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $props[$k] }
    else { $cfg.$k = $props[$k] }
}
$cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $cfgPath -Encoding UTF8
Say "[3] $ConfigName 已指回 $TargetVersion"

# 4) 作废残留安装包
Get-ChildItem $VersionsDir -Filter "*.zip" -File | ForEach-Object {
    $newName = $_.FullName + ".disabled"
    if (-not (Test-Path $newName)) { Rename-Item $_.FullName $newName; Say "[4] 已作废：$($_.Name)" }
}

Say ""
Say "[ok] 完成。现在可以启动宿主客户端（应为 $TargetVersion），随后启动你的网关。"