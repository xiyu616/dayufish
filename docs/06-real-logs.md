# 六、三个现场：日志原样贴出来

> 不是教程。是事故当天的原始证据，只把机器路径和账号打了码。
> 每个现场三段：**现象 / 原样日志 / 我当时怎么读的**。最后是现在的防法。

---

## 现场一：子进程崩了，把宿主一起带走

**现象**：23:25 忽然不说话。界面上报「应用无法启动或已意外停止」。下一个可用时间点是 00:28。

**原样日志**（事件查看器 → Windows 日志 → 应用程序）：

```
来源: Application Error   事件 ID: 1000
Faulting application name: python.exe, version: 3.12.14150.1013
Faulting module name: c10.dll, version: 0.0.0.0, time stamp: 0x67185a8e
Exception code: 0xc0000005
Fault offset: 0x000000000006ce14
Faulting process id: 0xF1C
Faulting application path: C:\Users\<you>\...\python.exe
Faulting module path: D:\tools\comfy-venv\Lib\site-packages\torch\lib\c10.dll
```

紧跟一条 WER 1001：

```
Event Name: APPCRASH
P1: python.exe   P2: 3.12.14150.1013   P3: 6a96deaf
P4: c10.dll      P5: 0.0.0.0           P6: 67185a8e
P7: c0000005     P8: 000000000006ce14
```

**怎么读**

- `0xc0000005` 是**访问冲突**，不是业务异常。torch 这种带原生算子的库，内存/显存一紧就给你这个码；堆栈帮不上忙，看的是**峰值**。
- `P5: 0.0.0.0` —— 这个 DLL 没写版本号。这种通常能稳定复现，先从显存下手，别急着翻业务代码。
- 真正致命的不是崩，是**崩完宿主也没了**：那个 python 是从宿主自己的 shell 里拉起来的，属于它的后代进程。后代踩原生崩溃，Windows 默认把整条作业链一起收掉。

**现在的防法**

1. 重型子进程一律脱离进程树起（`pythonw` / `DETACHED_PROCESS` / 计划任务），别从交互 shell 拉。
2. 先 512 出草稿确认构图，再放大；别一步上大尺寸。
3. 用完 `Stop-Process`，别让它挂着占显存。

---

## 现场二：任务「是 Ready」，但它从来没跑过

**现象**：早上该出的东西没出。任务列表里 State 干干净净写着 `Ready`。

**原样输出**

```
TaskName       : <task>
LastRunTime    : 2026/11/10 10:03:04
LastTaskResult : 267011
NextRunTime    : 2026/11/11 9:05:00
```

**怎么读**

- `267011` 不是错误，是 `0x00041303` = `SCHED_S_TASK_HAS_NOT_RUN`，「从来没运行过」。它长得像错误码，其实是「没跑」，所以不会有人报警。
- 注册时少了 `-Settings`：`State=Ready` + `NextRunTime` 都正常 → 看起来健康；而机器关机/休眠错过 09:05 之后，默认**不补跑**。
- 一行把它转成十六进制，直接对 `SCHED_S_*` 表：

```powershell
Get-ScheduledTaskInfo -TaskName <task> | % { '{0} 0x{1:X}' -f $_.LastTaskResult, $_.LastTaskResult }
```

**现在的防法**：注册时必须显式给 settings，且要带 `-StartWhenAvailable`。完整命令见 [03-missed-schedule.md](03-missed-schedule.md) 末尾。

---

## 现场三：脚本里的时间闸形同虚设

**现象**：盘后随手试跑一个盘中脚本。它没停，一路等到收盘，拿当前价当竞价价，凭空写进一笔持仓。

**原样日志**（错跑那一次，已改名 `.bak` 留证）：

```
[11-09 18:34:58] 模式=auction 候选: 159530, 516620, ...
[11-09 18:34:59] 买入 ... x35500 @1.337 (竞价半仓 高开+1.98%) 累计35500股
[11-09 18:34:59] 9:35 现价1.339 vs 开盘1.337
[11-09 18:34:59] 买入 ... x35400 @1.339 (站上开盘价加满) 累计70900股
```

三条日志在同一秒。脚本里 `wait_until(9:35)` 发现时间已过就**立即返回**，所有等待点一次穿透，几十秒里把一整天的流程跑完。

**怎么读**

- 带 `wait_until` 的脚本必须有**运行前的时间闸**（8:30~15:05 之外直接退出）。否则「等」不是等，是「立刻」。
- 它还认不出 `--help`：任何未知参数都当正常参数，继续跑完整流程。加参数解析，本身就是一道误触保护。
- 再加一个 `--dry`：写状态那一步直接跳过，试跑不留痕。

**现在的防法**（同一个脚本改完的三条）

```python
if len(sys.argv) > 1 and sys.argv[1] in ('-h', '--help'):
    print(USAGE); sys.exit(0)
if len(sys.argv) > 1:                      # 不认识的参数，一律不跑
    print(USAGE); sys.exit(2)

def save_state():
    if DRY:                                # --dry 不留痕
        return
    ...

now = datetime.now()
if not (830 <= now.hour * 100 + now.minute <= 1505):
    log(f'不在交易时段({now:%H:%M})，只读退出')
    return
```

---

## 附：三个命令，十秒拿到证据

```powershell
# 1. 最近两小时崩了什么
Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddHours(-2)} |
  Where-Object { $_.ProviderName -in 'Application Error','Windows Error Reporting' } |
  Select-Object TimeCreated,ProviderName,Id,Message

# 2. 任务到底跑没跑（结果转十六进制）
Get-ScheduledTaskInfo -TaskName <task> | % { '0x{0:X}' -f $_.LastTaskResult }

# 3. 进程在不在、是谁拉起来的
Get-CimInstance Win32_Process |
  Where-Object Name -match 'python|node' |
  Select-Object ProcessId,ParentProcessId,Name,CommandLine
```

> 一条原则：**先拿证据，再猜原因。**
> 这三次我一开始都猜错了（怪网络、怪模型、怪数据接口），翻完日志才发现全在自己这侧。