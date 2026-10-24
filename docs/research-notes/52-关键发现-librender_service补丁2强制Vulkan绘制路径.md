# 52. 关键发现：librender_service 补丁 2 把 RS 推上了 Vulkan 绘制路径

日期：2026-10-21

## 发现

`librender_service.z.so` 的第 2 处补丁（文件偏移 `0x40F518`）：

```
原版:  cbnz w21, 0x410570      ; w21==0 → GL 路径(0x41051c)；w21!=0 → Vulkan 路径
补丁:  b     0x410570          ; 无条件走 Vulkan
```

**w21 是 GL / Vulkan 绘制上下文的选择开关**（从全局 `*(0x552000+0xa10)` 读入）：

```
0x4104f8  w21 = *global_flag
0x410504  cbnz w21, skip
0x410508  InitializeEglContext()          ← w21==0 时初始化 EGL
0x410510  IsUniRender()
0x410514  tbnz w0, 0, uni_render_path
0x410518  cbnz w21, 0x410570              ← 选择分支
       ┌─ 0x41051c  CFI 校验 + 虚调用       （GL 绘制上下文路径）
       └─ 0x410570  RsVulkanContext::GetSingleton()
                    RsVulkanContext::CreateDrawingContext()   ← Vulkan 路径
```

我们的补丁**强制走 Vulkan**。而当前环境里 Vulkan 是不可用的
（docs/43 已移除 `libzvulkan.z.so` 与 Vulkan ICD；
更早也确认 `VK_KHR_external_memory_win32` 在 Linux 上不存在）。

⇒ **RS 的绘制上下文被建成了 Vulkan 的、且这个上下文是坏的**。
这解释了此前"图层结构全对、gbuffer 全对、宿主 paint 也跑了，但画出来是空的"：
**根本没画出东西**，宿主拿到的是空缓冲。

## 本轮实验：还原补丁 2（保留补丁 1）

从原版重建 `librender_service.z.so`，只保留补丁 1
（`bl` → `RegisterScreenNodeListener`，文件偏移 `0x39A2B8`）：

```
与原版逐字节差异 = 3 字节（仅补丁 1）
md5 = 348680be49
```

结果：

| | 补丁 2 强制 Vulkan | 还原补丁 2 |
|---|---|---|
| host 窗口 | 42KB 占位图 | **42KB 占位图（仍未出屏）** |
| guest | 正常 | **hdc 无响应（变差）** |

⇒ **单还原补丁 2 不能出屏，反而让 guest 状态变差**。
与 docs/43 的历史记录一致："这两处必须保留，去掉后 sceneboard 的窗口树建不起来"。

## 怎么理解这个矛盾

补丁 1（`RegisterScreenNodeListener`）负责**建桌面节点树**；
补丁 2（强制 Vulkan 路径）大概率是当初为了让 RS **能建起绘制上下文**才打的
—— 因为在当前环境里 GL 路径（`InitializeEglContext`）可能起不来。

也就是说：**两条路都不通，补丁 2 是在"GL 起不来"的情况下被迫选的坏路**。

真正要解决的是：**让 RS 的 GL 绘制上下文能正常建立**
（`w21 == 0` 分支的 `InitializeEglContext()`），而不是继续在
GL/Vulkan 两条坏路之间二选一。

## 下一步

1. 查 `w21` 那个全局（`*(0x552000+0xa10)`）是什么参数，
   什么条件会让它非 0（很可能是某个 param / 系统属性）。
2. 查 `InitializeEglContext()` 为什么在我们环境里失败
   （很可能与 docs/29 的 emutls 上下文分裂、或 EGL context 创建有关）。
3. 在 `0x410508` 的 `InitializeEglContext` 调用后插一条日志，看它的返回值。
4. 若 GL 路径能通，再还原补丁 2，RS 就走正常 GL 绘制 → 应能出屏。

## 状态

- `librender_service.z.so` 当前 = **原版 + 仅补丁 1**（`348680be49`）
- guest 侧状态变差（hdc 无响应），需要重新冷启动确认
- 宿主 Emulator 仍是插桩版（docs/51），原版备份 `tmp/Emulator.before_instr`
