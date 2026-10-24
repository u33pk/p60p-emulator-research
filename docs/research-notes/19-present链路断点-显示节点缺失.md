# 19 - present 链路攻坚：RS 渲染树没有显示节点，命令通道断点定位

> 状态：进行中。本文档记录 2026-10-19 这轮"为什么不出桌面"的完整排查结论。
> 桌面仍未出（窗口静止转圈残影）。核心结论：**不是 vblank/generator 问题**（那个链路已通），
> 而是 **RS 的渲染树里从未挂上逻辑显示节点 → 从不 present**。

## 一、已打通/已排除的部分（本 boot 实测，均在线验证）

| 环节 | 状态 | 证据 |
|---|---|---|
| composer vblank 65Hz 送达 RS 并被应答 | ✅ | binder 统计 +65/s，transaction_log 有 687→RS(ret 0/0) |
| VSyncGenerator 脉冲 | ✅ | 有请求才发；sceneboard(WM_xxxx) 请求后 "First vsync has send to" |
| 屏幕注册 | ✅ | RSScreenManager: GetScreenActiveMode screen[0] 1320x2232@60；DMS/sceneboard 收到 OnScreenConnectionChanged |
| sceneboard 建窗/请求vsync | ✅ | CreateNodeAndSurface 一批 SCB* 节点成功 |
| express 图像 buffer 分配 | ✅（现网） | 直接用 guest 调 ExpressAllocMem 各种尺寸/format 全 rc=0；早先两次 192x192 失败是启动竞态 |

## 二、generator 结论（docs/18 的收尾）

逆向 libvsync.z.so（107）：
- ThreadLoop 在 `condvar::wait` 无限等待 = **"无 listener" 空闲等待**，不是 bug。period_ 实测有值（≈63.6Hz，非 0）。
- listener 加入链：distributor->EnableVSync(true) → controller->SetEnable → `generator->AddListener`（vtable 槽 9）。
- 触发链源头是 `RequestNextVSync`（distributor 收到请求才 EnableVSync）。有人请求 → 有脉冲 → 证实全链路 OK。
- 所以 generator 清白；之前"generator 不产脉冲"是"没人请求"的表象。

## 三、真正的断点：present 从未发生

binder 铁证：composer_host 的入向 BR_TRANSACTION 整个生命周期只有 ~24 次（全是启动期查询），**PresentDisplay/SetClientTarget 一次都没有**。RS 在渲染（RSDrawFrame 每帧跑、`SetEarlyZEnabled gpuContext is nullptr` 按 60Hz 刷），但**渲染的内容从未 present**。

### 陷阱/计数器实证（对 107 librender_service.z.so 打点，看哪些函数跑到）

| 函数 | 结果 |
|---|---|
| RSDrawFrame::RenderFrame | 每帧都跑（每帧打 gpuContext null） |
| RSLogicalDisplayRenderNodeDrawable::OnDraw | **从未跑**（bss 计数器=0） |
| RSScreenRenderNodeDrawable::OnDraw | **从未跑** |
| RSUniRenderProcessor::PostProcess | **从未跑**（brk 陷阱无声） |
| RSUniRenderComposerAdapter::CommitLayers | **从未跑** |
| RSHardwareThread::CommitAndReleaseLayers / Redraw | **从未跑** |
| DisplayNodeCommandHelper::CreateWithConfigInRS（建显示节点） | **从未跑**（rs_base brk 陷阱无声） |

=> RS 的渲染树里**根本没有逻辑显示节点被绘制**，present 路径整体未激活。

### 上游（谁该让 RS 建显示节点）

- RSLogicalDisplayRenderNode 由 `DisplayNodeCommandHelper::Create/CreateWithConfigInRS` 创建——这是**客户端提交事务里的命令**（DMS/sceneboard 经 RSClient 写入命令流，RS 处理事务时执行）。
- DMS(foundation) 侧日志显示：`screen_session.cpp CreateDisplayNode` 被调用了（DMS 发出了）。
- **修正**：显示节点其实**建出来了**——扫 RS 内存找到 2 个 `RSLogicalDisplayRenderNode` 实例（vtable 扫描 2 命中）。所以 Create 命令是到了 RS 的。
- 但节点建了却**从未被绘制**（OnDraw 计数器=0）→ 问题在"挂树"环节：`AddDisplayNodeToTree` 命令没到，或渲染遍历没走到它。

