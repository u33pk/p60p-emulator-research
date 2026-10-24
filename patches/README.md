# 补丁与版本清单

定位过程、AArch64 替换原则和通用补丁方法见 [Emulator 二进制补丁经验](../docs/patching-experience.md)。

所有二进制补丁都**版本敏感**。先复制文件到自己的工作区，再运行：

```sh
python3 scripts/patch_binary.py patches/<manifest>.json /path/to/working-copy
```

工具检查文件长度、源 SHA-256 和每处原字节，任何一项不符即拒绝修改。不要直接改 SDK 原件，不要把偏移套到其他版本。

## Emulator 签名校验

`emulator-26.0.0.402-signature.json` 对应 Linux aarch64 Emulator 26.0.0.402。`CheckImage` 入口被改为 `mov w0,#0; ret`，用于让自行修改的研究镜像通过本地镜像签名校验。

- 源文件大小：130446408 字节。
- 源 SHA-256：`62dd21c38f6e21e242f66f6c17753dfa445dd4073e072d851d4af41f8ff9ab4e`。
- 只对工作副本应用；启动时通过 `P60P_EMULATOR_BIN` 指向该副本。

这是本地研究适配，不会伪造镜像签名，也不影响华为服务器的设备证明。

## librender_service

`render-service-p60p-6.0.0.108.json` 对应本次 ALN 真机 ROM 的 5805128 字节 `librender_service.z.so`：

- `0x39a2b8`：调用 `RegisterScreenNodeListener`；
- `0x40f504`：NOP 条件分支，始终初始化 EGL；
- `0x40f518`：NOP 条件分支，选择 GL 路径。

源 SHA-256：`893a44c13b877e05fb9a883b405737b74175e6274c12e82646adee07b4a5e427`。已验证补丁文件 SHA-256：`ba575171d3926cc154b1da32a94b04075c1f5a5063931897f7a62b56160fc03f`。

文件偏移与反汇编 vaddr 不同：该库代码段满足 `vaddr = file offset + 0x1000`。清单使用文件偏移。

## 从官方模拟器镜像提取的组件

以下文件不分发，需要由使用者从兼容的官方 6.0.1 模拟器镜像提取并写入手机 system 工作副本：

- `libdgles.z.so`、`libEGL.so`、`libGLESv3.so`、`libegl_effect.z.so`；
- `libdisplay_composer_hdi_impl_1.3.z.so` 和 1.0～1.3 的 display composer proxy；
- `libhuks_engine_core_standard.z.so`、`libhuks_service.z.so`；
- `libdsoftbus_server_plugin.z.so`、`libdsoftbus_service_ext_frame.z.so`、`libsoftbus_server.z.so`；
- `/system/bin/QemuParams`。

以下四个链接必须共同指向唯一的 `libdgles.z.so`，并恢复 `system_lib_file` 标签：

```text
libEGL_impl.so
libGLESv1_impl.so
libGLESv2_impl.so
libGLESv3_impl.so
```

不要把四份独立 EGL/GLES 实现混用，否则 emutls 上下文会分裂。保留手机原版 `libcomposer.z.so`；实验过的 6.0.1 替换版本会触发 panic。

## 文本与策略适配

- `configs/graphic-jobs.snippet.json`：composer 就绪后启动 RS，WMS 全屏后停止 bootanimation。
- `configs/shared-bundles.snippet.json`：登记四个 SceneBoard 依赖包。
- `configs/namespace-prefix.txt`：增加模拟器 HDF 库搜索路径。
- `configs/hdcd.root.cfg`：root HDC 服务定义。
- `configs/selinux-additions.cil`：调试域、显示 mmap 和 QemuParams 域。
- `configs/qemu-params-labels.txt`：文件、设备和参数标签。

其他离线修改：`const.secure=0`、`const.debuggable=1`、启用 HDC USB 模式、`local_code_sign` 的 `ondemand=false`，以及研究环境中 `bm/libbms/libcode_sign_utils` 的本地签名校验适配。后三者的二进制补丁未泛化发布，因为当前只验证了特定构建，不能用统一偏移安全处理其他 ROM。

## 最终研究实例校验值

这些值仅用于识别本次实验产物，仓库不附带对应文件：

```text
MD5  p60p_system.img      95cc8cfd399291e6a3273dcc7ca0fec2
MD5  p60pv2_vendor.img    7ba534406c32ba04bddfe43b2ba4b4f9
MD5  p60pv2_sysprod.img   e0d7cf5b622419f7f32a9b69127cca62
MD5  Emulator             ace992646a7e0f50c432ba45557fe1ef
```
