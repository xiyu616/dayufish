<#
.SYNOPSIS
    常驻 AI 的通道探活：不通就自动拉起，连续不通就弹窗喊人。

.DESCRIPTION
    故意不用"进程在不在"来判断。进程活着但内部卡死、协议端挂了、
    端口被占，这些都表现为"进程还在，人收不到消息"。
    所以探的是"它还能不能回答"，也就是发一次真实请求。

    失败节奏：
      第 1 次失败        -> 只记日志，不惊动
      连续 FailRestartAt 次 -> 尝试拉起一次（每个故障周期最多 MaxRestart 次）
      连续 AlertAt 次    -> 弹窗 + 提示音，人回来一眼能看见

    恢复后自动清零，不刷屏（正常时按 1/96 概率才写一行"正常"）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File health-check.ps1 `
        -ProbeUrl "http://127.0.0.1:3000/get_login_info" `
        -TokenFile "C:\ai\token.txt" `
        -Launcher "C:\ai\start-gateway.bat"
#>
param(
    [string]$Root          = $PSScriptRoot,
    [string]$ProbeUrl      = "http://127.0.0.1:3000/get_login_info",
    [string]$TokenFile     = "",
    [string]$Launcher      = "",
    [string]$LogFile       = "health.log",
    [string]$StateFile     = "health-state.json",
    [int]$FailRestartAt    = 2,
    [int]$AlertAt          = 3,
    [int]$MaxRestart       = 2,
    [int]$TimeoutSec       = 6
)

$ErrorActionPreference = "Continue"
$log = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $Root $LogFile }
$statePath = if ([System.IO.Path]::IsPathRooted($StateFile)) { $StateFile } else { Join-Path $Root $StateFile }
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-Log($msg) { Add-Content -Path $log -Value "$stamp $msg" -Encoding UTF8 }

$state = @{ fail = 0; restarted = 0; lastAlert = "" }
if (Test-Path $statePath) {
    try {
        $raw = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $raw.fail)      { $state.fail = [int]$raw.fail }
        if ($null -ne $raw.restarted) { $state.restarted = [int]$raw.restarted }
        if ($null -ne $raw.lastAlert) { $state.lastAlert = [string]$raw.lastAlert }
    } catch { }
}

# ---------- 1) 探活 ----------
$ok = $false
$detail = ""
try {
    $headers = @{}
    if ($TokenFile -and (Test-Path $TokenFile)) {
        $token = (Get-Content $TokenFile -Raw).Trim()
        if ($token) { $headers["Authorization"] = "Bearer $token" }
    }
    $r = Invoke-RestMethod -Uri $ProbeUrl -Headers $headers -TimeoutSec $TimeoutSec
    # OneBot 类接口成功时 retcode=0；别的接口只要 200 就算通
    if ($null -ne $r.retcode -and $r.retcode -ne 0) { $detail = "retcode=" + $r.retcode }
    else { $ok = $true }
} catch {
    $detail = $_.Exception.Message
    # 401/403 说明服务在、只是没带对凭证 —— 这也是"人收不到消息"，按失败算，但记录清楚
    if ($detail -match "401|403") { $detail = "鉴权失败（服务在，凭证不对）：" + $detail }
}

if ($ok) {
    if ($state.fail -ne 0 -or $state.restarted -ne 0) { Write-Log "恢复正常（之前连续失败 $($state.fail) 次）" }
    elseif ((Get-Random -Maximum 96) -eq 0) { Write-Log "正常" }
    $state.fail = 0; $state.restarted = 0; $state.lastAlert = ""
    $state | ConvertTo-Json -Depth 3 | Set-Content -Path $statePath -Encoding UTF8
    return
}

$state.fail++
Write-Log "探测失败 第$($state.fail)次：$detail"

# ---------- 2) 自动拉起 ----------
if ($state.fail -ge $FailRestartAt -and $state.restarted -lt $MaxRestart) {
    if (-not $Launcher -or -not (Test-Path $Launcher)) {
        Write-Log "拉起脚本不存在或未配置：$Launcher"
    } else {
        $state.restarted++
        Write-Log "尝试自动拉起（第$($state.restarted)次）：$Launcher"
        try {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$Launcher`"" -WindowStyle Hidden
        } catch {
            Write-Log "拉起失败：$($_.Exception.Message)"
        }
    }
}

# ---------- 3) 还不行就喊人 ----------
if ($state.fail -ge $AlertAt) {
    $msg = "常驻 AI 的通道连不上了（连续 $($state.fail) 次探测失败）。`n`n可能原因：宿主客户端升级了 / 网关挂了 / 端口被占。`n`n最近一次错误：$detail"
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    try {
        if (-not ("MB" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MB {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int MessageBoxTimeoutW(IntPtr hWnd, string text, string caption, uint type, uint timeout, uint notifymode);
}
"@
        }
        # 60 秒后自动关闭，不挡人
        [MB]::MessageBoxTimeoutW([IntPtr]::Zero, $msg, "常驻 AI 通道告警", 0x30, 60000, 0) | Out-Null
    } catch {
        Write-Log "弹窗失败：$($_.Exception.Message)"
    }
    $state.lastAlert = $stamp
    Write-Log "已弹窗告警"
}

$state | ConvertTo-Json -Depth 3 | Set-Content -Path $statePath -Encoding UTF8