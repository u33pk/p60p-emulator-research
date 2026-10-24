# 79. fake chipset_vsync_service：协议全逆向 + 客户端替换落地 + 冻结根因再定位（2026-10-22）

## TL;DR

- **已实现并部署 Path B（替换客户端）**：自制 `libchipset_vsync.z.so`（仅导出 `InitChipsetVsyncImpl`/`SetVsyncImpl`，返回 0），`chipset_vsync_service not found` 错误**消失**（验收#1 达成）。
- **偶发更新（非自发）**：17:38 那次开机在 15-30s 尺度上截图 md5 不同（时钟 05:33→05:45），但 18:29 干净重启后 4 分钟以上无任何自发更新（时钟停在开机时刻 06:29）——更新仅在被外部 poke（lldb SIGSTOP/CONT、hilog -b D、uinput 尝试）时偶发出现。**验收#2 未真正达成**（时钟平时不走）。
- **冻结根因再定位（关键新证据）**：`VSyncGenerator` 处于 **硬件模式（mode=1）**，而硬件 vsync（composer HDI `HdiScreen::OnVsync`）**30 秒 0 次到达**；`SetScreenVsyncEnabled` **从未被调用**。发生器在硬件模式下空等 → 帧只能以 ~0.5Hz 走 HGM 软 vsync/看门狗路径。`chipset_vsync_service` 协议本身是**被动型**（见下），其缺席不是 vsync 断流的直接原因。
- **完整 IPC 协议已逆向**（码表/parcel 布局/结构体偏移），实现 fake HDI 服务的全部素材齐备；注册路径唯一可行 = 劫持 `hdf_default.hcb` 里等长的 `sample_driver_service`(21字符) 条目 + 自制 driver 模块。未走完（风险/工时），方案细节见下。

## 一、客户端逆向结论（libchipset_vsync.z.so，已确认）

RS 侧（librender_service.so）：
- `RsChipsetVsync::LoadLibrary()` dlopen "libchipset_vsync.z.so"（BSS 里构造的 std::string）
- `GetChipsetVsyncFunc()`: dlsym `InitChipsetVsyncImpl`(0xe7772)、`SetVsyncImpl`(0xe7787)
- `ConnectChipsetVsyncSer()`：成功→RSMainThread+60=0，失败=1
- `OnVsync()` 里若 +60!=0 则**每个 vsync 重试** `InitChipsetVsync()`（这就是日志里周期性 3 连错误来源）
- `SetVsyncInfo(m)`→`RsChipsetVsync::SetVsync(a,b,c,d)` 转发 dlsym 的 SetVsyncImpl（**本构建无调用者，死代码**）

导出符号（extern "C"，unmangled）：
```c
int InitChipsetVsyncImpl(void);                    // → ChipsetVsyncClient::InitChipsetVsync()
int SetVsyncImpl(long a, long b, long c, int d);   // → ChipsetVsyncHostCallback::SetVsync
```
`ChipsetVsyncHostCallback` 单例字段：+8=a, +16=c, +24=b, +72=调用计数(≥0 自增), +76=d(bool)。
`GetVsyncInfo(RSVsyncInfo&)` = 返回 {+8, +16}（两把 int64，锁保护，**无副作用**）。
`SetVsync` 里 `c`=帧率(fps)，`1000000000/c`=帧周期；计数满后投票 ApsManager（`SetScene(...)`），`[+72]=-1`。
`VoteFrameRate(int)`：APS SetScene + 延迟投票逻辑，**不触发任何 vsync 回调**。

结论：客户端无任何接收线程/推送路径 → 服务→客户端通道语义为**被动**（服务拉取 GetVsyncInfo / 推 VoteFrameRate 做电源投票）。

## 二、HDI 协议逆向结果（cvsync_proxy_1.0/1.1）

