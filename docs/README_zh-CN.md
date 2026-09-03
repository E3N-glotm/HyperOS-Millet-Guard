# HyperOS Millet Guard 中文说明

Millet Guard 是一个面向 Xiaomi/Redmi/POCO HyperOS/MIUI 的 Magisk 模块，用于把**用户自定义应用**持续维护在 `MILLET_NO_RESTRICT_APP` 中，而不是关闭整个 Millet/Greeze。

## v2.0.1 修复

v2.0.1 修复了一个脚本执行权限导致的 GMS limiter 失效问题：部分 ZIP 解压/安装路径可能把辅助脚本落成 `0644`，此前会导致 `reconcile.sh` 无法直接执行，从而出现 `MILLET_NO_RESTRICT_APP` 已正确写入、但 `mGmsLimitEnabled` 仍为 `true` 的情况。

新版本在安装时显式设置脚本权限，内部调用统一通过 `/system/bin/sh` 执行，并在 `service.sh` 启动时自愈事件监听与核心辅助脚本的执行位。实机已用 `reconcile.sh`、`milletctl` 人为降为 `0644` 的方式回归验证，仍能把 GMS limiter 自动恢复为 `false`，且不会删除其他来源的 Millet 白名单条目。

## v2.0.4 高 CPU 竞态修复

v2.0.4 修复了 `reconcile.sh` 锁所有者检查中的一个窄竞态：旧逻辑在确认 PID 和 `/proc/<pid>/stat` 启动时间后，还会用 Toybox `tr` 读取 `/proc/<pid>/cmdline`。如果目标进程恰好在文件打开后退出，受影响的 HyperOS/Toybox 组合会让 `tr` 对 `read() = ESRCH` 无限重试，造成一个 CPU 核心长期接近满载。

新逻辑不再读取 `cmdline`，锁身份只使用 PID + 内核启动时间 ticks；这已经足以识别 PID 复用。`/proc/<pid>/stat` 也改为 shell 内建 `read` 一次读取，进程在竞态窗口退出时直接失败并按 stale lock 处理，不再产生外部 procfs 读取进程。CI 增加了对应回归测试。

## 核心思路

- 用户只维护 `/data/adb/millet_guard/packages.list`。
- 模块记录自己上一次管理过哪些包。
- 更新时只撤销“自己上一次加的条目”，绝不清空系统或其他模块的条目。
- 再把当前配置中的包加入有效 no-restrict 列表。
- SettingsProvider 发生变化时通过 `inotifyd` 事件驱动自愈。
- 每 5 分钟做一次低频保险检查。
- 如果配置包含 `com.google.android.gms`，额外 best-effort 关闭已知的 Xiaomi GMS 专用 limiter。
- 内部辅助脚本采用权限鲁棒的调用方式，并在安装/启动阶段恢复所需执行权限。

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
