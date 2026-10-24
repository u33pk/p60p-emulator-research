# 04 - SELinux 规则注入（获取完整 root 权限）

解决 root 后 hdc shell 仍被 SELinux 限制（`/sys`、`/proc/cmdline`、`/data`、dmesg 均 Permission denied）的问题。

## 结论（最终方案）

1. 删除 vendor 分区中的**预编译策略**，强制开机走 cil 编译路径
2. 向 **`system_common.cil`** 注入 `(typepermissive sh)` 和 `(typepermissive hdcd)`
3. 重启后 hdc shell 所在 sh 域变为 permissive，`setenforce 0` 也可用（整机 permissive，重启后恢复 enforcing，但 sh/hdcd 域保持 permissive）

## 排查过程（关键事实）

### 1. 策略加载器行为（libload_policy.z.so 字符串 + kernel.log 实证）

ramdisk 里的 `lib64/libload_policy.z.so` 决定加载方式，日志在实例 `Log/kernel.log`：

```
Found precompiled policy, load /vendor/etc/selinux/prebuild_sepolicy/developer_policy   ← 默认走这里
No precompiled policy found, compile it                                                  ← 删掉预编译后走这里
Add policy /system/etc/selinux/system_common.cil    ← 编译输入清单
Add policy /vendor/etc/selinux/vendor_common.cil
...
```

- **预编译策略位置**：`/vendor/etc/selinux/prebuild_sepolicy/policy.31` 和 `developer_policy`（debuggable=1 时优先加载后者）
- **system.img 里没有二进制策略**，`/system/etc/selinux/targeted/` 只有 contexts
- 编译时机：开机 1.6s 左右由 init fork `/system/bin/secilc` 完成（**设备自带 secilc**，无需 host 安装）

### 2. cil 文件加载清单与防篡改机制

开机实际编译的 cil（从 kernel.log 逐一确认）：

| 文件 | 有无 sha256  sidecar | 是否被加载 |
|------|------|------|
| system_common.cil | **无** | ✅（**唯一可注入点**） |
| system_developer.cil | 有 | ✅（修改后是否被跳过未验证，有 sidecar 风险） |
| vendor_common.cil / vendor_developer.cil | 无 | ✅ |
| public_common.cil / public_developer.cil | 无 | ✅ |
| compatible_developer/40.cil | - | ✅ |
| **system.cil** | 有 | ❌ **不加载**（无论内容是否匹配 sidecar，实测跳过） |

> 第一次注入把 `typepermissive` 写进 system.cil —— 完全无效，kernel.log 显示它根本不在编译列表。

## 具体操作

```bash
# 1. 复制 vendor.img，删除预编译策略（原文件不动）
cp --sparse=always phone_all_arm/vendor.img tmp/rooted_image/vendor.img
printf 'rm /etc/selinux/prebuild_sepolicy/policy.31\nrm /etc/selinux/prebuild_sepolicy/developer_policy\n' > tmp/debugfs_cmds3.txt
debugfs -w -f tmp/debugfs_cmds3.txt tmp/rooted_image/vendor.img

# 2. 注入 permissive 规则到 system_common.cil
printf '\n(typepermissive sh)\n(typepermissive hdcd)\n' >> tmp/selinux/selinux/system_common.cil

# 3. 写回 system.img（debugfs rm+write+ea_set+sif，mode 0644，补 selinux xattr）
#    （命令文件 tmp/debugfs_cmds4.txt，含还原 system.cil 为原版）

# 4. imageRoot 软链换成修改副本（system.img + vendor.img）
cd tmp/image_root_rooted/system-image/HarmonyOS-6.1.1/phone_all_arm
ln -sfn <WORKSPACE>/tmp/rooted_image/vendor.img vendor.img   # system.img 此前已换

# 5. 重启实例验证
```

## 验证结果

```bash
hdc shell "cat /proc/cmdline"     # ✅ 内核命令行可读（顺带拿到完整 cmdline，对真机镜像实验有用）
hdc shell "ls /data/"             # ✅ app chipset data healthsport hmos4 ...
hdc shell "dmesg | tail"          # ✅ 内核日志可读
hdc shell "setenforce 0"          # ✅ SELINUX:  switch to permissive（重启后恢复，但 sh/hdcd 域仍 permissive）
hdc shell "ls -Z /system/bin/sh"  # ✅ u:object_r:sh_exec:s0
```

- 整机 enforce=0 是运行时状态；`typepermissive` 写进了编译后的策略，**重启后依然生效**
- sh 域 permissive = AVC 只记录不拦截，等效于该域在 enforcing 系统里拥有全部权限

## 顺带有用的发现

内核 cmdline（真机镜像实验可能用得上）：
```
earlycon=pl011,0x9000000 console=ttyAMA0 init=/bin init default_boot_device=a003e00.virtio_mmio
root=/dev/ram0 rw ohos.required_mount.system=/dev/block/vda@/usr@ext4@ro,barrier=1@wait,required ...
```
注意模拟器把 **system 分区挂载到 `/usr`**（不是 /system）。
