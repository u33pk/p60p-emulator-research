# 81. 屏幕使能链修复后的 vsync 死锁与输入注入失败（2026-10-23）

## 今日战果（docs/80 由子代理完成并验证）

**屏幕使能链已修复**：`libdisplay_composer_service_1.3.z.so` 两处 `close` 打 NOP（SMQ fd 提前关闭导致 GetCmdReply 回传 EBADF → OnHotPlug 注册失败）。修复后干净启动：
- `Failed to register OnHotPlug` = 0，`screenPowerStatus_ is empty` = 0
- OnHotPlug(0,1) → ProcessScreenConnected → PhysicalScreenInit → SetScreenPowerStatus(On) → Init succeed
- 锁屏正常渲染（时钟显示开机时刻的正确时间）

## 剩余双断点（本轮实测结论）

### 断点 1：周期性帧调度死锁（画面冻结的直接原因）

实测链：
- RS 渲染只在 boot 首帧 + ~60s 看门狗兜底（`RenderFrame task too long: 59996ms` 周期出现）
- VSyncGenerator 对象全字段 3 秒采样零变化——彻底空转，无人请求
- `SetScreenVsyncEnabled` 从未被调用 → 宿主 express_sync 从不发 vsync 脉冲 → 硬件 vsync 断流
- 软件模式实验（patch libvsync.z.so 构造函数 0x3ea10 `tbz w20,#0`→`b`，文件偏移 0x3da10，`940d0036`→`6b000014`）：对象确实以软模式构造（+280=0），但依然空转——软模式按需 tick，没有请求就停。**已还原该 patch**
- 关键推理：官方镜像的持续 60Hz vsync 来自宿主连续脉冲（express_sync 是推模式）；guest 软件模式是拉模式，不能替代
- bootstrap 死锁：boot 后无人请求帧 → 不 enable vsync → 无脉冲 → 无帧

**候选突破（未做）**：用 composer HDI stub 客户端（libdisplay_composer_stub_1.3）直接调 `SetScreenVsyncEnabled(0,true)`，让宿主开始发脉冲，打破死锁；或逆向 RSScreenManager 找到 enable 的前置条件并从内存补状态。

### 断点 2：uinput 注入被 MMI 拒绝（明确报错）

```
uinput/MultimodalEventHandler: [InjectPointerEvent:239] Send to server failed, ret:-1
uinput/InputManagerImpl: [SimulateInputEvent:1252] Failed to inject pointer event
```
- 官方镜像上同一二进制 shell 用户可注入（已成功解锁桌面验证）；P60P 上 root(sh 域) 注入被拒
- 差异候选：uid(0 vs 2000) 或 SELinux 上下文(sh vs shell) 或华为 MMI 的鉴权差异
- 宿主鼠标转发在两种镜像上都不通（宿主 Emulator 自身问题，独立）

## 工具链沉淀（重要）

- `.gnu_debugdata` = **xz 压缩**的符号 ELF：`objcopy --dump-section .gnu_debugdata=x.xz so && xz -dc x.xz > dbg.elf`（librs/libvsync/rs_base 均已提取，tmp/*.syms）
- guest 内存读写：`ptrace(PTRACE_ATTACH)` 后 /proc/pid/mem 可写（dd 直写 EIO）；tmp/poke tmp/peek tmp/scan_mem 已编译部署
- **hdc shell 的 `$((...))` 是 32 位**，大地址算 skip 必须在宿主算好传十进制字面量
- VSyncGenerator 对象签名：vtable=libvsync_base+0x4d300、+280=模式(0软/1硬)、+281=running、+508=360；tmp/scan_mem <pid> <hex> 可扫任何单例
- 模拟器 PPM 恒 1.45MB 无效判据；PNG cmp 才是冻结判据

## 当前镜像改动清单（自 docs/80 后无新增）
- vendor: libdisplay_composer_service_1.3.z.so（2×NOP）
- system: libchipset_vsync.z.so（fake 客户端，docs/79）
- libvsync.z.so 软件模式 patch 已还原（字节恢复 940d0036）

## 下一步优先级
1. composer HDI 客户端强推 SetScreenVsyncEnabled → 打破 vsync 死锁（最可能让桌面"活"起来）
2. 输入：对比官方/P60P 的 MMI 注入鉴权（换个 uid/上下文试注入）；宿主鼠标转发另案
3. guest 时钟跳变异常（docs/79 遗留）可能影响所有定时器，需立案

## 追加：HDI 客户端强推方案受阻（00:57 实测）

- `IDisplayComposer::Get(false)`（真服务路径）返回 null；`Get(true)`（isStub）可拿本地桩对象但调 proxy 方法返回 -4
- 根因日志：`SA_CLIENT: GetSaWrap SA:5100 not start` + `hdi_servmgr_client: failed to get sa hdf service manager`——hdi servmgr 经 samgr SA 5100 可达，但我们的 root shell 进程被判 "not start"（SA 可见性/权限过滤，或 SA 5100 未注册）
- C 直连 API `HDIServiceManagerGet()` 直接挂起（timeout）
- 工具源码留档：tmp/vse6.cpp（x8 sret 技巧可用）、tmp/hdils.cpp（ListAllService，符号未解析完）、tmp/hdic.c（C API，挂起）
- 结论：**系统进程身份是硬通货**。下一步正经路线 = 把 vsync enable 逻辑做成 init 注册的系统服务（uid=graphics/system + 对应 secon），或 patch composer vendor vdi 让其在初始化时自行向宿主声明 vsync 开启

## 追加 2：init 系统服务方案（01:16 实测）

**已打通**：把 vsync enable 逻辑注册为 init 系统服务（graphics uid + render_service 域），成功拿到真 composer 对象！
- 部署：`/system/bin/vsync_on`（render_service_exec 标签触发域转换）+ 服务定义追加在 `/vendor/etc/init.hmos.emulator.cfg`（boot-complete job 里 start）
- 坑点记录：
  - /system/etc/init 下的独立 cfg 被 init 静默忽略（原因未查明，可能该版本 init 只扫白名单）
  - 服务日志不能写 /data/local/tmp（graphics 无权限），改 /data/service/el0/render_service/
  - `IDisplayComposer::Get(false)` 在 servmgr 未就绪时会**永久阻塞**（不是返回 null）——必须 fork+看门狗，或先 sleep 15s
  - aarch64 C++ sret 返回槽在 **x8** 寄存器（不是 x0）
- 当前卡点：`SetDisplayVsyncEnabled(0,true)` 返回 **-4**（HDI 服务边界错误，未达 vdi 层；服务侧无 vsyncStatus 日志）
- 下一步候选：注册 VBlankCallback 后再 enable（需手写 IRemoteObject stub 对象）；或逆向 -4 在 ObjectCollector/服务加载层的具体分支
- 该服务常驻无害，持续重试中
