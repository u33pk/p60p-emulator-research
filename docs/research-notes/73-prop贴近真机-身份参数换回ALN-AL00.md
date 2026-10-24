# 73. prop 贴近真机：身份参数全部换回真机值（ALN-AL00 / Mate 60 Pro）

日期：2026-10-21

## 目标

模拟器里跑的 guest，`param ls` 里身份类 prop 全是 `emulator` / `PHEMU`，
要求尽可能贴近真机：从真机镜像里取值，直接搬过来。

## 一、`emulator` 到底是哪一层盖的

真机 system（`p60p_system.img`）里的 `/system/etc/param/ohos.para` 是**通用占位值**
（`const.product.model=ohos`、`const.product.name="OpenHarmony 3.2"`、
`const.product.brand=default`），根本不是真机身份。

真机身份在 **sys_prod 分区**，而参数是分层加载、后层覆盖前层：

| 层 | 路径 | 说明 |
|---|---|---|
| 1 | `/sys_prod/etc/param/hw_defaults.para` | 默认层（115 条） |
| 2 | `/sys_prod/variant/hw_oem/factory/etc/param/` | factory 变体 |
| 3 | `/sys_prod/variant/hw_oem/<devmodel>/etc/param/` | **机型变体** |
| 4 | `/sys_prod/variant/region_comm/<region>/etc/param/` | 区域变体 |
| 5 | `/vendor/etc/param/default.para` | vendor 层 |

**关键坑**：运行时 `/sys_prod/etc/param/` 会被**机型变体目录整体 bind-mount 覆盖**
（`/proc/mounts` 里能看到 `/dev/block/vdc /sys_prod/etc/param ext4` 这条）。
所以**改默认层的 `hw_defaults.para` 完全不生效**——必须改机型变体那一份。

我们的 image root 里 `sys_prod.img` / `vendor.img` 用的是 **6.0.1 模拟器镜像**，
其 `variant/hw_oem/PHEMU-FD00/etc/param/hw_defaults.para`（45 条）与
`vendor/etc/param/default.para` 都写着 `const.product.model=emulator`
等标识，这就是 `emulator` 的来源。

## 二、真机值从哪来

真机 ROM 的 `update.bin` 解包产物在
`tmp/unpack_out/unpack_result_221524/`（含 `sys_prod.img` 2.2GB、`vendor.img` 859MB，
都是 EROFS，用 `fsck.erofs --extract=` 解）。

真机 `sys_prod` 的机型变体目录：

```
variant/hw_oem/ALN-AL00   ALN-AL10   ALN-AL10P   ALN-AL80   factory
```

`p60p_rom/package_info` 确认 ROM 覆盖 `deviceModel=ALN-AL00;ALN-AL80;ALN-AL10;ALN-AL10P`，
`VERSION.mbn` = `ALN-LGRP1-CHN 206.0.0.108(SP6)`。
即 **HUAWEI Mate 60 Pro（ALN 系列）**。本次取基础版 **ALN-AL00**。

真机 `vendor/etc/param/` 下**没有** `default.para`（身份只在 sys_prod）。

## 三、做了什么

1. 抽取真机参数：`tmp/sysprod_real/`（sys_prod）、`tmp/vendor_real/`（vendor）
2. 合并成一份（优先级：默认 < factory < ALN-AL00 < region china），148 条
   → `tmp/para_p60p/full_merged.para`
3. 写入**机型变体**位置（真正被读的那份）：
   `tmp/rooted_image/p60pv2_sysprod.img` 的
   `/variant/hw_oem/PHEMU-FD00/etc/param/hw_defaults.para`
   （`sys_prod.img` 链接已指向这个副本，不动 6.0.1 参考镜像）
4. `tmp/rooted_image/p60pv2_vendor.img` 的 `/etc/param/default.para`：
   6 条身份项换成真机值，**保留模拟器功能项**
   （`persist.hdc.mode=bridge`、`persist.hdc.port=5555`、`rosen.*` 等，
   删了 hdc 会连不上）
5. 删 qcow2 冷启动验证

## 四、全放过去的后果：`render_service` 崩溃

148 条全量搬入后开机 **31 秒 panic**：

