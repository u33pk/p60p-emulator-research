# 82. vsync 自使能 trampoline：概念验证成功 + 崩溃排查（2026-10-23）

## 重大结论：自使能能让帧流起来

在 `libdisplay_composer_service_1.3.z.so` 的 `InitCmdRequest`（0x126e8，RS 建立 SMQ 通道时必经）入口注入 `bl` → 跳板（借 `ExitService` 0xddc4 的 60 字节空间）→ 调 `DisplayComposerService::SetDisplayVsyncEnabled(this,0,true)`（0x10aa4）。

**效果：宿主 express_sync vsync 脉冲立刻开始，开机动画持续渲染（帧流通！）**——bootstrap 死锁被打破，方向验证正确。

## 但 trampoline 两次版本都崩 composer_host（SIGTRAP）

- v1（不保存 x0/x1）：崩溃于 stub `DisplayComposerStubInitCmdRequest_+240` 的 **brk（栈金丝雀校验失败）**。分析：SetDisplayVsyncEnabled 踩了调用者保存寄存器 x0，返回后 `ldr x0,[x0,#152]` 野指针
- v2（保存 x0/x1/x19-x21）：**同样位置崩溃**。金丝雀不匹配原因未查明（理论分析 x29/x30 链路完好）——stub 用 x15 存金丝雀并已 spill，所有被调方契约都满足
- 崩溃后 composer_host 重启，但 DMS 永远收不到屏幕（Default screen id = -1 刷屏）→ 卡开机动画

## 教训：patch 串台事故

trampoline 用的基础文件 dump 自镜像 `/vendor/lib64/` 路径（镜像内实际是 `/lib64/`），debugfs 静默失败用了旧文件 → **把子代理的 SMQ patch 冲掉了**。发现时镜像处于「无 SMQ patch + 有 trampoline」的双重损坏态。
**已用子代理备份 `tmp/v_service13_noclose.so`（md5 2a230836… 已验证）恢复**，当前镜像 = docs/80 稳定态（0x1fc58/0x1fef8=NOP，无 trampoline）。
**今后 debugfs dump 后必须 md5 比对源文件，静默失败会拿旧文件。**

## 其他实测（排除法）

- `SetDisplayVsyncEnabled` devId 0..16 全部 -4 → 非 devId 问题
- `RegDisplayVBlankCallback(0, null)` → -3（必须真 stub 对象，而手写 IRemoteObject 需要 libipc 的 IPCObjectStub，其动态符号全隐藏，暂不可行）
- -4 来自 **stub 分发层**（服务方法本身只回 -1/-2/-3）——客户端代码路径与服务期望不匹配（疑版本握手），对比 RS 走 librender_service_base HdiDevice 的完整协商流程

## 下一步候选（按优先级）

1. **修 trampoline 崩溃**：用 lldb attach composer_host（崩溃前断 0x13024）看金丝雀哪步失配；或换注入点——不在 InitCmdRequest 入口，而在 stub 分发成功后的安全位置（如 `OnHotPlug` 回调里，那时 RS 已就绪）
2. 复刻 RS 的完整版本协商（GetVersion 握手后调用），破客户端 -4
3. 输入注入线（MMI Send to server failed -1）与宿主鼠标线仍未动

## 追加：vdi 层注入三连（02:45 实录）

注入点迁至 vdi 库（`libdisplay_composer_vdi_impl.z.so`），全部失败但排除了大量假设：

1. **HotplugListening 的 7a88 接屏路径**：BRK 探针证明**开机从不触发**（初始显示连接不走轮询循环，来自 HdiSession::DiscoveryDisplay）
2. **79f4 重连路径**：BRK 探针同样不触发
3. **GetDisplayCapability（0x7db4）入口钩**：**触发成功**（16 指令跳板保存 x0/x1/x2 + 位移指令），`SetDisplayVsyncEnabled` 被调用——但 composer_host 随即**并发崩溃**（null vtable 调用）

