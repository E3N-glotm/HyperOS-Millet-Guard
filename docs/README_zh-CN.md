# HyperOS Millet Guard 中文说明

Millet Guard 是一个面向 Xiaomi/Redmi/POCO HyperOS/MIUI 的 Magisk 模块，用于把**用户自定义应用**持续维护在 `MILLET_NO_RESTRICT_APP` 中，而不是关闭整个 Millet/Greeze。

## v2.0.1 修复

v2.0.1 修复了一个脚本执行权限导致的 GMS limiter 失效问题：部分 ZIP 解压/安装路径可能把辅助脚本落成 `0644`，此前会导致 `reconcile.sh` 无法直接执行，从而出现 `MILLET_NO_RESTRICT_APP` 已正确写入、但 `mGmsLimitEnabled` 仍为 `true` 的情况。

新版本在安装时显式设置脚本权限，内部调用统一通过 `/system/bin/sh` 执行，并在 `service.sh` 启动时自愈事件监听与核心辅助脚本的执行位。实机已用 `reconcile.sh`、`milletctl` 人为降为 `0644` 的方式回归验证，仍能把 GMS limiter 自动恢复为 `false`，且不会删除其他来源的 Millet 白名单条目。

## v2.0.4 高 CPU 竞态修复

v2.0.4 修复了 `reconcile.sh` 锁所有者检查中的一个窄竞态：旧逻辑在确认 PID 和 `/proc/<pid>/stat` 启动时间后，还会用 Toybox `tr` 读取 `/proc/<pid>/cmdline`。如果目标进程恰好在文件打开后退出，受影响的 HyperOS/Toybox 组合会让 `tr` 对 `read() = ESRCH` 无限重试，造成一个 CPU 核心长期接近满载。

新逻辑不再读取 `cmdline`，锁身份只使用 PID + 内核启动时间 ticks；这已经足以识别 PID 复用。`/proc/<pid>/stat` 也改为 shell 内建 `read` 一次读取，进程在竞态窗口退出时直接失败并按 stale lock 处理，不再产生外部 procfs 读取进程。CI 增加了对应回归测试。

## v2.0.5 FCM DNS 分层自愈

v2.0.5 针对一次实机夜间故障重构了 FCM 自愈判定：原始 MCS 连接先因 heartbeat timeout 关闭，随后 GMS 自己的 `gtalk_connection` 事件进入 `UNKNOWN_HOST`。旧版 Guard 只要直接向 sing-box 配置的上游 DNS 执行 `nslookup mtalk.google.com` 成功，并且目标 `5228-5230` 可达，就会把问题误判为 GMS/MCS 卡死并 `SIGTERM gms.persistent`；然而这条直接查询绕过了 GMS 实际使用的 Android Resolver 路径，因此连续重启并不能修复 `UNKNOWN_HOST`。

v2.0.5 增加了 Android libc/netd resolver 判定，并读取近期 `gtalk_connection` event log；其中 connection error `3` 按 `UNKNOWN_HOST` 处理。只要近期存在该错误，或 Android Resolver 当前不能解析 mtalk，就**禁止重启 GMS**。在系统确实提供可用 resolver cache flush 接口时可限频尝试；不支持的命令不会再被当成成功。解析恢复后还会等待 300 秒稳定期，避免 DNS 刚恢复就立即触发一次无意义重启。自 v2.0.7 起，不再把 direct `nslookup` 当成独立的上游 DNS 证据，因为 Box 的 DNS hijack 本身可能再次截获这次查询；只有 Android 自己先成功解析出 mtalk 地址后，才继续验证 TCP `5228-5230` 可达性。

此外，`fcm_guard.sh` 有 PID + `/proc/<pid>/stat` start-time 的单实例锁，防止 2 分钟轮询和 Whetstone 事件监听同时进入自愈流程。模块会记录当前 GMS UID；若恢复出厂或重装后 UID 改变，会先清理模块记录的旧 UID 规则。v2.0.7 对 `BOX_LOCAL` 的读取和写入统一等待 xtables lock，并且不再在正常检查中通过“删光再插一条”进行重复规则归一化，以免和 Box 自己的链重建互相竞争。

