# 坑 3：重启之后，定时任务不会补跑

## 现象

机器夜里关机了。早上九点零五分的任务，**根本没触发**。
但去任务计划程序里看，状态写着 `Ready`，看不出任何异常。

任务列表里的 `Last Run Time` 还停在昨天。

## 关键认知：267011

任务计划程序里的 `LastTaskResult = 267011`（十六进制 `0x41303`）不是错误码。

它的意思是：**这个任务从来没有运行过。**

我第一次看到它以为坏了，其实只是"从上次注册到现在还没到点 / 一直被关机挡住"。

同理 `0x41301` 是"正在运行"，`0x0` 才是成功。

## 为什么不会补跑

Windows 计划任务的默认设置是：**到了点，机器不在，就跳过，不补。**
等你开机了，它也不追。

对一个"每天早上 9:05 干一件事"的任务来说，这意味着：只要那天早上机器是关着的，这件事就永远不发生了。

## 解法一：打开 StartWhenAvailable

```powershell
$t = Get-ScheduledTask -TaskName "你的任务"
$t.Settings.StartWhenAvailable      = $true
$t.Settings.DisallowStartIfOnBatteries = $false
$t.Settings.StopIfGoingOnBatteries     = $false
$t.Settings.ExecutionTimeLimit      = "PT1H"
Set-ScheduledTask -TaskName "你的任务" -Settings $t.Settings
```

`StartWhenAvailable` 就是"错过了就尽快补跑"。

顺手关掉三个电池相关的限制 —— 笔记本上这三个默认值是"电池供电就不跑"，
这也是"任务莫名不执行"的经典原因之一。

## 解法二：脚本自己也要有时间闸

光靠计划任务不够。补跑的时候，**补跑的其实是一个"过期的时间点"**。

我的真实事故：一个每天 9:05 跑的竞价任务，某天机器 9:58 才开机，
任务补跑了 —— 但它拿的是"现在的价格"当"9:05 的价格"，直接把一笔假成交写进了账本。

所以脚本里必须有：

```powershell
$now = Get-Date
if ($now.TimeOfDay -lt [TimeSpan]"08:30" -or $now.TimeOfDay -gt [TimeSpan]"15:05") {
    Write-Host "不在有效时段，只读退出"
    exit 0
}
```

**补跑 ≠ 等价于准点跑。** 有外部世界状态的脚本，必须自己判断"现在还算不算数"。

## 解法三：还有个更阴的

参数解析没写好，`--help` 会被当成正常参数，直接走完整流程。
我那个脚本就是这样：打 `--help` 想看用法，结果它真的建了一笔持仓。

任何"会写东西"的脚本，第一段都该是：

```powershell
if ($args -contains "--help" -or $args -contains "-h") { Show-Usage; exit 0 }
# 未知参数一律拒绝，不要默默忽略
```

## 一句话教训

**补跑是补救，不是修复。** 时间敏感的任务，脚本内部必须再判断一次时间。