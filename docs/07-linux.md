# 七、换到 Linux：不是翻译，是换一套机制

Windows 上那套是「补丁」：探针、守卫、回退脚本。Linux 上更省事的方向是「隔离」。
逐项对应，附等价写法。前提是你已经在 Linux 上跑起来过一个常驻 agent（或者任何常驻服务）。

---

## 1. 保活探针 → systemd timer + oneshot

Windows 那边是 `check-health.ps1` + 计划任务每 5 分钟。Linux：

`/etc/systemd/system/agent-health.service`

```ini
[Unit]
Description=agent channel health probe

[Service]
Type=oneshot
ExecStart=/opt/agent/health-check.sh
```

`/etc/systemd/system/agent-health.timer`

```ini
[Unit]
Description=probe every 5 min

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload && systemctl enable --now agent-health.timer
```

- `Persistent=true` 就是 Windows 的「错过计划开始时间就尽快启动」：关机期间错过的触发，开机补一次。
- **别用 `Restart=always` 兜「进程活着但通道死了」**。探针要探**接口**（HTTP 返回码），不是探进程在不在。进程在、端口通、但不回话，这状态 `Restart=always` 一辈子发现不了。

## 2. 版本守卫 → 别拦了，直接锁住

Windows 上很别扭：客户端自己下载升级包，只能事后把 `*.zip` 改名（`version-guard.ps1`）。
Linux 上有更直接的锁：

- **目录权限锁**：二进制装到 `/opt/app/versions/<ver>`，属主 root，跑服务的用户只读 → 它根本写不进去。
- **包管理器锁**：`apt-mark hold <pkg>` / `dnf versionlock add <pkg>`。
- **容器锁**：镜像钉 digest（`image@sha256:...`），tag 变了解析结果也不变。

真要从下载目录里拦（有些客户端绕过包管理器自己下载），`inotifywait` 对 `update-guard.ps1`：

```bash
inotifywait -m -e create,moved_to --format '%w%f' /var/lib/agent/updates |
while read -r f; do
  case "$f" in
    *.zip) mv "$f" "$f.disabled"
           echo "$(date '+%F %T') blocked $f" >> /var/log/agent-guard.log ;;
  esac
done
```

配一个 unit 常驻即可；注意它自己别写进被监视的目录，否则自己触发自己。

## 3. 回退 → 版本目录 + 符号链接，秒级切

Windows 的 `revert.ps1` 干四件事：备份配置 → 缺目录从备份拷回 → 改版本指针 → 废安装包。
Linux 上换个结构，回退变成改一条链接：

```
/opt/app/versions/1.2.3/     # 每个版本一个目录，永不原地覆盖
/opt/app/versions/1.2.4/
/opt/app/current -> versions/1.2.4
```

```bash
ln -sfn /opt/app/versions/1.2.3 /opt/app/current
systemctl restart app
```

两条前提，缺一个就白搭：

1. **配置不能放在版本目录里**（放 `/etc/app/`）。否则回退连配置一起退回去，可能更糟。
2. **服务启动路径必须走 `current`**。Unit 里写死 `/opt/app/versions/1.2.4/app` 的话，切链接毫无意义。

## 4. 进程树那一课，Linux 是另一种死法

Windows 上是「后代踩原生崩溃，整条链被收掉」。
Linux 没有作业对象，但 systemd 默认 `KillMode=control-group`：`systemctl stop app` 会把 cgroup 里**所有**进程杀掉 —— 包括你从 app 里 fork 出来的 ffmpeg、推理进程。

两条硬规矩：

- 重活别从服务进程里 fork。用独立的 transient unit：

```bash
systemd-run --user --unit=heavy-$(date +%s) \
  -p MemoryMax=8G -p CPUQuota=300% \
  /opt/app/heavy.sh
```

- `MemoryMax` 顺手把「内存吃满 → 原生崩溃（`0xc0000005` 那类）」变成「这个 unit 被 OOM 收掉」，宿主不受影响。这一步比 Windows 上任何补丁都干净。

## 5. 定时任务补跑：cron 不会补

- **cron 不补跑**，错过就是没了。要补就 `systemd timer` + `Persistent=true`。
- 必须用 cron 的场合（老系统、容器里没 systemd），加一条 `@reboot` 补偿脚本，自己判断「今天这次跑没跑过」，用 `.last_run` 文件存日期：

```bash
#!/bin/sh
today=$(date +%F)
[ "$(cat /var/lib/appjob/.last_run 2>/dev/null)" = "$today" ] && exit 0
/opt/app/job.sh && echo "$today" > /var/lib/appjob/.last_run
```

- Linux 没有 Windows 那个 `0x41303`「从未运行」的结果码可以用来查。等价信号是：`journalctl -u app-job --since today` **一条都没有**。任务列表里 unit 是 `active (waiting)`，跟 Windows 的 `State=Ready` 一样，什么都不代表。

---

> 两边最大的差别：
> Windows 问「它崩了以后谁来救」，Linux 问「怎么让它崩了也崩不到别人」。
> 前者靠补丁和探针，后者靠 cgroup、权限和符号链接。