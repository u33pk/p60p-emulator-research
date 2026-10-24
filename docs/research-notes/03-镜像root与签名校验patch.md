# 03 - 镜像 root 与签名校验 patch

记录对模拟器原版镜像（phone_all_arm）的完整 root 过程：Emulator 签名校验 patch + system.img 免 sudo 离线修改。

## 一、签名校验 patch（Emulator 二进制）

### 定位过程

- 镜像目录的 `image_signature/*.hwp7s` 是各分区的 PKCS#7 签名，启动时由校验线程验证，失败则弹窗并强制关闭模拟器
- r2 + 自扫 adrp/add 引用定位到 `CheckImage` / `CheckSign.c` 相关代码（字符串线索：`verify signature error, code %08x.`、`Check Image Failed`、`The image file has been tampered with...`）
- 校验入口函数 **`fcn.01224374`**（`0x1224374`，源码 `../emulator/emulator-ui/utils/sign/CheckSign.c`）：
  - 读 `.hwp7s` → 解析 PKCS#7 → 验签，**返回 `w0=0` 表示成功**，否则返回错误码（`0x88100001` / `0x88200309` 等）
  - 唯一调用点 `0x1224e84`：只消费返回值 `w0`，`cmp w0,0; b.eq` 决定成功/走"篡改"分支
  - 函数无副作用参数，patch 入口安全

### patch 内容

文件偏移 = 虚拟地址（.text 段恒等映射）。`0x1224374` 处 8 字节：

| 偏移 | 原指令 | 改为 |
|------|--------|------|
| 0x1224374 | `stp x29, x30, [sp, -0xc0]!` (`fd7bb4a9`) | `mov w0, #0` (`00008052`) |
| 0x1224378 | `mov x29, sp` (`fd030091`) | `ret` (`c0035fd6`) |

效果：所有镜像签名校验直接返回成功。

- 原版备份：`tmp/Emulator.orig.20261017`
- patch 后 `-version` 正常（26.0.0.402）
- 注意：**该 patch 对 SDK 目录里的 Emulator 生效于所有实例**（rooted 与后续真机镜像实验共用）

## 二、system.img 修改（免 sudo，debugfs 离线方式）

镜像为 ext4（无 journal，metadata_csum）。`debugfs -w` 无需挂载、无需 root：

```bash
# 1. 复制稀疏副本（原镜像不动）
cp --sparse=always phone_all_arm/system.img tmp/rooted_image/system.img

# 2. 导出要改的文件
debugfs -R 'dump /etc/param/ohos.para tmp/extract/ohos.para' tmp/rooted_image/system.img
# （hdc.para、hdcd.cfg 同理；原版备份在 tmp/orig_backup/）

# 3. 本地修改
# ohos.para:  const.secure=1→0, const.debuggable=0→1
# hdc.para:   persist.hdc.mode.usb "disable"→"enable"（tcp/uart 保持 disable）

# 4. 写回（rm + write + ea_set 补 selinux xattr + sif 恢复 mode 0500）
debugfs -w -f tmp/debugfs_cmds.txt tmp/rooted_image/system.img
```

三个文件原始属性：mode `0500`、root:root、xattr `security.selinux = "u:object_r:system_etc_file:s0"`。写回后全部恢复（xattr 缺末尾 NUL 无影响，内核 SELinux 读取时会自行补零）。

`hdcd.cfg` 整体替换为 root 版（来源 OpenHarmony developtools_hdc `hdcd.root.cfg`，`secon` 用 **`u:r:hdcd:s0`** 而非 `u:r:su:s0`，服务 `disabled:1`，内容存档在 `tmp/hdcd.cfg`）。

## 三、rooted 实例

```
imageRoot  = tmp/image_root_rooted   （除 system.img 外全部软链到 phone_all_arm）
instancePath = tmp/deployed_rooted
实例名     = HarmonyOS_Phone_rooted
```

```bash
sdk/emulator/Emulator -create HarmonyOS_Phone_rooted -deviceType Phone \
  -osVersion "HarmonyOS 6.1.1(24)" \
  -imageRoot <WORKSPACE>/tmp/image_root_rooted \
  -instancePath <WORKSPACE>/tmp/deployed_rooted
sdk/emulator/Emulator -start HarmonyOS_Phone_rooted \
  -instancePath <WORKSPACE>/tmp/deployed_rooted \
  -imageRoot <WORKSPACE>/tmp/image_root_rooted   # 桌面会话加窗口环境变量，见 01 号文档
```

## 四、验证结果

```bash
hdc -t 127.0.0.1:5555 shell id
# uid=0(root) gid=0(root) groups=0(root),1006(file_manager),1007(log),1008(user_data_rw),2000(shell),3009(readproc) context=u:r:sh:s0
```

hdc shell 即为 root。注意：模拟器把 system/vendor 分区以**只读 virtio-blk 设备**提供给客机，运行时无法 `mount -o remount,rw`，改系统文件需按第二节离线修改镜像。

## 参考

- root 方法参考：CSDN moli51234《HarmonyOS 模拟器 root》（blog.csdn.net/moli51234/article/details/146159992）
- hdcd.cfg 来源：gitee OpenHarmony/developtools_hdc `src/daemon/etc/hdcd.root.cfg`