```
render_service(pid 1934) exit with signal : 11        ← SIGSEGV
allocator_host / composer_host exit with signal : 9
foundation(pid 1939) exit with signal : 9
ServiceReap error critical service crashed foundation 4
bootfail ServiceCrash name: foundation
ExecReboot panic   →  sysrq: Trigger a crash
```

`foundation` 是 critical 服务，它一挂 init 就走 panic-reboot 自毁路径。

**剔除 15 条图形/GPU 管线参数后正常开机**（这些是真机 GPU/渲染硬件专属，
模拟器没有对应能力）：

```
const.graphics.hybridrenderenable / const.graphics.hybridrenderfeatureswitch
persist.sys.graphic.GpuApitype / persist.sys.graphic.hideNotch.status
const.app_comp.auto_start_enable / const.app_comp.image.preset_enable
const.app_comp.rgm_quick_stop_enable / const.app_comp.rgm_suspend_enable
const.recent.support_foregroundblur
const.sceneboard.unlock.desktop_foregroundblur_enable
const.window.device.rotation_optimization_switch
const.display.hdr_picture_support
const.exagear.state / const.binfmt.state / const.dynamic.zygote32
```

剔除清单：`tmp/para_p60p/merged_tier1.para`（133 条）。

## 五、结果

界面无回归（锁屏正常出屏，时钟走动）。prop 共 **1709 条**，身份全部是真机值：

| prop | 之前 | 现在 |
|---|---|---|
| `const.product.model` | emulator | **ALN-AL00** |
| `const.product.name` | emulator | **HUAWEI Mate 60 Pro** |
| `const.product.brand` / `manufacturer` | HUAWEI | HUAWEI |
| `const.build.product` | emulator | **ALN** |
| `const.build.description` | — | **ALN-AL00-user 206.0.0 HUAWEIALN-AL00 108SP6-CHN-LGRP1 release-keys** |
| `const.software.model` | default | **ALN-AL00** |
| `const.comp.product_version` | Product-PHEMU 206.0.0(0000) | **Product-ALN 206.0.0(0000)** |
| `const.comp.hl.product_base_version` | emulator-LGRP1-CHN 6.0.0.48(SP1) | **ALN-LGRP1-CHN 6.0.0.108(SP6)** |
| `const.product.hardwareversion` | default | **HL1CMSM** |
| `const.ai.nnrt_deivce` | — | **K6010** |
| `const.aod.hardware_config` | 6 | **13** |
| `const.logsystem.versiontype` | beta | **commercial** |
| `const.security.device_security_level` | — | **4** |
| `const.build.vendor.date` | 2025-09-18 | 2025-10-16 15:48:53 |

**仅剩 3 条带 emulator/PHEMU 字样**，都是模拟器运行时注入（不在镜像里）：

```
const.cust.devmodel         = PHEMU-FD00        ← config.ini 的 deviceModel=
const.cust.config_dir_layer = ...:/sys_prod:/sys_prod/variant/hw_oem/PHEMU-FD00
ohos.boot.hardware          = hmos.emulator     ← 模拟器启动参数注入
```

## 六、遗留

1. `const.cust.devmodel=PHEMU-FD00`：改 `config.ini` 的 `deviceModel=ALN-AL00`
   即可贴近真机（变体路径也会指向 ALN-AL00；届时 PHEMU-FD00 变体文件可改名为 ALN-AL00）
2. `ohos.boot.hardware=hmos.emulator`：模拟器宿主注入，要改得动宿主侧或 QemuParams 参数
3. 15 条被剔除的图形参数：如需可逐条试回，定位到具体崩的是哪一条

## 状态

- `tmp/rooted_image/p60pv2_sysprod.img`：6.0.1 sys_prod 副本 + 真机参数
  （默认层 126 条 + `variant/hw_oem/PHEMU-FD00` 133 条 + factory/china 变体）
- `tmp/rooted_image/p60pv2_vendor.img`：vendor 身份 6 条换真机值
- image root 链接：`sys_prod.img` → 上述副本；`system.img` → `p60p_system.img`；
  `vendor.img` → `p60pv2_vendor.img`
- 完整 prop 清单：`tmp/props_final.txt`（1709 条）
- 真机参数抽取：`tmp/sysprod_real/`、`tmp/vendor_real/`、`tmp/para_p60p/`