## v2.0.6 GMS 重连闹钟丢失自愈

2026-09-05 的实机故障进一步暴露了第二层问题：05:00 左右 MCS 因心跳超时进入 `UNKNOWN_HOST` 后，GMS 自己先正常执行了多轮 `GCM_RECONNECT`；最后一次约在 05:18。随后 GcmService 内部仍显示 `Reconnect Scheduler Alarm` 已经逾期数小时，但 Android AlarmManager 中已经不存在对应的 `GCM_RECONNECT` pending alarm。也就是说 GMS 认为自己已经安排了下一次重连，而系统实际上没有可触发的重连闹钟，最终形成约 8 小时断联。v2.0.5 在 DNS 异常期间正确避免了反复杀 GMS，但只做 DNS flush 并等待 GMS 自己重连，无法修复这个“重连调度器丢闹钟”的死锁。

v2.0.6 增加软重连层：当 GcmService 的内部重连期限已经明显逾期，或持续断线超过 5 分钟且 AlarmManager 中没有 `GCM_RECONNECT` 时，Guard 会限频发送一次 GMS 原本应由 AlarmManager 投递的 `com.google.android.intent.action.GCM_RECONNECT`。它不会杀死或重启 Play services；在本次故障现场手工发送同一事件后，原 `gms.persistent` PID 保持不变，并在 8 秒内重新建立 `mtalk.google.com:5228` 连接。DNS 不健康时仍禁止硬重启，软重连最多每 5 分钟触发一次，用于重建 GMS 自己的 backoff/alarm 状态。

## v2.0.7 xtables 与 DNS 路径加固

2026-09-11 的连续审计定位到两个确定问题。第一，旧版 `fcm_rule_count()` 直接执行 `iptables -S BOX_LOCAL` 且不等待 `/system/etc/xtables.lock`。当 Android/netd/Box 正在持锁时，读取会立即失败；stderr 又被丢弃，后续 `awk` 会输出 `0`，于是 Guard 把一次锁竞争误判成“FCM bypass 不存在”，插入重复规则，下一轮又看到 `2`。v2.0.7 对 Box 链的读取/写入统一使用有界 `iptables -w`，读取失败时 fail-closed；若 Box 自己也维护同一条精确 FCM 规则，会先短暂等待原生重建完成，只在规则持续缺失时补一条。

第二，Android 16 上 `ndc resolver flushnet` 可输出 `500 0 Command not recognized`，但 `ndc` 自身退出码仍为 `0`。v2.0.6 因此会把实际没有发生的 DNS flush 记录成成功。v2.0.7 同时验证返回文本和退出码，遇到 `Command not recognized`、binder transaction failure 等情况明确按“不支持”处理。

同一轮实机对照还证明：此前给 FCM 固定使用的 `61.139.2.69` 在蜂窝网络上稳定，但在当时 Wi-Fi 上完全直连失败；临时完全绕开 Box DNS hijack 后，`223.5.5.5`、`119.29.29.29`、`114.114.114.114` 均能直接成功。因此 FCM DNS 不应盲目固定运营商 DNS，必须分别验证实际使用的 Wi-Fi 和蜂窝路径。

另外，定制 Box 网络监控的 `/data/adb/box/run/net.heal.lock` 从 9 月 3 日起成为永久 stale lock，同时 `net.signature` 卡在 `__offline__`。仓库在 `extras/box-for-root/net.inotify` 提供经过加固的第三方兼容脚本：在任何 iptables 操作前获取 PID + start-time 锁，先 debounce 并重新采样，然后**先提交稳定 network signature，再执行一次 Box restart**。这样 restart 自己产生的 route/rule event 再进入 handler 时已经看到相同 signature，会立即 no-op，从结构上切断网络回环。该脚本不会由 Millet Guard 静默覆盖到其他用户的 Box 安装。

