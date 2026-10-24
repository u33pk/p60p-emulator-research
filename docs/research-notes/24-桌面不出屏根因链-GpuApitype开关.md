# 24 — 桌面不出屏的完整根因链（systemGpuApiType_ 开关）

日期：2026-10-20

## 结论摘要

guest 从未出过一帧的根因不是显示驱动、不是 composer、不是 Vulkan 能力，
而是 **`RSMainThread::Init` 提前返回，导致屏幕节点监听器从未注册**。

触发条件是一个配置缺口：`persist.sys.graphic.GpuApitype` 参数在混合镜像里不存在，
使 `systemGpuApiType_ = 0`，`SetUpGpuContext` 走 OpenGL 分支失败，GPU 上下文恒为 null。

## 根因链条（每一环都有日志/反汇编实证）

```
persist.sys.graphic.GpuApitype 参数不存在 (errNum 106)
        ↓
Drawing::SystemProperties::systemGpuApiType_ = 0
        ↓  (librender_service_base 静态初始化 entry.init464 @ 0x6e80ac 复制给)
RSSystemProperties::systemGpuApiType_ = 0
        ↓
RenderContext::SetUpGpuContext (librender_service_base.z.so 0x396578)
   检查 *systemGpuApiType_：为 0 → OpenGL 分支 (0x3966e4)
        ↓
GPUContext::BuildFromGL() 返回 false
        ↓  (0x3967f4 tbz w0,0 → 0x396894 打印错误)
日志: "SetUpGpuContext: SetUpGrContext drGPUContext is null"
        ↓  renderContext+8 (gpuContext) 保持 null
RSMainThread::Init (librender_service.z.so 0x39a948)
   0x39b278 ldr x8,[this+0x1a0] → +8 → +8  取 gpuContext
   0x39b284 cbnz x21, 0x39b704   ← 为 null 就不跳
        ↓
日志: "Init gpuContext is nullptr!" (0x39b288~0x39b2b8)
        ↓  直接走函数尾声 0x39b2bc → ret (0x39b334)
RegisterScreenNodeListener (0x39b914) 永不执行
        ↓
RSScreenManager::screenNodeListener_ 保持 nullptr
        ↓
ProcessScreenConnected 里 NotifyScreenNodeChange 报
   "screenNodeListener_ is nullptr!"
        ↓
RSMainThread::RSScreenNodeListener::OnScreenConnect 不触发
        ↓
foundation 的 ScreenSessionManager 收不到 OnScreenConnect
   (TriggerCallbacks: screenChangeCallbacks_.size() 0 —— 连订阅者都没有)
        ↓
ScreenSession 不创建 → AddDisplayNodeToTree 不调 → 无显示节点
        ↓
sceneboard: rsId:0、"get Container Session List with screenId: 0 failed"
        ↓
从不提交帧 → RS 不合成 → composer 不 present → guest 零帧
```

## 关键证据

### 1. ProcessScreenConnected 其实是走通的

重启 render_service 后（begetctl start_service）日志：

```
OnHdiBackendHotPlugEvent: HotPlugEvent, screenId is 0, connected is 1
OnHotPlugEvent: screen 0is connected, event has been saved
ProcessScreenConnected The screen for id 0 connected.
ProcessScreenConnected The screen id 0 is set to defaultScreenId.
add screen: w * h: [1320 * 2232]
NotifyScreenNodeChange: screenNodeListener_ is nullptr!      ← 断点在这
TriggerCallbacks: id 0 event 0 reason 0 screenChangeCallbacks_.size() 0
Init succeed
```

之前 docs/22/23 认为"握手不走 ProcessScreenConnected"是在 RS 死掉期间做的观察；
RS 活着时它是能走通的，只是下游 listener 为空。

### 2. 时序（不是简单的启动竞态）

```
10:46:59.312 (tid 12744) SetUpGpuContext: drGPUContext is null
10:46:59.398 (tid 12750) SetUpGpuContext: drGPUContext is null
10:46:59.403 (tid 12740) RSMainThread: thread init
10:46:59.404 (tid 12740) RSMainThread: Init gpuContext is nullptr!
```

