# 微信 FCM 刷新（WeChat FCM Refresh）

此 Android App 的模块兼容策略（v1.0.2 起）：

1. 优先选择当前已启用的 `fcm_unified_guard/bin/wechat_fcm_refresh.sh`。
2. 若不可用，检查当前已启用的旧版 `gms_millet_guard/bin/wechat_fcm_refresh.sh`。
3. 如果两者都未安装、已禁用、正在移除或不包含脚本，使用 APK 的 `assets/wechat_fcm_refresh.sh` 内置实现。

每次操作都重新检查模块状态，不缓存旧模块路径；禁用或卸载模块不会导致 `helper_missing`。App 内置脚本由 APK 自身提供，只在显式打开 Root 开关并由用户点击操作时运行；「检查当前状态」不会删除任何数据。

「一键清除旧注册并刷新 FCM」会终止微信进程、删除**微信自身**的 Firebase IID/FCM 注册相关文件，并重新打开微信；不会清理聊天数据库或 GMS 全局数据。操作后的 Token 指纹变化不代表腾讯服务器一定确认绑定。

为保持安装覆盖兼容，`com.e3n.wechatfcmrefresh` 包名不变；新 APK 需沿用原 v1.0.1 的签名密钥。

源码在 `src-packed/` 中以 gzip + base64 分卷保存，构建前运行 `sh companion-app/unpack-sources.sh` 恢复 Java 文件，`app/src/main/assets/` 存放可独立运行的脚本资源。构建入口为仓库根目录的 `build-companion.sh`。
