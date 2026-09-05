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

新版把“远端链路可达”和“GMS 实际解析链路健康”拆开判断。直连 DNS + TCP 探针仍用于确认外部 FCM 路径，但同时通过 Android libc/netd resolver 解析 `mtalk.google.com`，并读取近期 `gtalk_connection` event log；其中 connection error `3` 按 `UNKNOWN_HOST` 处理。只要近期存在该错误，或 Android Resolver 当前不能解析 mtalk，就**禁止重启 GMS**，优先按 5 分钟限频尝试对活动 resolver NetId 执行 DNS cache `flushnet`，然后保留 GMS 进程让其自行重连。解析恢复后还会等待 300 秒稳定期，避免 DNS 刚恢复就立即触发一次无意义重启。

此外，`fcm_guard.sh` 现在有 PID + `/proc/<pid>/stat` start-time 的单实例锁，防止 2 分钟轮询和 Whetstone 事件监听同时进入自愈流程。`BOX_LOCAL` 中模块维护的精确 `GMS UID + TCP 5228-5230 + RETURN` 规则也会自动去重为一条，并记录当前 UID；若恢复出厂或重装后 GMS UID 改变，会先清理模块记录的旧 UID 规则再建立新规则。

## v2.0.6 GMS 重连闹钟丢失自愈

2026-09-05 的实机故障进一步暴露了第二层问题：05:00 左右 MCS 因心跳超时进入 `UNKNOWN_HOST` 后，GMS 自己先正常执行了多轮 `GCM_RECONNECT`；最后一次约在 05:18。随后 GcmService 内部仍显示 `Reconnect Scheduler Alarm` 已经逾期数小时，但 Android AlarmManager 中已经不存在对应的 `GCM_RECONNECT` pending alarm。也就是说 GMS 认为自己已经安排了下一次重连，而系统实际上没有可触发的重连闹钟，最终形成约 8 小时断联。v2.0.5 在 DNS 异常期间正确避免了反复杀 GMS，但只做 DNS flush 并等待 GMS 自己重连，无法修复这个“重连调度器丢闹钟”的死锁。

v2.0.6 增加软重连层：当 GcmService 的内部重连期限已经明显逾期，或持续断线超过 5 分钟且 AlarmManager 中没有 `GCM_RECONNECT` 时，Guard 会限频发送一次 GMS 原本应由 AlarmManager 投递的 `com.google.android.intent.action.GCM_RECONNECT`。它不会杀死或重启 Play services；在本次故障现场手工发送同一事件后，原 `gms.persistent` PID 保持不变，并在 8 秒内重新建立 `mtalk.google.com:5228` 连接。DNS 不健康时仍禁止硬重启，软重连最多每 5 分钟触发一次，用于重建 GMS 自己的 backoff/alarm 状态。

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
- FCM 自愈入口单实例运行，Box 的精确 FCM UID bypass 自动去重。

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

## 注意

加入 no-restrict 的应用可能增加后台运行和耗电。只添加确实需要可靠后台执行的应用。

该机制与 Android 原生 DeviceIdle/Doze 白名单不是一回事。
