# 18 - vblank 链路打通：从"零提交"到"65Hz 直达 RS"

> 接上篇 17（双重修复落地）。本篇记录对"v2 真机镜像窗口永远停在开机转圈"的彻底排查与三处根因修复。
> 结论先行：**帧提交的 vsync 驱动链路已完全打通**（VDI 软件 vsync 以 ~65Hz 经 binder 直达 render_service 并被成功应答），
> 但 RS 的 `VSyncGenerator` 仍不产生脉冲，渲染引擎全程休眠，尚无一帧上屏。剩余问题见文末。

## 一、先排除"其他因素"（用户点名方向）

对运行中的 v2 实例做全面取证，逐项排除了与显示无关/与检测相关的嫌疑：

| 嫌疑 | 证据 | 结论 |
|---|---|---|
| 内核非法/签名校验 | 系统完整启动到 launcher/lockscreen ready | 无此类拦截 |
| 模拟器检测 | `const.product.name=emulator`（厂商本就模拟器配置），桌面流程正常推进 | 无拦截 |
| 显示电源关屏 | `GetScreenPower state:0`，OHOS 中 `POWER_STATUS_ON=0` | **屏是 ON，非关屏** |
| selinux 拦显示 | avc 拒绝集中在 `/dev/access_token_id`(sceneboard/foundation/powermgr) 和 hiview/xpower | 与显示输出无关 |
| huksService.ready=false | TEE-less，导致 `bootevent.boot.completed` 可能不被置位 | 周边，未证明显示相关 |
| anti_fraud_service 循环崩溃 | faultlog 大量 cppcrash | 手机特有服务在模拟器上失败，周边 |

**关键反差**：`bootevent.wms.fullscreen.ready=true`、`launcher.ready=true`、`lockscreen.ready=true`、`bootanimation.finished=true` —— 系统自己认为一切就绪，但用户看到的是**静止的开机转圈残影**（bootanimation 被杀时最后一帧），之后零提交。

## 二、根因与修复（3 处，均已固化进镜像）

### 根因 1：107 手机 RS 只用 idle 版 vblank 注册，48 模拟器 VDI 不支持
- 手机 RS（6.0.0.107）的 `HdiDeviceImpl` 只调 `RegScreenVBlankIdleCallback`（V1_2 idle 接口），**从不调** plain `RegScreenVBlankCallback`（hilog 统计 0:1 证实）。
- 48 模拟器 vendor 的 VDI（`libdisplay_composer_vendor.z.so`）只有 plain 实现；服务端 `svc13` 的 idle 分支因 `VBlankIdleCb_==nullptr` 直接返回错误。
- **修复 A**（`system.img` `/system/lib64/libdisplay_composer_hdi_impl_1.3.z.so`，48 模拟器版客户端内）：
  把 `RegDisplayVBlankIdleCallback(cb,data)` 入口改写为 `RegDisplayVBlankCallback(0,cb,data)`：
  - vaddr `0xe6d8`（文件 `0xd6d8`）16 字节：`mov x3,x2; mov x2,x1; mov w1,wzr; b 0xc650`
  - 宿主件：`tmp/emu_hdi13_vblankfix.so`

### 根因 2：107 的 composer proxy 与 48 stub 之间存在 IPC 偏差
- RS 侧真实调用链：`libcomposer.z.so` → impl_1.3 → **libdisplay_composer_proxy_1.0~1.3（107 手机版）** → binder → 48 stub。
- 107 proxy 发起的大量调用（GetDisplayProperty/RegRefreshCallback/GetHDRCapabilityInfos/GetDisplaySupportedColorGamuts 等）在 48 stub 侧报错。
- **修复 B**：把 4 个 proxy 全部换成 48 模拟器版（取自 `tmp/image_root_600` 的 system.img）：
  - `libdisplay_composer_proxy_1.0/1.1/1.2/1.3.z.so`，selinux 标签 `system_lib_file:s0`
  - 107 原版备份在 `tmp/proxy107_orig/`（md5 见 `tmp/proxy107_orig.md5`）
- 注：事后 trap 实验证明 107 proxy 也能到达服务端 handler，但 48 全套对齐是更干净的状态，保留。