**关键结论**：0xa8 enable 消息成功送达宿主 → 宿主开始推送事件 → **guest 合成器在并发处理事件时崩溃**（binder 线程 GetDisplayCapability 处理中对象被并发销毁，vtable 变 null）。崩溃不在 enable 本身，而在 guest 处理"使能后涌入的宿主事件"的链路——疑似与 SMQ fd 同族的并发缺陷，或宿主事件触发了屏幕重建（CreateScreen/DeleteScreen 竞争）。

**修 bl 编码时发现的坑**：python `//4` 对负数向下取整导致 imm 多 -1（如 -0x4c9c//4 = -0x132b 而正确是 -0x1327），trampoline 内 bl 目标漂移 4 字节 = 从函数中间开始解码 = 野跳。已修正（`-(0x4c9c//4)` 或先取整再取负）。

**当前状态**：镜像已还原 docs/80 稳定态（vdi md5 d92ef936… 验证），0 崩溃 0 报错。

## 下一步
- 分析 enable 后涌入的宿主事件类型（qemu.log 级别对比官方 boot），定位并发崩溃点（候选：session 屏幕重建、SMQ 事件路径的 fd 缺陷变体）
- 或：使能后延迟到 quiescent 窗口（boot 完成后再 enable，避开初始化并发期）

## 追加 2：0xa8 是歧路 + RS 连接对照实验（03:05 实录）

**0xa8 enable 证明是错误方向**：官方镜像 qemu.log 从头到尾没有 "display terminate"；我们发送 0xa8 后宿主执行 display terminate + clear snapshot → guest 并发崩溃。官方 vsync 路径不含 SetDisplayVsyncEnabled。

**RS 客户端连接对照实验（关键）**：同一个 rs_power_on 客户端（RSInterfaces::SetScreenPowerStatus）
- 官方镜像：binder 调用正常送达（BinderInvoker 日志可见事务），无 "renderService is nullptr"
- P60P：同客户端报 "renderService is nullptr"
→ **确诊：RS 服务端点的发布/发现在 P60P 上坏了**。sceneboard 渲染走共享内存事务（不依赖连接），所以首帧能出；但 DMS 电源状态、app vsync、控制操作全部依赖这条连接 → 全部断裂 → 冻结。

**RS 发布机制**：librs 无 AddSystemAbility 符号（与官方同代码），ConnectHub 全内联+间接调用。下一步：逆 ConnectHub::Connect 第一个 samgr 调用（0x3751e0 blr 链）找出 RS 端点 ID/名字，再查 RS 侧发布点（RSMainThread::Init）为何没生效。

## 追加 3：确诊 RS 端点 = samgr SA 10，P60P 上未注册（03:10 实录）

**决定性日志**（rs_power_on 客户端在 P60P 运行）：
```
SA_CLIENT: GetSaWrap SA:10 not start
OHOS::RS: RenderService connect fail
```
- 客户端 `ConnectHub::Connect`（rs_base 0x375268）：`ISystemAbilityManager::GetSystemAbility(10)` 获取 RS 远端对象 → P60P 上 samgr 无 SA 10
- 对照：同一客户端在官方镜像上连接成功（binder 事务正常）
- 客户端代码与官方相同 → **RS 服务端点在 P60P 上从未注册进 samgr**
- sceneboard 走共享内存事务不依赖连接（所以首帧能出）；DMS 电源状态、app vsync、控制操作全走连接 → 全断 → 冻结。全线索闭环。

**RS 发布机制**：librs 无 AddSystemAbility 直接符号（经 ISystemAbilityManager vtable 间接调用）。5 处 w1=0xa 字面量均为无关用途。

**下轮假设**：RS 初始化时 samgr 未就绪 → `GetSystemAbilityManager()` 返回 null → 发布被静默跳过且无重试。官方上时序恰好 OK。
**验证/修复方向**：
1. boot 早期用 lldb 断 RS 进程的 AddSystemAbility 调用点（samgr vtable），看是否到达/返回 null
2. 若确认：给 RS 打重试补丁，或让 samgr 更早就绪，或 boot 完成后由同域服务补注册（需拿到 RS 的 IRemoteObject——较难）

## 追加 4：SA 10 注册攻坚战（03:45 实录）

