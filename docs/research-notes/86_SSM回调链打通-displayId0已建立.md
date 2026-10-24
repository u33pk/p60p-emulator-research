# 86. SSM→RS 回调链打通，displayId 0 分配成功，UI 层全通（2026-10-23 08:55）

## TL;DR

**本轮重大突破**：ScreenSessionManager（SA:3299，foundation 内 `screen_session_manager.cpp`）→ RS 的回调注册链走通，**displayId 0 成功分配**，sceneboard/WMS/输入法全拿到屏幕（`PrintDisplayInfo: 1320x2232`）。UI 层从「displayId 空、全挂」变为「displayId 0 已建立」。

**剩余唯一断点在渲染层**：`RSBaseRenderEngine::RequestFrame: request SurfaceFrame failed` + `gpuContext is nullptr` + `RenderFrame task too long: 59566 ms`——RS 的 EGL 上下文仍建不起来，画面不出。uinput/aa 仍挂（可能也依赖出图或另有阻塞）。

## 一、SSM→RS 回调链：完整时序（hp3.log 实证）

```
RS RSScreenManager::Init succeed
→ TriggerCallbacks: screenChangeCallbacks_.size() 0        ← 首次事件时还没有 listener
→ SSM: RegisterScreenChangeListener(741): start            ← 160ms 后 SSM 注册
→ RS: AddScreenChangeCallback: add a remote callback succeed
→ SSM: OnScreenChangeDefault(994): screenId: 0 screenEvent: 0
→ SSM: GetOrCreateScreenSession(3052): ScreenId: 0
→ SSM: CreateScreenProperty: GetScreenActiveMode → 1320x2232
→ SSM: GetDefaultScreenId(3194): Default screen id : 0
→ SSM: CreateDisplayNode(134): config screenId: 0
→ SSM: InitAbstractScreenModesInfo: fill 1320/2232 activeModeId:0
→ WMS: AddFocusGroup: displayId: 0 / PrintDisplayInfo: 1320|2232|480
→ sceneboard: CreateSceneSession winId 3/4 displayId 0
→ inputmethod: getDefaultDisplaySyncWrapper displayId:0
→ DMS SA OnStart end
```

**关键**：SSM 注册回调晚于首个 hotplug 事件（160ms），但**它注册后会主动 `OnScreenChangeDefault` + `GetOrCreateScreenSession` 拉取现状**，不依赖事件重放。所以只要 RS 侧 `Init succeed` 且屏幕在，SSM 就能跟上。

**触发方法**（复现步骤）：
```sh
hdc shell pkill -x render_service   # RS 重启 → composer hotplug 重发时序对齐
# 等 25 秒（SSM 跟上 + DMS OnStart）
```
或 `pkill -x composer_host`（重发 hotplug 到已 Init 的 RS）——两种都能让链走通，但 **RS 重启 + 等 25 秒** 最干净（本轮验证通过）。

## 二、本轮修的另一坑：composer_host 拉起链

`pkill composer_host` 后若**手动** `nohup hdf_devhost` 启动，会卡在 `GetSaWrap SA:5100 not start`（缺 devmgr attach 流程），且干扰 init 的 respawn 状态，之后 composer_host 再也拉不起来。**必须让 init/hdf_devmgr 自己拉**（pkill 后等 8 秒），或重启模拟器恢复。

## 三、当前渲染层断点（下一目标）

```
RSMainThread: RenderFrame task too long: 59566 ms
skia: RSBaseRenderEngine::RequestFrame: request SurfaceFrame failed!
     RSScreenRenderNodeDrawable::RequestFrame renderEngine requestFrame is null
     RSDrawFrame::SetEarlyZEnabled gpuContext is nullptr!
RSSurfaceOhosGl: Invalid eglSurface, return
```

- 与 docs/84/85 记录的 `Invalid eglSurface` 同源：RS 的 EGL context/ surface 建不起来。
- `librender_service.z.so` 版本敏感（docs/85）：归档版 `87ccfa650c`（手机原版+2补丁）GL 能渲染但系统卡死；当前版 `43a30162df` 系统正常但 EGL 断。
- 已排除：libEGL_impl.so 在 guest 内 `dlopen` 正常（dltest2 实测 OK），namespace 路径含 /system/lib64，SELinux 标签已补。
- **怀疑方向**：`RSSurfaceOhosGl` 创建 EGL surface 需要 composer 侧的 buffer producer/ANativeWindow；`GetDisplayProperty -2 not supported`（composer_host 报）可能导致 surface 属性拿不到。或需查 RenderEngine 的 EGL config 选择（模拟器 GPU 通过 libdgles.z.so 转发）。

## 四、uinput/aa 仍未恢复

displayId 0 已建立，但 `uinput -T -c` 仍报坐标超界、`aa start` 仍 fail。可能：
- uinput 走 MMI，MMI 的 display 映射依赖 `GetDisplayProperty`（composer 报 -2 not supported）——同一断点
- aa/bm 的 shell 命令通道可能另有阻塞（待查）

## 五、下一步

1. **攻渲染层 EGL surface**（唯一出图断点）：查 `RSSurfaceOhosGl` 创建路径 + composer `GetDisplayProperty` 返回 -2 的属性项；或对比归档版 librender_service 的 EGL 初始化差异（二分 patch）
2. 出图后验证 uinput/aa 是否随之自愈
3. 滑动验证 → 归档
