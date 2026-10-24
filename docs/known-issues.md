# 已知问题

## 账号、支付与设备证明

- 华为账号授权可成功，但应用市场登录因 OUCS 匿名证明/TSMS 凭证失败而终止。
- 设备完整性检测存在 `Local sysIntegrity is empty`、`bad cipher text` 和风险检测超时。
- 依赖 TEE、DRM、设备证书或服务器完整性判定的功能预计不可用或受限。

## 系统与硬件

- 不是完整麒麟手机模拟：基带、摄像头、NFC、传感器和其他真机专用硬件不保证可用。
- GPU 加速走 host OpenGL ES；Vulkan 外部内存互操作路径未打通。
- root 的 `aa`、`bm`、`snapshot_display` 等 CLI 仍可能受 displayId/access-token 限制；系统 UI 启动 APP 和系统截屏是另一条路径。
- 六个域仍为 per-domain permissive，需要继续收敛策略，不能把当前配置用于高安全场景。

## 稳定性与复现

- 启动早期偶发 host heartbeat 看门狗失败，同一镜像重试曾成功；仍需更多冷启动统计。
- Emulator 或 guest 外层后台任务若带自动超时，会连带终止模拟器。长期运行应使用无自动 kill 的托管方式。
- 二进制补丁只对列出的构建有效，没有跨版本自动定位能力。
- 从原始 ROM 生成最终镜像仍有手工步骤和版本核对，不宣称一键复现。
- launcher 的 15 个入口和资源 ID 针对本次应用构建；其他 ROM 需重新生成。

## 身份边界

工作目录历史名称、ROM 的 ALN-AL00 身份和当前 P60 Pro 屏幕参数并不表示同一硬件。`ohos.boot.hardware` 仍可能由 host 注入 `hmos.emulator`。修改显示属性不会改变服务器的设备证明结果。
