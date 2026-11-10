# 让一个 AI 在你自己电脑上活着

> 不聊模型能力。聊**它怎么不掉线、怎么记事、怎么不烧钱**。
> 全部来自一个人在 Windows 上把 AI 常驻进 QQ、真实跑了两个月踩出来的坑。
> 里面每个脚本、每个数字，都是事故现场拿回来的。

## 先说结论：难点不在 prompt，在运维

大多数人搭自托管 AI，第一周卡在这三件事：

1. **它会死** —— 宿主升级、进程崩、机器重启，任何一样都能让它失联，而且是悄悄地死。
2. **它会忘** —— 上下文一压缩，昨天定的事就没了，然后重新问你一遍。
3. **它很贵** —— 一次会话几十个工具调用，账单一节比一节高。

> 第一次搭？先看 [从零开始：一个周末让它跑起来](docs/00-from-zero.md)，按顺序做，每步都有验收标准。

下面五个坑，每个都是我真踩进去、再爬出来的。

---

## 五个坑

| # | 坑 | 一句话 |
| --- | --- | --- |
| 1 | [宿主一升级，桥接就哑](docs/01-host-upgrade.md) | 别堵升级，保证能退回去 |
| 2 | [它安静地死掉，没人知道](docs/02-silent-death.md) | 它坏了要自己喊人 |
| 3 | [重启后定时任务不补跑](docs/03-missed-schedule.md) | 补跑是补救，脚本内部还要判一次时间 |
| 4 | [子进程崩了把宿主带走](docs/04-process-tree.md) | 重型子进程必须踢出进程树 |
| 5 | [重复花钱、重复犯错](docs/05-burn-and-memory.md) | 省钱 = 别让它重复发现昨天已知的事 |

## 脚本

三个都跑过，不是伪代码。都参数化了，改几个参数能用在别的服务上。

### `scripts/health-check.ps1`

探活 + 自动拉起 + 弹窗告警。每 5 分钟跑一次。

```powershell
powershell -ExecutionPolicy Bypass -File health-check.ps1 `
    -ProbeUrl "http://127.0.0.1:3000/get_login_info" `
    -TokenFile "C:\ai\token.txt" `
    -Launcher "C:\ai\start-gateway.bat" `
    -Root    "C:\ai"
```

节奏：1 次失败只记日志 → 连续 2 次尝试拉起 → 连续 3 次弹窗喊人。
每个故障周期最多重启 2 次，防死循环。

### `scripts/version-guard.ps1`

宿主客户端的升级包拦截器。发现新下载的 `*.zip` 就改名作废，并记录出现的新版本目录。
建议计划任务每 6 小时一次。

```powershell
powershell -ExecutionPolicy Bypass -File version-guard.ps1 `
    -VersionsDir "C:\Program Files\YourApp\versions" `
    -KeepVersion "1.2.3"
```

### `scripts/revert-host.ps1`

真被升级了就回退：备份配置 → 缺目录从备份拷 → 版本指针指回旧版 → 作废残留安装包。
**先跑 `-DryRun`**。

```powershell
powershell -ExecutionPolicy Bypass -File revert-host.ps1 `
    -VersionsDir "C:\Program Files\YourApp\versions" `
    -TargetVersion "1.2.3" `
    -BackupDir "D:\backup\app-versions\1.2.3" -DryRun
```

## 上手顺序

别一上来就装脚本。按 [`docs/checklist.md`](docs/checklist.md) 走：
通道 → 凭证 → 备份 → 探活 → 拉起 → 拦截 → 回退 → 定时任务 → 记忆。
每一步都有验证方法。

## 我踩过最贵的两个坑（给新来的人）

**第一个：以为"进程在"就是"活着"。**
它会在你以为它好好的时候安静地死掉。早上该报的东西没报，
你晚上才发现。损失的不是钱，是那一整天的信任。

**第二个：备份了但没试过恢复。**
出事那天打开备份目录，文件都在，然后发现少了一个隐藏文件，
起不来。**没验证过的备份等于没有备份。**

## 状态

v0.1。骨架 + 三个脚本 + 五篇事故复盘 + 上手清单。
接下来补：真实日志截图、计划任务注册的完整命令、多平台（Linux）对应写法。

如果你也在这条路上踩了别的坑，欢迎开 issue —— 我大概率也踩过。
还有这是我大肥鱼自己写的，坑也是自己踩的。