客户端→服务（proxy SendRequest，`w1`=code）：
| 方法 | code | data parcel |
|---|---|---|
| V1_1 SetCallback_V1_1_(cb, extra) | **2** | WriteInterfaceToken(desc) + WriteRemoteObject(cb)（extra 未写入） |
| GetVersion | （走 V1_0 GetVersion_，带 extra remote） | token |
| SetCallback (V1_0) | （proxy10 @0x8658） | 同上 |
| Reconnect | — | — |

服务→客户端 callback stub 码表（ChipsetVsyncHostCallbackStub::OnRemoteRequest）：
| code | 方法 | 语义 |
|---|---|---|
| 1 | VoteFrameRate(int) | data: ReadInt32(rate)；reply: WriteUint32×2 |
| 2 | GetVsyncInfo(RSVsyncInfo&) | reply: **WriteUnpadBuffer(16字节)** = {int64 a, int64 c} |
| 其他 | GetVersion | reply: 两个 uint32 |

descriptor 是运行时构造（非明文 rodata），`RSVsyncInfoBlockMarshalling/Unmarshalling` 为 16 字节定长块。

## 三、Path B 实现（已部署）

- 源码：`tmp/vsyncfake/fake_client.c`（3 行：两个导出返回 0）
- 编译：`clang --target=aarch64-linux-ohos -shared -fPIC -O2 -Wl,-soname,libchipset_vsync.z.so`（SDK llvm，aarch64 musl，仅依赖 libc.so）
- 镜像内路径：`/system/lib64/libchipset_vsync.z.so`（mode 0644，SELinux `u:object_r:system_lib_file:s0`，已 ea_set）
- 原版备份：`tmp/vsyncfake/libchipset_vsync.z.so.orig`
- 部署方式：debugfs rm + write + sif + ea_set（tmp/x.lbl）

实测：重启后 `hilog -x | grep chipset` 无任何 not found（验收#1 达成，干净重启复验 0 条）。锁屏时钟偶发更新但平时冻结（验收#2 未达成）。

## 四、冻结根因再定位（本轮最重要的新证据）

lldb（静态 lldb-server，推 /data/local/tmp，gdb-remote 直连）+ /proc/mem 直读实测：

1. **VSyncGenerator 模式 = 1（硬件模式）**（对象 +281 字节，period=15622783ns≈64Hz 已校准 → 开机时硬件 vsync 曾短暂流通）
2. **硬件 vsync 断流**：断 `HdiScreen::OnVsync`（libcomposer @0x33aec）30 秒 **0 次命中**
3. **使能从未发生**：断 `HdiDeviceImpl::SetScreenVsyncEnabled`(0x189c8)/`HdiScreen::SetScreenVsyncEnabled`(0x342a0) 16 秒 **0 次命中**
4. 屏幕注册本身成功（持久日志 hilog.000 有 `ProcessScreenConnected`/`SetVsyncEnabledScreenId`/`AddScreenToHgm`），但运行时 `RSScreenManager: IsAllScreensPowerOff: screenPowerStatus_ is empty`
5. 发生器仍偶尔 notify（25s 内 ~10 次 GEN_NOTIFY / 3 次 RS_ONVSYNC）= HGM 软 vsync + 60s 看门狗（`RenderFrame task too long: 60005ms`）在兜底
6. 画面 15s 尺度有更新（05:33→05:45），但伴随**时钟跳变**（30s 真实时间走 12 分钟），guest `date` 与 host 一致 → 帧渲染时刻的 guest 时间不稳定

**结论**：冻结链是 `live-present 切换后宿主 express_display paint 停（doc 77）→ 硬件 vsync 断流 → 发生器硬件模式空等 → 帧以 ~0.5Hz 兜底`。chipset_vsync 协议是被动通道，补服务不会把硬件 vsync 带回来。guest 时钟跳变是另一条独立异常线（疑与 suspend/resume 或 clocksource 有关），可能放大/扭曲了所有计时表现。

## 五、fake HDI 服务的完整可行方案（未落地，素材已齐）

