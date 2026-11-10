<#
.SYNOPSIS
    宿主客户端升级守卫：发现新下载的安装包就改名作废，并记下出现的新版本目录。

.DESCRIPTION
    很多宿主客户端（含 Windows 版 NTQQ）没有"关闭自动更新"的开关。
    堵不住它下载，那就让它下载了也装不上：
      - 定时把版本目录里的 *.zip 全部改名成 *.zip.disabled
      - 记录除 KeepVersion 以外出现的版本目录（说明已经被解压了，得准备回退）

    建议用计划任务每 6 小时跑一次。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File version-guard.ps1 `
        -VersionsDir "C:\Program Files\YourApp\versions" `
        -KeepVersion "1.2.3" `
        -LogFile "C:\ai\version-guard.log"
#>
param(
    [Parameter(Mandatory = $true)][string]$VersionsDir,
    [Parameter(Mandatory = $true)][string]$KeepVersion,
    [string]$LogFile = "version-guard.log",
    [switch]$DisableZips = $true
)

$ErrorActionPreference = "Continue"
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$lines = @()

if (-not (Test-Path $VersionsDir)) {
    Add-Content -Path $LogFile -Value "$stamp [x] 版本目录不存在：$VersionsDir" -Encoding UTF8
    exit 1
}

if ($DisableZips) {
    Get-ChildItem $VersionsDir -Filter "*.zip" -File -ErrorAction SilentlyContinue | ForEach-Object {
        $new = $_.FullName + ".disabled"
        if (-not (Test-Path $new)) {
            try {
                Rename-Item $_.FullName $new -ErrorAction Stop
                $lines += "$stamp 作废更新包 $($_.Name) ($([math]::Round($_.Length/1MB,1)) MB)"
            } catch {
                $lines += "$stamp 改名失败 $($_.Name): $($_.Exception.Message)"
            }
        }
    }
}

Get-ChildItem $VersionsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -ne $KeepVersion) { $lines += "$stamp 发现新版本目录 $($_.Name) —— 宿主可能已经升级了" }
}

if ($lines.Count -eq 0) { $lines += "$stamp 正常，无新包" }
$lines | Add-Content -Path $LogFile -Encoding UTF8