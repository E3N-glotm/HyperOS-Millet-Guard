# Millet Guard · HyperOS 后台保活与 FCM 自愈

**语言：简体中文（当前） | [English](README_EN.md)**

面向小米 HyperOS 的 Magisk 模块，用于**按应用维护后台免冻结白名单**，并提供针对 Google FCM 的有限自愈功能。不会全局关闭 Millet/Greeze，也不会强制所有应用常驻。

**当前版本：v2.1.4** · [下载与历史版本](https://github.com/E3N-glotm/HyperOS-Millet-Guard/releases) · [详细中文变更记录](docs/README_zh-CN.md)

## 主要功能

- 维护 `Settings.System.MILLET_NO_RESTRICT_APP` 中用户指定的应用；不覆盖其他模块或系统创建的条目。
- 通过 `inotifyd` 事件驱动同步，并辅以低频安全核查，避免持续高频轮询。
- 针对 Google Play 服务，按实际接口尝试解除小米特有的 GMS 限制。
- FCM 监控先读取 GMS 的 `GcmService` 状态，确认 Android DNS 与 MCS 连接后再考虑恢复；对系统自身可恢复的临时故障不反复重启。
- 对心跳超时、丢失重连与部分微信后台停止状态做窄范围处理；不清除微信数据或随意刷新 Token。
- v2.1.4 增加只读能力报告，识别当前系统是否提供 DeviceIdle、设置服务及 Greeze 相关接口，不按 HyperOS 版本字符串硬性限制。

## 安装与配置

1. 从 [Releases](https://github.com/E3N-glotm/HyperOS-Millet-Guard/releases) 下载 Magisk ZIP 并安装，随后重启。
2. 按需要编辑用户名单 `/data/adb/millet_guard/packages.list`，每行一个完整 Android 包名。
3. 在 Root 终端运行：

```sh
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl list'
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl add com.tencent.mm'
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl remove com.tencent.mm'
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl status'
```

模块只管理属于它的白名单条目。移除名单条目，不应清除由其他软件维护的条目。需要查看系统能力时，使用 Magisk 的**操作**功能。

## FCM 使用说明

- 它与 AdGuard Home、代理工具或 LSPosed FCM Hook **不是同一个功能**；FCM 收发仍依赖 Google Play 服务、实际 DNS/网络路径及应用自身注册状态。
- 日志显示 `Connected=true` 只能证明当时存在连接，不能证明锁屏数小时后的微信消息必然及时送达。
- 应用豁免可能增加后台唤醒与耗电；建议只加入真正需要实时通知的应用。
- 若 Box/sing-box 的网络路由本身不可达，请先修复网络；本模块不会替代代理连接管理。

## 兼容性与回退

依据实际 Settings、Greeze 与网络接口检测能力；部分 OEM 接口缺失时相应功能会跳过。不同设备和固件的后台策略不一定相同。停用/卸载后重启即可停止模块管理；用户名单保存在 `/data/adb/millet_guard/`，需要彻底清理时请先备份后再处理。

[微信 FCM 刷新辅助应用](https://github.com/E3N-glotm/HyperOS-Millet-Guard/releases) 为独立工具，不建议将其当作常规定时重注册方案。

## 项目说明

由 E3N 维护。完整实现、自动化测试与历史问题详见仓库脚本、CI 和 [中文技术记录](docs/README_zh-CN.md)。