**RS 发布代码定位**：`RSRenderService::Init`（librs 0x3bb950）内 0x3bc2c8 调 samgr vtable([x22+104])，参数 (x21=samgr, w1=10, x2=sp+0x70=RS对象sptr间接, x3=sp+0x38=SAExtraProp) —— 签名与 `AddSystemAbility(10, obj, prop)` 完全吻合。即 **RS 确实尝试发布 SA 10**。

**已排除**：
- 时序（RS 重启后 samgr 肯定就绪，仍失败）
- samgr profile 缺失（已加 /system/profile/render_service.json，字段名修正为 dump-level，仍失败）

**当前卡点**：samgr 侧 AddSystemAbility 的运行时验证——lldb 断 `SystemAbilityManagerProxy::AddSystemAbilityWrapper`（samgr 进程 0x7faae9f8c0）**断点插入失败**（error 9，SELinux/ptrace 限制）。无法确认 RS 的 Add 是「没到达」还是「被拒」。

**下一批候选**：
1. samgr（Rust 二进制）的 AddSystemAbility 权限校验逆向——找它检查 caller 的什么（token/权限名），对照 RS 的 accesstoken（RS 的 native token 在 P60P 华为 token DB 里可能缺关键权限）
2. 内核 audit 日志（samgr 拒绝时可能有 avc/拒绝日志被丢弃）
3. 终极方案：patch samgr 跳过 Add 权限检查（Rust 二进制，工作量大）

## 追加 6：分水岭结论——RS 只查不发（04:15 实录）

**运行时 vtable 鉴定**（读 rs_power_on 进程内 libsamgr_proxy vtable，RELATIVE 重定位已解析）：
- slot 13 (+104) = `GetSystemAbility(int32_t, const string& deviceId)` ← RS::Init 调的是它
- slot 17 (+136) = `AddSystemAbility(int32_t, sptr<IRemoteObject>, SAExtraProp)`
- 全 librs 搜索 **无任何 AddSystemAbility(10) 调用点**

**结论：RS 从不发布 SA 10，只查询**。官方镜像上 SA 10 由**另一个组件**发布（官方 profile/vendor 都无声明，发布者身份未定位）。P60P 上该发布者缺失或失效 → SA 10 不存在 → 全链路断。

**下一步候选**：
1. 官方镜像运行时断 samgr AddSystemAbilityWrapper（官方 SELinux 可能允许插桩），抓发布者 backtrace
2. P60P 全库扫描 slot17+10 模式（工作量大，候选：foundation 系/anco/rgm）
3. 若发布者定位不到：my vsync_on 服务（graphics 身份）拿到 RS 的 IRemoteObject 后代为注册——难点是获取 RS 对象，可考虑从 RS 进程内存挖 connection 单例

## 追加 7：Get→Add 自发注册实验（04:55 实录）

**思路**：RS::Init 0x3bc2c8 调的是 GetSystemAbility(10,devId)（slot+104），改成调 AddSystemAbility（slot+136）——单指令偏移 patch（0xF94036C8→0xF94046C8），让 RS 自己注册 SA 10。参数碰巧兼容（w1=10、x2=sp+0x70 正好是 RS 对象 sptr、x3=sp+0x38 是 SAExtraProp 但为 deviceId 字符串垃圾）。

**结果**：boot 挂起（开机动画定格）。两次尝试（第一次与 vdi 钩叠加，第二次干净 vdi 同样挂）。原因推测：samgr 代理序列化垃圾 extraProp 时事务卡死/崩溃，或 RS init 线程阻塞。

**重要排雷**：04:35-04:44 的 composer 崩溃潮**不是** profile/typepermissive 引起——是当时 vdi 的 GetDisplayCapability 钩仍部署在镜像（02:45 观察实验后再没还原）。md5 核验后立即定位。**教训再次验证：改完镜像必须 md5 验证部署物。**

**下轮正确姿势**：
1. x3 指向 librs .bss 的 32 字节零区（SAExtraProp 全 false）：需要把 `add x3, sp, #0x38` 改成 `adrp x3, zeropage; add x3, x3, #off`（两条指令替换一条，需找洞）
2. 或更简单：先验证垃圾 prop 时 samgr 的拒绝日志（挂起时 hdc 断了没法看——保持 hdc 会话或先开 persistent hilog 再实验）
