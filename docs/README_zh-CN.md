# HyperOS Millet Guard 中文说明

Millet Guard 是一个面向 Xiaomi/Redmi/POCO HyperOS/MIUI 的 Magisk 模块，用于把**用户自定义应用**持续维护在 `MILLET_NO_RESTRICT_APP` 中，而不是关闭整个 Millet/Greeze。

## 核心思路

- 用户只维护 `/data/adb/millet_guard/packages.list`。
- 模块记录自己上一次管理过哪些包。
- 更新时只撤销“自己上一次加的条目”，绝不清空系统或其他模块的条目。
- 再把当前配置中的包加入有效 no-restrict 列表。
- SettingsProvider 发生变化时通过 `inotifyd` 事件驱动自愈。
- 每 5 分钟做一次低频保险检查。
- 如果配置包含 `com.google.android.gms`，额外 best-effort 关闭已知的 Xiaomi GMS 专用 limiter。

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
