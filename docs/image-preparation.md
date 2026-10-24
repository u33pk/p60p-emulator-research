# 镜像解包、修改与实例组装

## 重要说明

本仓库不包含镜像，也没有把“原始 ROM → 最终镜像”包装成已验证的一键命令。下列步骤是本次实验的可复核记录。不同 ROM 的分区格式、库 ABI、SELinux 类型和二进制偏移都可能不同，必须逐步核对。

全程可在项目工作区完成，不需要挂载到 `/mnt`，也不需要使用系统 `/tmp`。`debugfs` 可以直接离线修改 ext4，无需 sudo。

## 1. 准备输入

需要：

- 手机升级包及与其匹配的解包工具；
- 官方模拟器镜像，本次关键适配组件主要来自 6.0.1；
- 与 Emulator 构建匹配的 SDK/HDC；
- `erofs-utils`、e2fsprogs、Python 及其解包依赖。

手机包解包示例：

```sh
mkdir -p work/unpack
python3 build_update.py "$PWD/work/unpack" /path/to/rom-dir -unpack update.bin
```

输出根目录必须预先创建。工具参数以其 `README_zh.md` 和源码为准。

## 2. 检查文件系统并保留基准

```sh
fsck.erofs --extract=work/pristine-system --no-sbcrc /path/to/unpacked/system.img
file /path/to/unpacked/system.img
```

本次手机 system 是 EROFS，而最终模拟器启动使用约 6.4 GiB 的 ext4 工作副本。不要假设只改扩展名或 fstab 就能通用启动。转换时必须保留完整目录、符号链接、UID/GID、mode 和 SELinux xattr，并逐项抽查。

保留一份未修改的提取树和原始镜像，用于比较和回滚。不要把研究工作直接做在唯一原件上。

## 3. 应用适配

按 [patches/README.md](../patches/README.md) 处理：

1. 提取模拟器显示、DGLES、HUKS、softbus 和 QemuParams 组件；
2. 统一四个 EGL/GLES impl 链接；
3. 对正确版本的 `librender_service.z.so` 应用已校验补丁；
4. 合并 graphic job、shared bundles、namespace、HDC 和 SELinux 增量；
5. 配置 emu_param 的文件/参数标签；
6. 保留手机原版 `libcomposer.z.so`。

`configs/` 是增量示例，不应盲目覆盖整个分区中的同名文件。合并后先验证 JSON，再写回镜像。

## 4. debugfs 写回与元数据

典型操作：

```sh
debugfs -R 'dump /system/etc/param/ohos.para work/ohos.para' work/system.img
# 修改 work/ohos.para 后，用 rm + write 写回

debugfs -w -R 'rm /system/etc/param/ohos.para' work/system.img
debugfs -w -R 'write work/ohos.para /system/etc/param/ohos.para' work/system.img
debugfs -w -R 'sif /system/etc/param/ohos.para mode 0100500' work/system.img
debugfs -w -R 'sif /system/etc/param/ohos.para uid 0' work/system.img
debugfs -w -R 'sif /system/etc/param/ohos.para gid 0' work/system.img
```

恢复 SELinux 标签时，`ea_set` 的值是包含末尾 NUL 的标签字节。不同文件不能用同一个标签：

- 普通 system etc 文件通常为 `system_etc_file`；
- 共享库和四个 GL 链接为 `system_lib_file`；
- `system_common.cil` 为 `system_file`；
- `hdcd`、`hdf_devmgr`、`QemuParams` 分别是自己的 exec 标签。

写文件后漏恢复 xattr 是 enforcing 下 `exec EACCES`、dlopen 失败和启动循环的常见原因。

## 5. 组装 imageRoot

以官方模拟器 imageRoot 为基线，在工作区建立新目录。kernel、ramdisk、userdata 等保留模拟器来源，只把研究用的 system/vendor/sys_prod 工作副本链接或复制进来。不要污染官方目录。

本次最终组合使用经适配的模拟器 vendor/sys_prod，并把真机身份参数合并进实际生效的 variant。参数优先级大致为默认层、factory、机型变体、区域变体和 vendor；只改 `hw_defaults.para` 默认层可能被 bind mount 的机型目录遮住。

不要把真机全部图形参数照搬。本次剔除 hybridrender、GpuApitype、app_comp、模糊、HDR、exagear/binfmt 等手机专用项，否则 render_service/foundation 可能进入 critical panic。

## 6. 创建实例与分辨率

可以用 Emulator 的 `-create` 和 `-screen "1220 2700 444 6.67"` 创建实例，osVersion 字符串必须与所选镜像匹配。已有实例则把 `configs/p60pro-screen.ini` 中的字段合并进 `config.ini`。

修改基镜像后，关闭实例并删除该实例对应的 system/vendor/sys_prod qcow2 覆盖层，否则旧覆盖层会继续遮住新基镜像。不要误删 userdata，除非明确要重置全部数据。

最后配置 `config.sh`，使用 `scripts/run_emulator.sh` 启动。首次启动后用 `scripts/smoke_check.sh` 检查，而不是只看进程是否存在。
