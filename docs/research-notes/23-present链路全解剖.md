# 23 - present链路全解剖：sceneboard不提帧的完整定位

日期：2026-10-20（承接 docs/22）

## 方法：全链路 ptrace 断点逐环验证

用自研 `tmp/ptrace_watch`（多断点 + fp 栈回溯 + exec 启动模式）在**活着的** guest 进程里逐环下断，把"为什么不出画面"彻底拆开。结果：

| 环节 | 函数 | 是否被调 |
|---|---|---|
| sceneboard 建 surface 节点 | `RSSurfaceNode::CreateNodeAndSurface` (librender_service_client 0x1ffe28) | ✅ 在调 |
| sceneboard 提交帧 | `RSTransaction::Commit` (0x1acd2c) | ❌ 从未 |
| sceneboard 建 GL 上下文 | `eglCreateContext` / `eglSwapBuffers` | ❌ 从未 |
| sceneboard 挂显示节点 | `RSDisplayNode::CreateNode`/`AddDisplayNodeToTree` (0x1bd80c/0x1bd924) | ❌ 从未 |
| RS 合成提交 composer | `RSUniRenderComposerAdapter::CommitLayers` (rs_base 0x426edc) / `RSHardwareThread::CommitAndReleaseLayers` (0x1e1658) | ❌ 从未 |
| composer present 到显示器 | `DisplayComposerService::FastPresent` (libdisplay_composer_service_1.3 0x150e0) | ❌ 从未 |
| RS 渲染线程状态 | RSUniRenderThread | 空闲（event loop 等活，没脏帧） |

## 屏幕接入握手断在哪

composer→（虚拟屏创建 OK：`emulator create display 0 1320 2232`，hotplug 正常）→ **RS `RSScreenManager::OnHotPlug` 被调（重启 composer 时实测命中）** → 但之后：
- `RSScreenManager::ProcessScreenConnected`（0x465388）不触发
- `RSMainThread::RSScreenNodeListener::OnScreenConnect`（0x3ae38c）不触发
- foundation 里 `ScreenSessionManager::OnScreenConnect`（libscreen_session_manager 0x1650b8，服务端在 foundation）不触发
- → 显示节点不挂树（`AddDisplayNodeToTree` 命令从未到 RS）

**谁负责挂显示节点**：`AddDisplayNodeToTree` 的客户端入口在 `librender_service_client.z.so`，全系统只有 `platformsdk/libscreen_session_manager.z.so`（屏幕会话管理器）import 它。它的服务端在 **foundation** 进程。sceneboard 只是 client（加载的是 `libscreen_session_manager_client.z.so`）。

## 结论

显示呈现断在**屏幕会话握手**：composer 热插拔到了 RS，但 RS 没把屏幕事件传给 foundation 的 ScreenSessionManager（`OnScreenConnect` 从未触发），于是显示节点不挂树、sceneboard 窗口拿不到 rsId（实测 `rsId:0`、`get Container Session List with screenId: 0 failed`）、不建 surface、不渲染、不提帧。

guest 自始至终 present 0 帧；窗口的"转圈"是模拟器宿主的 Qt 占位动画。

## 排查中排除的（都不是根因）

- SELinux：render_service 无 teleport/vulkan 拒绝（只一条无害的 arkui_param 读拒绝）
- 屏幕电源：IsScreenOn=1，屏是开的
- 文件属主（softbus 那个坑）：已修
- GPU/Vulkan、HUKS：都通了

## 下一步

查 RS 的 OnHotPlug→ProcessScreenConnected 为什么没走通（可能 RS 侧屏幕创建失败、或 RS→foundation 的 DisplayManagerAgent 通知没注册/没发）。也可以评估用 601 的 display/window 会话栈替换的可行性。