`SetUpGpuContext` 失败在 RSMainThread::Init 之前；并且 composer 重连再触发一次
热插拔时，`screenNodeListener_` 仍然是 nullptr —— 说明不是"注册晚了"，而是
**根本没注册**（Init 提前 return 了）。

### 3. SetUpGpuContext 的两条分支（librender_service_base.z.so）

```
0x3965a4 ldr x8,[x0,8]        ; renderContext+8 现有 gpuContext
0x3965a8 cbz x8, 0x396638     ; 为空才走 setup
0x396638 ... ldr w8,[*systemGpuApiType_]
0x396644 cbz w8, 0x3966e4     ; ==0 → OpenGL 分支
0x396648 ldr x8,[x1]          ; 传入的 drGPUContext
0x39664c cbnz x8, 0x396820    ; 非空 → 直接采用
0x396650 ...                  ; 为空 → 自己调 RsVulkanContext::CreateDrawingContext
```

**重要**：GL 分支完全无视传入的 Vulkan drawing context，直接 `BuildFromGL`。
我们此前在 `RSBaseRenderEngine::Init` 打的强制 Vulkan 补丁（0x410518 `b 0x410570`）
确实让 `CreateDrawingContext` 跑起来了，但结果在 SetUpGpuContext 里被 GL 分支丢弃。

### 4. systemGpuApiType_ 的来源

- `lib2d_graphics.z.so` 里 `Drawing::SystemProperties::systemGpuApiType_` (0x2f7d28)
  由 `GetSystemGraphicGpuType()` 从参数 **`persist.sys.graphic.GpuApitype`** 读取
  （`atoi` 后比较：1 → 返回 1；2 → 走额外检查）
- `librender_service_base.z.so` 静态初始化 `entry.init464` (0x6e80ac)
  把它复制到 `RSSystemProperties::systemGpuApiType_` (0x770770)
- 两者都在**库加载时**定值，所以改参数后必须重启 render_service

## 修复动作

```
param set persist.sys.graphic.GpuApitype 1
begetctl start_service render_service     # 重启让它重新读参数
```

已验证 `param set ... success`、`param get` 返回 1。
**注意**：`begetctl stop_service render_service` 会让模拟器整个退出
（render_service 是 critical 服务，停它触发级联 + 模拟器心跳看门狗），
所以重启要用 start_service（对已停的服务）或直接冷启动模拟器。

## 附带发现

1. **render_service 会自己死掉**：分析中途发现 RS 进程不在了（此前认为"杀 composer 会连带杀 RS"
   的说法不准——实测杀 composer_host 后 RS 存活，composer 自己重启）。
   RS 死掉后不会自动拉起（`disabled: 1`，靠 `bootevent.composer_host.ready` 触发），
   需要 `begetctl start_service render_service`。

2. **模拟器慢性不稳定**：`crash_server.log` 里 `Client heartbeat lost, exit` 有 44 次，
   `memory is low, freeMem: 0 ,mCurHostTotalMemory: 0` 从 10-18 起就有 19 万次
   （宿主内存其实充足，是模拟器自己取内存返回 0）。模拟器会周期性自杀，
   重启即可，与本次修复无关。

3. **模拟器启动必须用绝对路径**，相对路径会报 `ErrorCode 00801003 镜像文件路径更改`。

4. 模拟器控制命令（`-instance <name> -rotation/-power/-foldedState`）可用，
   但旋转/折叠**不会**触发显示热插拔；非折叠机型不支持 foldedState。

## 下一步

- 验证参数生效后 RSMainThread::Init 走完 → listener 注册 → OnScreenConnect →
  ScreenSession 创建 → AddDisplayNodeToTree → sceneboard 出帧 → 桌面可见
- 若仍不出屏，检查 `TriggerCallbacks` 订阅者（foundation ScreenSessionManager）
  是否需要在其侧补注册