## 核心思路

- 用户只维护 `/data/adb/millet_guard/packages.list`。
- 模块记录自己上一次管理过哪些包。
- 更新时只撤销“自己上一次加的条目”，绝不清空系统或其他模块的条目。
- 再把当前配置中的包加入有效 no-restrict 列表。
- SettingsProvider 发生变化时通过 `inotifyd` 事件驱动自愈。
- 每 5 分钟做一次低频保险检查。
- 如果配置包含 `com.google.android.gms`，额外 best-effort 关闭已知的 Xiaomi GMS 专用 limiter。
- 内部辅助脚本采用权限鲁棒的调用方式，并在安装/启动阶段恢复所需执行权限。
- FCM 断线时优先区分 Android DNS 故障与 GMS 进程卡死；DNS 异常期间不重启 GMS。
- FCM 自愈入口单实例运行；Box 的精确 FCM UID bypass 使用 xtables 等待并仅在持续缺失时自愈，不在正常检查中反复删插。

## 添加应用

```sh
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl add com.tencent.mm'
```

## 删除应用

```sh
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl remove com.tencent.mm'
```

## 查看状态

```sh
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl status'
```

## 最近任务上划后仍允许 FCM 唤醒（v2.0.8，可选）

部分 HyperOS 版本会把“从最近任务上划应用”实现成真正的 `force-stop`。这会把 Android 包状态设置成 `stopped=true`。此时即使 Google Play 服务已经收到有效的高优先级 FCM，系统仍会记录 `Failed to broadcast to stopped app ...`，直到用户再次手动打开应用。

Millet Guard v2.0.8 提供一个独立、默认关闭的兼容功能。它只监听原因**明确为 `SwipeUpClean`** 的 ActivityManager force-stop 事件；对加入专用名单的包，仅清除 `stopped` 标志，不重新打开界面，也不恢复刚刚被清掉的进程或最近任务卡片。这样后续 FCM 仍可按 Android 正常机制重新拉起应用。

例如为微信启用：

```sh
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl swipe-add com.tencent.mm'
```

查看或移除：

```sh
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl swipe-list'
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl swipe-remove com.tencent.mm'
```

专用名单位于：

```text
/data/adb/millet_guard/swipe_keepalive.list
```

该功能与 `packages.list` / `MILLET_NO_RESTRICT_APP` 相互独立。默认名单为空，不会改变其他应用行为。

为避免破坏用户真正的“强行停止”意图，该功能**不会**处理应用信息页“强行停止”、`am force-stop`、一键清理或其他非 `SwipeUpClean` 原因。上述操作仍会正常留下 `stopped=true`。

`setPackageStoppedState()` 的 Binder transaction 编号不会写死；模块从当前手机自身的 `framework.jar` 动态解析，并与 `ro.build.fingerprint` 一起缓存，系统升级后会重新发现。

## v2.0.9 SwipeUpClean 日志缓冲区修复

真实最近任务上划验收发现 v2.0.8 还有一个集成缺陷：事件 worker 只监听了 logcat 的 `main` buffer，但当前 HyperOS 会把决定性的 `ActivityManager: Force stopping ... : SwipeUpClean` 写入 `system` buffer。因此手工注入同格式事件时 helper 能正常清除 `stopped`，真实上划后却可能完全收不到事件，随后 GMS 会记录 `Failed to broadcast to stopped app`。

v2.0.9 同时监听 `main` 与 `system`。匹配条件仍严格限定为 `SwipeUpClean`，不会扩大到应用信息页“强行停止”、`am force-stop` 或其他清理原因。

## 注意

加入 no-restrict 的应用可能增加后台运行和耗电。只添加确实需要可靠后台执行的应用。

该机制与 Android 原生 DeviceIdle/Doze 白名单不是一回事。