### 注册机制（关键结论）
- libhdi 的 `IServiceManager`(V1_0) **无 AddService**（GetService/ListAllService/RegisterServiceStatusListener...），用户态服务由 **devmgr 按设备配置加载**
- 配置：`/chip_prod/etc/hdfconfig/hdf_default.hcb`（主配置）；devhost 由 devmgr 按 host 段 spawn（如 `vibrator_host -i 14`），dlopen `moduleName` → `dlsym("driverDesc")` → `HdfDriverEntry{moduleVersion,moduleName,Bind,Init,Release}` → Bind 设 `deviceObject->service` → devhost `DevSvcManagerClntAddService` 发布到 servmgr
- SELinux 侧已备好：`/vendor/etc/selinux/targeted/contexts/hdf_service_contexts` 有 `chipset_vsync_service u:object_r:hdf_chipset_vsync_service:s0`
- **hdf_default.hcb 无 chipset_vsync 设备声明**（真机由芯片侧配置提供）

### 劫持路径（零结构改动）
hcb 是 `01<节点>\x00 02<属性>\x00<类型><值>` 扁平格式。文件头两个 sample 条目：
```
0xeb: "sample_driver_service" (21字符)   → 原位改写 "chipset_vsync_service"（等长!）
0xc7: "libsample_driver.z.so"  (21字符)   → 保持
0x87: sample_device 记录: policy=02(用户态服务) preload priority moduleName serviceName permission deviceMatchAttr
```
sample_host 已声明（0x5f: hostName "sample_host"）。sample 驱动 .so 本就不存在 → 放自制模块到 devhost 可 dlopen 路径（/vendor/lib64 或 /vendor/modules）。

### driver 模块 ABI（从 libvibrator_driver.z.so 逆向）
- 导出 `driverDesc`（HdfVdiDesc={int moduleVersion; HdfDriverEntry* moduleEntry;}）
- `IService` 对象（40B）：+0=serviceObj(你的 IRemoteObject stub)，+16=Dispatch 函数指针，+32=备用
- Dispatch(this, code, HdfSBuf* data, HdfSBuf* reply)：`SbufToParcel(data/reply)`→调 stub 虚 `OnRemoteRequest(code, parcel, parcel, MessageOption(0,8))`（参考 vibrator .text+0x418）
- OnRemoteRequest 处理：code2=SetCallback_V1_1（ReadRemoteObject 存 cb，起 60Hz 线程：每 16.6ms 对 cb SendRequest(code2) 读 16 字节，每秒 SendRequest(code1, rate=60)）；其他=GetVersion(回 1,1)
- 链接 libipc_single.z.so + libhdf_host.z.so；version-script 导出 `driverDesc@@1.0`

### SELinux
sample_host 无 secon → 新域需 cil 加 servmgr 注册/通信 allow；项目惯例 `(typepermissive xxx)` 先跑通。

## 六、遗留/建议
1. 继续 Path A：按第五节做，预计可达成验收#1/#4，但按第四节结论**大概率仍不解冻**
2. 真正解冻方向：`SetScreenVsyncEnabled` 使能链（谁调它→为何不调）或宿主 express paint 断流（doc 77），二者在 guest 侧可继续查
3. guest 时钟跳变独立问题值得单独立案（影响所有计时判据）
4. uinput 被 MMI 静默吞（doc 77）导致验收#3 无法用 uinput 验证；画面更新慢也使解锁无视觉反馈

## 附：本轮工具链备忘
- 静态 lldb-server：`sdk/.../native/llvm/lib/clang/15.0.4/bin/aarch64-linux-ohos/lldb-server`（可推 guest，pkill hdc 后 fport tcp:PORT tcp:PORT，`lldb-server g :PORT --attach <pid>`，host `lldb` 用 `gdb-remote 127.0.0.1:PORT`；attach 后 detach 会致 RS 重启，pid 会变）
- /proc/<pid>/mem 直读免停进程（dd skip=<addr>）
- 模拟器启动：`setsid bash tmp/run_emu_plain.sh`；改镜像后删 `tmp/deployed_p60pv2/HarmonyOS_P60P_v2/*.qcow2`
