# 坑 2：它会在你以为它活着的时候，安静地死掉

## 现象

早上八点，该报的信号没报。
打开电脑一看：**进程还在。** 但消息一条都没发出来。
再一看任务状态：Ready。日志最后一行是昨晚十一点。

没有人知道它什么时候死的。

## 为什么会"悄悄死"

常驻程序不是"进程在"就叫活着。至少这几种状态，你在任务管理器里分不出来：

- 进程卡在一个永远不返回的 API 调用上
- 协议端的 WebSocket 断了，但进程没退
- 端口还在听，内部 session 已经失效
- 凭证过期了，每条消息都发不出去，但都在"succeed"
- 单线程事件循环被一个死循环占满

**判断"活着"的唯一标准是：它能不能完成一次真实动作。**

## 解法：探活、拉起、喊人

三段式，缺一不可。

### 1) 探活要打真实接口

不要 `Get-Process` 看进程名。打一次协议端的真实接口：

```powershell
$r = Invoke-RestMethod -Uri "http://127.0.0.1:3000/get_login_info" `
        -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 6
if ($r.retcode -ne 0) { throw "通道异常" }
```

注意 **401/403 也要按失败算**，但日志里要写清"服务在、凭证不对"。
这两个故障的修法完全不同，混在一起会白白排查半天。

### 2) 连续失败才拉起，而且要限次数

单次失败可能只是网络抖一下。我的阈值：

| 连续失败次数 | 动作 |
| --- | --- |
| 1 次 | 只记日志 |
| 2 次 | 尝试拉起重启 |
| 3 次 | 弹窗 + 提示音，喊人 |

每个故障周期最多自动重启 2 次。**不设上限的话，一个坏掉的配置能让它整夜重启。**

### 3) 喊人要用"会自己消失"的窗口

最烦的告警是弹了一屏、等你回来点确定。用 `MessageBoxTimeoutW`，60 秒自己关：

```powershell
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MB {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int MessageBoxTimeoutW(IntPtr hWnd, string text, string caption, uint type, uint timeout, uint notifymode);
}
"@
[MB]::MessageBoxTimeoutW([IntPtr]::Zero, "通道挂了", "告警", 0x30, 60000, 0)
```

配套一声系统提示音。人不在屏幕前也能听见。

### 4) 日志别刷屏

每 5 分钟探一次，一天 288 行"正常"，日志就没法看了。
我让它在正常时按 **1/96 概率**才写一行。异常必写，恢复必写。这样一个月后翻日志，全是有效信息。

## 完整脚本

`scripts/health-check.ps1`。参数化过了，改五个参数就能用在你自己的服务上：

```powershell
powershell -ExecutionPolicy Bypass -File health-check.ps1 `
    -ProbeUrl "http://127.0.0.1:3000/get_login_info" `
    -TokenFile "C:\ai\token.txt" `
    -Launcher "C:\ai\start-gateway.bat" `
    -Root    "C:\ai"
```

注册成计划任务，每 5 分钟一次（注册时记得一起设 `StartWhenAvailable`，见坑 3）。

## 一句话教训

**它坏了要自己喊人。** "等人发现"等于"坏了一整晚"。