### sceneboard 侧的并发故障

- `SCBScreenSM: Failed to get default screen session!` —— 启动早期 sceneboard 向 DMS 要 screen session 失败（**时序竞态**；系统稳定后重启 sceneboard 即恢复）。
- `SCBScreenSM: init orientation settings DataShare error: DataShareHelper is not initialized successfully` ×N —— **settingsdata 的 DataShare 服务持久不可用**（settingsdata 进程没在跑；`aa`/`bm` 命令也整体失败 → 应用框架层（AMS/BMS）也有问题）。SCBScreenSM 因此无限重试，可能永远走不到"建显示节点"那一步。

## 四、GPU/Vulkan 背景（重要约束）

- **107(手机) RS 强依赖 Vulkan**：`RSNormalProcessExecutor::CreateGrContext` 无条件走 `RsVulkanContext::GetSingleton → BuildFromVK`。
- **模拟器全系镜像（600/601）都没有 Vulkan 驱动**；模拟器的 RS(48/600/601) 是 **GL 架构**（libdgles.z.so，走 /dev/teleport_express express 通道）。
- 宿主机 GL 正常（qemu.log: gl vendor NVIDIA RTX A2000, "native windows inited"）。
- 已把 600 的整套 GL 栈铺进 107 system.img：libdgles.z.so + 4 个 impl（libEGL_impl/libGLESv1/2/3_impl 之前被我误铺成同一个 EGL 文件，已纠正为 libdgles）+ libEGL.so + libGLESv3.so + libegl_effect.z.so。
- 但 **107 RS 从不初始化 GL**（日志无 DGLES init），因为它只走 VK。`gpuContext is nullptr` 每帧都在刷。
- framebuffer surface 类型选择器（CreateFrameBufferSurfaceOhos 读的全局）实测=**0（GL）**，即选了 RSSurfaceOhosGl——但 GL 未初始化，RSSurfaceOhosGl 也起不来。

## 五、当前卡点的一句话总结

107 手机 RS 的渲染/上屏管线为 Vulkan/GPU 设计，模拟器无 Vulkan 驱动 → RS 有 gpuContext=null 的软渲染空转；同时 RS 里逻辑显示节点**建了但从未被绘制**（没挂进渲染树）→ 永不 present → 桌面永远不出来。挂树依赖 sceneboard/WMS 走完屏幕状态机下发 AddDisplayNodeToTree 命令，而 sceneboard 因 settingsdata/DataShare 持久故障 + 启动期 screen session 竞态卡住。

## 六、可选方向（待决策）

1. **整套图形栈换成 601 模拟器版**（render_service/bin + librender_service.z.so + librender_service_base.z.so + libcomposer.z.so + libvsync.z.so + librender_service_client.z.so 等），让 RS 变回 GL 架构。风险：107 的 sceneboard/客户端 与 601 RS 的 binder ABI 兼容性未知（rs_base 是 server/client 共享库）。
2. 修 settingsdata/DataShare + 追 sceneboard 为什么不下发 display-node 命令（也许修好 DataShare 后 SM 走通，显示节点就建了）。
3. 继续钉 107 RS：找到"无 GPU 时渲染树也该挂上屏节点"的回退逻辑为何没生效。

## 附：本轮调试工具/方法备忘

- 免 root 改镜像：`debugfs -w -f xxx.dfs <img>`（rm/write/sif mode/ea_set security.selinux）。
- 进程内读内存：ptrace_read/ptrace_findhex（vptr 扫描定位对象实例）。
- 函数打点数：text 段找 ≥64B 零洞做 cave，入口改 `b cave`，cave 里重放被换掉的 adrp + 对 bss 尾计数器自增（不崩进程）。
- **坑**：brk 陷阱打在每帧都跑的函数上会让 faultlogger 把 guest 拖死（qemu HeartBeat stop → 整机被杀）。
- **坑**： Emulator 的 `image_path_change` 清除数据弹窗 = `-imageRoot/-instancePath` 传相对路径触发；传**绝对路径**即消失。弹窗与 userdata 无关（删 userdata 也弹）。
- pkill/pgrep 模式匹配会匹配到自己（bash -c 的命令行含同样字符串）→ 用 `pgrep -x Emulator`。
- qemu-img convert 在本机因 RLIMIT_MEMLOCK=8192 走不了 io_uring（离线读 userdata 暂时不可行）。

