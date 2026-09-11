# Box For Root 网络状态机兼容补丁

这个目录是 **Box For Root / sing-box 的独立兼容补丁**，用于保存 2026-09-11 在实机上验证通过的网络状态机修复。它与 Millet Guard 主模块刻意解耦：Millet Guard 的 `main` / Release **不会自动覆盖** `/data/adb/box/scripts/net.inotify`。

## 为什么单独保存

实机曾出现两个危险问题：

1. `/data/adb/box/run/net.heal.lock` 成为永久 stale lock，网络状态机失去恢复能力；
2. 旧 handler 在加锁前就执行 iptables 修改，并且 restart 自己产生的 route/rule 事件可能再次进入 handler，存在形成网络回环风暴的条件。

本补丁的关键顺序是：**获取锁 → debounce → 重新采样 → 先提交新的 network signature → 再刷新规则/只重启 Box 一次**。因此 restart 自己产生的事件再次进入时看到的是相同 signature，会直接 no-op。

## 恢复出厂后重新部署

前提：已经重新获得 Root，并已经安装、配置好 Box For Root，使 `/data/adb/box/scripts/box.service` 可用。建议先确认 Box 自身能正常启动，再部署本补丁。

1. 从 GitHub 仓库切换到分支：

   `compat/box-for-root-network-stability`

2. 把整个 `extras/box-for-root/` 目录放到手机任意可读位置，例如：

   `/sdcard/Download/box-for-root-compat/`

3. **先只读预检**：

   ```sh
   su -c 'sh /sdcard/Download/box-for-root-compat/install.sh --check'
   ```

   必须看到 `PRECHECK PASS`。这一步不会停止 watcher、不会替换文件、不会修改 iptables，也不会重启 Box。

4. 预检通过后，在 root shell 中正式安装：

   ```sh
   su
   sh /sdcard/Download/box-for-root-compat/install.sh
   ```

   安装器会：

   - 检查当前 Box 目录和 `box.service`；
   - 用 Android `/system/bin/sh -n` 验证补丁语法；
   - 备份原始 `net.inotify` 和现有状态文件到 `/data/adb/box/backups/net-context-compat-时间戳/`；
   - 精确停止旧 `net.inotify` / `net.monitor` watcher；
   - 原子替换 `net.inotify`；
   - 删除旧 stale lock；
   - 按当前真实 IPv4 接口初始化 `net.signature`；
   - 只执行一次 Box restart；
   - 恢复 watcher。

5. 安装完成后执行：

   ```sh
   su -c 'sh /sdcard/Download/box-for-root-compat/verify.sh'
   ```

   正常情况下应看到：

   - `net.inotify` 语法 PASS；
   - `net.inotify watcher = 1`；
   - `net.monitor.pid` 指向的父进程存活且命令正确；`ip monitor | while` 会额外产生一个同 argv 的管道子 shell，这是正常现象；
   - 没有 stale `net.heal.lock`；
   - `net.signature` 不是 `__offline__`；
   - sing-box 正在运行。

## 回滚

安装器会把最近一次备份路径写入：

`/data/adb/box/run/net-context-compat.last-backup`

恢复最近一次原版：

```sh
su -c 'sh /sdcard/Download/box-for-root-compat/rollback.sh latest'
```

也可以指定具体备份目录：

```sh
su -c 'sh /sdcard/Download/box-for-root-compat/rollback.sh /data/adb/box/backups/net-context-compat-20260911-xxxxxx'
```

## 与 FCM DNS 的关系

这个分支只负责 **Box 网络状态机 / watcher / anti-loop**，不会自动修改 sing-box 的 `config.json`。此前实机上 `61.139.2.69` 在蜂窝可用、但在当时 Wi-Fi 路径失败，因此 FCM 专用 DNS 后来改成了经过实测的 `223.5.5.5`。恢复出厂后仍应根据当时 Wi-Fi 与蜂窝网络分别验证 DNS，不要把某个运营商 DNS 永久写死当成通用值。

Millet Guard 的 FCM 自愈、GMS no-restrict、Android resolver 检查仍属于 Millet Guard 主分支/Release，本分支不替代它们。

## 兼容性边界

本补丁实机验证环境为 Android 16、当前 Box For Root 布局（`/data/adb/box/scripts/`）以及 sing-box 1.12.0。以后如果 Box For Root 大版本升级并更改了 `net.inotify`、`net.monitor`、`box.service` 的路径或职责，**不要直接强行安装旧补丁**；先运行 `install.sh --check`，再比较新版 Box 的网络脚本结构。

## 已验证的实机行为

2026-09-11 的验收中，Wi-Fi 消失、网络从“Wi-Fi + 蜂窝”切换到“仅蜂窝”时，补丁只触发 **一次** Box restart；之后稳定蜂窝状态下 60 秒观察期间 sing-box PID 不再变化，stale lock 不存在，`net.inotify` watcher 保持 1 个，`net.monitor.pid` 的父进程保持稳定，没有形成 restart 回环。

