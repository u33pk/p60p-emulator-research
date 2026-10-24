# 76. SELinux 恢复 enforcing + 桌面打通（P60P 真机 ROM 在模拟器）

日期：2026-10-22　**结论：SELinux=Enforcing 下系统稳定、root 全真、桌面正常出屏**

## 目标

把 SELinux 从 permissive 恢复到 enforcing，同时：
1. root shell 不变「假 root」（不能卡在 /data 等目录外）
2. 处理恢复后连锁暴露的问题
3. 桌面正常启动

## 最终状态（全部实测）

- `getenforce` = **Enforcing**
- 系统稳定运行，无重启循环（storage_manager / hdf_devmgr / samgr / foundation / render_service 全在跑）
- hdc 正常连接；root `uid=0`，**`/data` 可读、可写、可删**（不是假 root）
- **桌面正常出屏**（锁屏时钟/壁纸/状态栏/横幅齐全），guest 自发 boot-complete（`bootevent.boot.completed=true` 触发 QemuParams）

## 修复清单（按因果链）

### A. root 不变假 root —— 本来就有
`system_common.cil` 里已有 `(typepermissive sh)` 和 `(typepermissive hdcd)`（之前注入的），
shell/hdcd 域 per-domain permissive。系统整体 enforcing，唯独 root shell 不设防。**无需改动。**

### B. 开机崩溃-重启循环 —— 三层根因

1. **文件标签丢失**（debugfs 写文件会丢 security.selinux xattr，导致 exec EACCES）：
   - `/vendor/bin/hdf_devmgr`：`vendor_file` → `hdf_devmgr_exec`（critical 服务，崩了触发 panic）
   - `/system/bin/hdcd`：`system_bin_file` → `hdcd_exec`（否则 hdc 连不上）
   - 修法：`debugfs -w -R 'ea_set -f <标签文件> <路径> security.selinux' <镜像>`，
     标签文件内容如 `u:object_r:hdf_devmgr_exec:s0\0`（带 NUL）。

2. **系统性根因 —— enforcing 下 ueventd 冷启动重扫时 SIGSEGV**：
   /dev 是 tmpfs，设备节点全靠 ueventd 重建。它一崩，`/dev/access_token_id` 等节点没建出，
   init 给各服务 open 该节点 ENOENT（日志 `failed to set access token`，enforcing 下 102 次、
   permissive 下 0 次）→ token 设不上 → 服务注册 samgr 被拒（`PERMISSION DENIED`）→
   critical 服务（storage_manager 等）exit → 崩溃重启循环。
   **修法**：`system_common.cil` 尾部加 `(typepermissive ueventd)`。

3. 零星 dev_kmsg 补规则：watchdog_service / resource_schedule_service /
   accesstoken_service / wireless_hid_accessory_manager_ability → dev_kmsg_file write+open。

### C. 桌面不出 —— QemuParams 域缺失 + 显示链被卡

1. **QemuParams 跑不起来两层**：
   - 二进制版本不匹配：P60P 的 QemuParams（250208B）缺符号 exit 127 → **换官方 6.0.1 版**（92960B）
   - 服务域 `emu_param` 真机策略里不存在 → setexeccon EINVAL → exec 前 _exit(21)
   **修法**：把官方 6.0.1 的 `emu_param` 域完整注入 `system_common.cil`
   （5 个 type 声明 + 属性归属 domain/sadomain/native_system_domain/file_attr/system_file_attr/exec_attr/dev_attr/parameter_attr + 全套 allow/typetransition），
   补 `file_contexts`（QemuParams→emu_param_exec、/dev/express_pipe→dev_emu_pipe_file）
   和 `parameter_contexts`（ohos.qemu.hvd.name→ohos_emu_hvd_name、ohos.qemu.dpi 等→ohos_emu_dpi_param），
   QemuParams 二进制打 `emu_param_exec` 标签，vendor cfg 的 secon 还原为 `emu_param`。
   → QemuParams-bootparams 跑起来，把 `ohos.qemu.dpi` 等显示参数搬进 guest。

2. **显示链被卡（sceneboard 拿不到 display）**：
   显示参数有了，但 sceneboard 仍 `getDefaultDisplaySync failed 1400001`（拿不到默认显示）、
   THREAD_BLOCK——composer_host 卡在 futex_wait，连 `/dev/express_display` 都没打开，
   `express_hotplug` 计数为 0。**显示路径全量 avc 扫描无任何拒绝**（拒绝被 dontaudit/audit 限流吞了）。
   **修法（typepermissive 二分定位）**：给显示链加 typepermissive 后 composer 立即初始化、桌面出屏：
   ```
   (typepermissive composer_host)
   (typepermissive display_engine_service)
   (typepermissive render_service)
   (typepermissive allocator_host)
   ```
   （精确的被拒规则被 dontaudit 屏蔽，待后续如需可再用 audit 补丁/二分收紧。）

## 关键诊断方法（复用价值）

- **decisive A/B**：同镜像切 permissive/enforcing 对比，确认问题是 SELinux 特有
- **typepermissive 二分**：avc 看不到（dontaudit/限流）时，给可疑域加 typepermissive，功能恢复即定位
- **聚合 avc**：`dmesg | grep 'avc.*denied'` 按 scontext→tcontext:class 聚合找模式
- **「failed to set access token」计数** 是 enforcing 系统性问题的晴雨表

## 遗留

- guest 侧 `snapshot_display` 全黑（capture 与呈现缓冲不一致）
- 锁屏静止时时钟不主动刷新（交互后刷新）——render Commit 门控，与 SELinux 无关
- uinput 滑动注入在 enforcing 下未生效（`/dev/uinput` 不存在）——独立输入问题，待查
- 显示链 4 个域的精确被拒规则被 dontaudit 屏蔽，如需收紧可再二分

## 改动文件汇总（本阶段）

- `p60p_system.img`：`/system/etc/selinux/config`（enforcing）、`system_common.cil`（+typepermissive ueventd/显示链 + emu_param 域 + dev_kmsg 规则）、`system_developer.cil`、`file_contexts`、`parameter_contexts`、`/system/bin/QemuParams`（换官方版+打标签）、`/system/bin/hdcd`（打标签）
- `p60pv2_vendor.img`：`/vendor/bin/hdf_devmgr`（打标签）、`/etc/init.hmos.emulator.cfg`（QemuParams secon→emu_param）
