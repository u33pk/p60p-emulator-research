# 架构与最终方案

## 组合边界

本方案不是把一台手机完整虚拟化，而是混合使用：

- 手机 ROM 的 system 及其中应用、框架、身份参数；
- 官方模拟器的 kernel、ramdisk、userdata 基础镜像；
- 经适配的官方模拟器 vendor/sys_prod；
- 官方 Emulator 的 express 虚拟硬件和 host OpenGL ES 转发。

因此，应用和大部分系统服务来自手机，显示、触控、虚拟块设备和启动握手来自模拟器。麒麟专用驱动、基带、TEE、摄像头、NFC 等并不会因为使用 system 镜像而自动可用。

历史目录名是 P60P，实际 ROM 的 `ALN-AL00` 标识对应 Mate 60 Pro。当前实例另外采用 P60 Pro 的 1220×2700 屏幕参数。这些只是实验组合，不表示硬件身份、证明或全部参数已变成 P60 Pro。

## 启动链

```text
Emulator / kernel / express devices
  → init 挂载 system/vendor/sys_prod/userdata
  → composer_host 建立虚拟显示后端
  → render_service 经 DGLES 使用 host OpenGL ES
  → SceneBoard / WMS 建立桌面
  → bootevent.boot.completed=true
  → QemuParams 向 /dev/express_pipe 发送 boot-complete
  → host 撤销开机动画并呈现 guest 帧
```

关键不是“桌面进程是否存在”，而是每一环都完成：GPU 上下文、显示缓冲、SELinux 标签、mmap、窗口树和 host 呈现门控。

## 最终桌面修复

首启时 BMS 和图标缓存可能正常，但 launcher 的 `gridlayout_info` 仍为空。启动脚本仅在这个表为 0 时写入最小官方入口，等待应用扫描后执行两次 SceneBoard 刷新。系统随后继续补全布局。已有桌面不会被重置。

## 最终显示配置

使用 OpenGL ES，不启用手机镜像中不完整的 Vulkan ICD 路径。最终分辨率是 1220×2700、444 dpi；guest 输入范围和图形缓冲都应为这个尺寸，而不只是 host 窗口缩放。
