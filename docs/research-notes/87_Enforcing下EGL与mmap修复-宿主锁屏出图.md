# 87. Enforcing 下 EGL 与 mmap 修复，宿主锁屏真实出图（2026-10-24）

## 结论

在 `getenforce=Enforcing`、root shell 可用的状态下，P60P 真机 system + 模拟器 vendor 已在宿主窗口真实显示锁屏：壁纸、时间、日期、状态栏和底部按钮均可见，不再是黑屏或开机转圈。

尚未完成：guest `snapshot_display` 仍报 `displayId 0 invalid`，`uinput` 仍提示坐标超界，`aa start` 设置仍失败；因此本轮不是最终交互验收通过。

## 两项根因与最小修复

### 1. GL 实现链接没有 SELinux 标签

`/system/lib64/libEGL_impl.so` 等四个链接指向同一个 `libdgles.z.so`，但链接自身是 `unlabeled`。普通 root shell 的 dlopen 成功不能证明 render_service 域也能加载；旧日志明确为：

```
render_service/OpenGLWrapper: dlopen failed ... libEGL_impl.so: No such file or directory
InitializeEglContext: Failed to create EGLDisplay
CreateEGLSurface: EGL context has not initialized
```

对以下四个链接补 `u:object_r:system_lib_file:s0`：

- `libEGL_impl.so`
- `libGLESv1_impl.so`
- `libGLESv2_impl.so`
- `libGLESv3_impl.so`

修复后 `/proc/<render_service>/maps` 确认只加载 `/system/lib64/libdgles.z.so`，并拿到宿主转发的 `OpenGL ES 3.0 (4.6.0 NVIDIA 595.71.05)`。

### 2. enforcing 策略允许打开 teleport 设备但不允许 mmap

补标签后首个真正的 surface 错误是：

```
allocator_host: ExpressAllocMem ... success
render_service/DISP: ExpressMmap ... Permission denied, size 11784960
Bufferqueue: Map failed, ret:50007000
NativeWindowRequestBuffer: RequestBuffer ret:50002000
DGLES: EGL_BAD_SURFACE, g_handle is null
```

`/dev/teleport_express` 类型为 `dev_file`。`system_common.cil` 原有规则：

```
(allow render_service dev_file (chr_file (read write open getattr ioctl)))
```

缺少 `map`，改为：

```
(allow render_service dev_file (chr_file (read write open getattr ioctl map)))
```

保持 render_service 域为 enforcing，没有恢复显示四域整体 permissive。修复后 `ExpressMmap`、`Map failed`、`EGL_BAD_SURFACE` 均消失，RS 正常绘制，composer 出现 `CommitComposeLayer! 10`。

## RS 版本结论修正

当前出图使用干净归档版 `librender_service.z.so`，md5 `87ccfa650c`：手机原版 + listener 补丁 + 强制 GL 两处 NOP。当前版 `43a30162df` 另有约 20 万字节诊断差异；其 mmap 修复后仍会触发宿主 `gbuffer_id: id 0` / `find null prt`，宿主保持黑屏。

归档版在同时补齐 EGL 链接标签和 `dev_file.map` 后，冷启动约 110 秒即显示锁屏，hdc/shell 正常，boot-complete 为 true。此前“该版本必然令 guest 卡死”的判断不适用于当前修复组合。

## 当前实证

- 宿主截图：`tmp/cleanrs_host.png`
- `getenforce`：`Enforcing`
- `whoami`：`root`
- `bootevent.boot.completed`：`true`
- 宿主 qemu：已收到 `guest os boot completed`
- guest capture：仍 `displayId 0 invalid`
- `uinput -T -m 660 1800 660 900 300`：仍提示坐标超界，画面未解锁
- `aa start -a EntryAbility -b com.huawei.hmos.settings`：仍失败

## 操作注意事项

- debugfs 写入后必须恢复原 SELinux 标签；`system_common.cil` 原标签是 `system_file`，不是 `system_etc_file`。
- 改镜像后删除本实例 qcow2 再冷启动。
- 后续必须同时检查 host 与 guest，并执行上滑、打开设置等实操，不能仅凭一张宿主截图判定完成。
