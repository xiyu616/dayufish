# 八、三个脚本真跑一遍：输出原样贴

不是"应该输出什么"，是**刚才真跑出来的**。跑的时候现场有两个可用的对照：
一个活的通道（探活能过）、一个死端口（必然失败）、一个正在运行的宿主（回退必须被拦）。

环境：Windows 10 / PowerShell 5.1 / 2026-11-10 11:19。

---

## 1. `health-check.ps1`：活着的时候，它什么都不说

```
PS> health-check.ps1 -Root .\r1 -TokenFile .\token.txt
（没有任何输出）
```

活动结束后 `health-state.json`：

```json
{
    "restarted": 0,
    "lastAlert": "",
    "fail": 0
}
```

**这就是设计**：正常时按 1/96 概率才写一行"正常"，其余时间完全静默。计划任务每 5 分钟跑一次，
日志一年也不会被噪音撑爆。判断"它到底工作没工作"，看 `health-state.json` 的 `fail` 和 `restarted`，
别看日志有没有新行。

## 2. `health-check.ps1`：探一个死端口，连跑两次

```
PS> health-check.ps1 -Root .\r2 -ProbeUrl http://127.0.0.1:3999/get_login_info
PS> health-check.ps1 -Root .\r2 -ProbeUrl http://127.0.0.1:3999/get_login_info
```

`health.log`：

```
2026-11-10 11:19:00 探测失败 第1次：无法连接到远程服务器
2026-11-10 11:19:02 探测失败 第2次：无法连接到远程服务器
2026-11-10 11:19:02 拉起脚本不存在或未配置：
```

三条日志把节奏说全了：

1. 第 1 次失败**只记一行**，不惊动任何人（偶发超时不该弹窗）。
2. 第 2 次到达 `FailRestartAt`，开始尝试拉起 —— 这里没配 `-Launcher`，所以它明说"未配置"，没瞎起东西。
3. 再失败到第 3 次才会弹窗 + 提示音（本次没跑到那一步，免得真弹）。

注意它探的是**接口**（一次真实 HTTP 请求），不是进程。进程在、端口通、内部卡死，这种"活着但不回话"
状态，查进程列表是查不出来的。

## 3. `version-guard.ps1`：已经拦下的包，它不重复干活

```
PS> version-guard.ps1 -VersionsDir I:\qq\versions -KeepVersion 9.9.30-48762
```

`version-guard.log`：

```
2026-11-10 11:19:07 正常，无新包
```

目录现状：

```
9.9.30-48762                            （当前版本，保留）
9.9.30-48762-9.9.37-54395.zip.disabled  （11/06 下载的升级包，已被改名作废）
channel.json / config.json / setting.json
```

`*.zip` 全改成 `*.zip.disabled` 之后，客户端就装不上了。它做的是"下载了也白下载"，不是"阻止下载"——
因为 NTQQ 根本没有关闭自动更新的开关（`Ctrl+,` 里翻不到，菜单里也没有）。

## 4. `revert-host.ps1 -DryRun`：被自己的进程检查挡住

```
PS> revert-host.ps1 -VersionsDir I:\qq\versions -TargetVersion 9.9.30-48762 `
                    -BackupDir I:\qq-versions-backup\9.9.30-48762 -DryRun
[x] 宿主客户端正在运行（QQ），请先完全退出再运行本脚本。
exit=1
```

**这是对的，不是失败**。改版本指针时客户端还开着，配置文件会被它自己回写覆盖，改了等于没改，
严重的情况会留下一个既不是新版也不是旧版的目录。所以脚本第一件事就是查进程，在跑就退出。

真实的回退流程因此是：退出客户端 → 跑 `-DryRun` 看一眼 → 去掉 `-DryRun` 真跑 → 启动客户端验证。

---

## 附：这次实测冒出来的两个坑

这两个都是**跑的过程中才发现的**，写完文档之前根本不知道：

### 坑一：脚本假定 Root 目录存在

第一次 `-Root .\r1` 直接炸：

```
Add-Content : Could not find a part of the path '...\r1\health.log'.
```

`-Root` 是个目录时，脚本用它拼日志和状态文件，但没建目录。真实部署里 `$PSScriptRoot` 永远存在，
所以部署时看不见 —— 但换目录、换机器、第一次跑就炸。已修，一行：

```powershell
$null = New-Item -ItemType Directory -Force -Path (Split-Path $log), (Split-Path $statePath)
```

### 坑二：带中文的 .ps1 必须存成 UTF-8 **with BOM**

修脚本时我用无 BOM 的 UTF-8 写回，下一次运行直接报：

```
The string is missing the terminator: ".
```

原因：Windows PowerShell 5.1 读无 BOM 的 `.ps1` 会按系统 ANSI 代码页解码，中文被拆成乱码，
乱码里恰好吞掉一个引号 → 整个文件语法错误。**加 BOM 就好**（PowerShell 7 不挑，5.1 挑）。

所以：改这类脚本时用 `New-Object Text.UTF8Encoding($true)`，别用 `$false`。
这个坑在别的地方（JSON 配置、日志）无害，但 `.ps1` 会直接跑不起来。

---

> 一句话：三个脚本的"正常输出"大多是**空**。保活和守卫这种东西，安静才是工作状态；
> 要确认它还活着，看状态文件里的计数，别指望日志天天有新行。