### 根因 3：VDI 软件 vsync worker 的两处缺陷 + 手机 RS 从不 enable
48 模拟器 VDI 的 `SorftVsync`（`libdisplay_composer_vendor.z.so`）：
1. **启动竞态**：`Init()` 先 `pthread_create`  worker、后才置 `flagB=1`；worker 第一轮若先跑到且 `flagB==0` 会**直接退出**（0x12084 `cbz w25,exit`），此后 vsync 永死。v2 上 worker 确实不存在（无线程等其 cv）。
2. **enable 门控**：worker 仅当 `enable(+0x10)!=0` 才发脉冲，而手机 RS 从不调 `SetDisplayVsyncEnabled(true)`。
3. **计时字段中毒**：绕过等待后，`+0x88` 漂移字段为负垃圾值，`usleep(drift+15366)` 算出 ~4294s 巨眠。

- **修复 C**（`vendor.img` `/lib64/libdisplay_composer_vendor.z.so`，4 处单指令补丁）：
  | vaddr | 原指令 | 改为 | 作用 |
  |---|---|---|---|
  | `0x12050` | `cbnz w8,0x1207c` | `b 0x1207c` | 跳过 enable 等待，直接进发射路径 |
  | `0x12054` | `cbz w25,0x1207c` | 保持 | （flagB==0 时也走发射路径，配合下条） |
  | `0x12084` | `cbz w25,0x1211c` | `nop` | flagB==0 不再退出（消除启动竞态杀 worker） |
  | `0x12094` | `add w25,w8,w27` | `mov w25,w27` | 睡眠周期固定为 w27=15366us（~65Hz），不吃垃圾漂移 |
  | `0x12114` | `bl HiLogPrint` | `nop` | 静音空回调期的日志刷屏 |
  - 宿主件：`tmp/vendor_composer_nosleep.so`
- `svc13` 已**还原为 48 纯净版**（此前实验的 auto-enable cave 不再需要；备份 `tmp/svc13.so`，autoenable 版留档 `tmp/svc13_autoenable.so`）。

## 三、修复后的实证（当前状态）

- VDI worker 存活并以 ~65Hz 运转（SorftVsync `+0x14` 计数器 2s 内 +133）。
- **binder 实证**：composer_host(687) `BC_TRANSACTION` 以 64/s 增长；事务日志可见 `call from 687 to 846(render_service) ... ret 0/0` + `reply ret 0/0` —— vblank 事件**成功送达并被 RS 应答**。
- RS 侧回调 = `HdiScreen::OnVsync`（libcomposer 0x35974），内部喂给 `VSyncSampler`。

## 四、剩余卡点（下一攻坚目标）

**RS 收到 vblank（64/s），但 `VSyncGenerator` 不产生脉冲，`RSMainThread/RSUniRenderThread/RSHardwareThread` 全程 0 CPU，零 present，screenCap 仍 "Failed to get display pixelMap"。**

已查清的 RS 内部状态：
- `VSyncGenerator` 线程在 `futex(FUTEX_WAIT_PRIVATE, val=2, timeout=NULL)` 上**无限等待**，无人 notify。
- 采样器 `VSyncSampler` 有 `StartSample(bool)`/`SetHardwareVSyncStatus(bool)` 门控；107 的启动时机疑似挂在手机特有的语义上（真实硬件上首个 idle-vblank 到达即触发）。
- sceneboard 与 RS 之间 binder 连接齐全；sceneboard 主线程已完成启动进入事件循环空闲（此前的 `GetDefaultDisplaySync` 卡死是暂时的，已自行恢复）。
- 线索词：`persist.sys.graphic.vsyncControlEnabled`（当前未设置）、`RegSetScreenVsyncEnabledCallbackFor{Main,Hardware}Thread`、`DVSyncParamParse` 系列参数。

## 五、复现/验证命令

```bash
./v2ctl.sh start-nw          # headless 启动（本机无 X11，窗口模式需用户侧跑 ./v2ctl.sh start）
# vsync worker 计数（proof）：
#   vendor base = grep libdisplay_composer_vendor /proc/<composer>/maps
#   ptrace_read <pid> <base+0x16dc0+0x14> 两次对比应递增
# binder 事务率：watch /sys/kernel/debug/binder/stats 中 composer 的 BC_TRANSACTION ≈64/s
```
