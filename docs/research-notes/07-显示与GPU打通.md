# 07 - 显示打通与 GPU 加速落地

真机系统（p60p）显示链路打通，桌面成功渲染；GPU 加速（express GPU → 宿主 NVIDIA）落地。

## 显示打通的过程

### 三层修复

1. **加载层（exit 127）**：devhost 缺 `libhdf_host.z.so`。该库在模拟器镜像 `/system/lib64/chipset-sdk-sp/`（模拟器镜像是扁平布局 + system 子目录的双布局），真机 system 里此库在真机 vendor。注入真机 vendor 版后 127 消失
2. **驱动层（exit 255）**：6.0 版 libhdf_host 与 6.1 驱动不匹配。直接把 system 的 HDF 三件套换成 6.1 → **storage_daemon exit 127**（真机二进制对 6.1 库符号不兼容）→ 回滚
3. **隔离方案（成功）**：OHOS musl **忽略 LD_LIBRARY_PATH**（wrapper 脚本法无效），但 musl 命名空间 ini 的 `[section.dir.map]` 按**二进制所在目录**分场景：`/vendor/bin` → acquiescence 场景，`/system/bin` → systemscence 场景，各场景有独立 lib.paths
   - 模拟器 vendor 建 `/lib64/hdf61/` 放 6.1 HDF 三件套
   - `/bin/hdf_devhost` 改名为 `hdf_devhost.bin`，原路径放同名二进制（wrapper 保留无害）
   - 真机 system 的 `/system/etc/ld-musl-namespace-aarch64.ini`：`[acquiescence]` 的 `namespace.default.lib.paths` **首位**插入 `/vendor/lib64/hdf61`
   - 效果：devhost（/vendor/bin）独享 6.1 HDF 环境；system 分区二进制（/system/bin）完全不感知，继续用 6.0

### 结果

- composer_host（显示驱动宿主）存活，render_service（6.0 真机版）通过模拟器 vendor 的 display_composer HDI 完成合成
- 模拟器截图实证：完整桌面（状态栏/设置/图库/文件/日历/壁纸/dock）
- 残余：pin_auth_host 仍 exit 127（指纹驱动宿主，与显示无关，待查）

## GPU 加速调研与落地

### 调研结论

| 组件 | 真机系统 (6.0) | 模拟器系统 (6.1) |
|------|----------------|------------------|
| EGL 分发层 | `/system/lib64/libEGL.so`（EglWrapper 架构） | 同架构 |
| **GPU 实现层** | 真机 vendor `/vendor/lib64/chipsetsdk/libEGL_impl.so` + libGLESv1/2/3_impl（**麒麟 GPU 专用**） | 模拟器 system `/system/lib64/lib*_impl.so`（**express GPU 专用**） |
| gralloc/buffer | 真机版 | 模拟器 vendor display_buffer HDI（显示打通后已在用） |

关键点：OHOS 的 libEGL.so 是 wrapper，实现层 `lib*_impl.so` 由 musl 搜索路径解析。当前 /vendor 是模拟器 vendor（无 impl），真机麒麟 impl 又驱动不了 express GPU → render_service 之前走 CPU（skia）软渲染。

### 落地（一次性成功）

往 p60p system `/system/lib64/` 注入模拟器的 4 个实现库：
`libEGL_impl.so / libGLESv1_impl.so / libGLESv2_impl.so / libGLESv3_impl.so`（system_lib_file 标签，0644）

验证证据：
- render_service 进程 maps：`libEGL_impl.so`、`libGLESv1/2/3_impl.so` 全部已加载
- 宿主 qemu.log：`eglCreateContext: EGLDisplay(...), EGLContext(...)` —— guest 的 EGL 上下文创建直达宿主 NVIDIA GPU（GBM/EGL）
- 桌面截图正常（GPU 路径渲染）

### 工作量复盘（对照事先调研）

| 预估项 | 实际 |
|--------|------|
| 注入 4 个 impl 库 | 确实一步成功（ABI 兼容，EglWrapper 6.0↔6.1 无变化） |
| ABI 不匹配时换 libEGL.so/libGLESv3.so | 未触发 |
| gralloc 兼容 | 无额外工作（display_buffer HDI 本就是模拟器 vendor 的） |
| Vulkan（可选） | 未做：libvulkan.so 还是真机版，ArkUI 主路径用 GLES，暂不需要 |

**结论：GPU 加速实际工作量 ≈ 注入 4 个文件 + 一次重启，风险点在 EglWrapper 分发表的跨版本兼容性（本次侥幸兼容）。**

## 当前系统状态总览

- 显示：✅ GPU 硬件渲染（express GPU → 宿主 NVIDIA RTX A2000）
- hdc root：✅（`hdc tconn 127.0.0.1:5555`）
- 已知小残项：pin_auth_host 127（指纹）、hiview 255（日志守护，/log 目录缺失）、部分真机分区挂载告警
