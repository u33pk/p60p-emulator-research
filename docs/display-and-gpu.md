# 显示、GPU 与 boot-complete

## DGLES 单一实现

手机镜像中的四个 `*_impl.so` 若作为独立副本存在，各自会有独立的 emutls 状态。一个模块写入“当前 GL 上下文”，另一个模块却读到空值，Skia 随之初始化失败。

最终方案让四个 impl 链接共同指向 `libdgles.z.so`，并在 enforcing 下给链接本身恢复 `system_lib_file` 标签。仅验证 root shell 能 `dlopen` 不够，必须确认 render_service 域也能加载。

## 显示 HDI 与缓冲

手机显示 HDI 面向真实显示驱动，模拟器需要对接 `/dev/express_display` 的官方实现和 proxy。`libcomposer.z.so` 保留手机版本，避免 ABI 混用引发内核 panic。

 enforcing 下还出现过：分配成功但 `/dev/teleport_express` mmap 被拒绝。只为 open/ioctl 放行不够，`render_service → dev_file:chr_file` 还需要 `map`。这是 `configs/selinux-additions.cil` 中的关键规则。

## host 为什么一直转圈

guest 已绘制并不代表 host 已呈现。宿主需要收到 boot-complete 才撤销开机占位图并进入 live-present。手机系统中 QemuParams 曾因两类问题没有工作：

1. 二进制依赖与系统库不匹配，exit 127；
2. 真机 SELinux 策略没有 `emu_param` 类型，setexeccon 在 exec 前失败。

最终采用兼容的官方 QemuParams，并补全 emu_param 域、设备标签、参数标签和 vendor 服务配置。这样 guest 在系统真正就绪后自行通知 host，不再用 LD_PRELOAD 猜时间强制触发。

## 启动顺序

`bootevent.composer_host.ready` 后才启动 render_service，`bootevent.wms.fullscreen.ready` 后才停止 bootanimation。这避免 RS 找不到显示后端，以及桌面未就绪时提前撤动画。

## 为什么不用 Vulkan

本次手机镜像缺少可直接使用的 Mali Vulkan ICD。简单加入模拟器 Vulkan ICD 会把 RS 引到外部内存互操作路径，而 host 环境不具备对应扩展。移除这条多余路径后，OpenGL ES 桌面正常，不能把“没有 Vulkan”误判成“没有 GPU 加速”。
