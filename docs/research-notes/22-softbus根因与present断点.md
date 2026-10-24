# 22 - softbus根因(文件属主) + 显示占位符真相 + present链路仍断

日期：2026-10-20（承接 docs/21）

## 突破3：softbus 框架初始化失败的根因 = 文件属主丢失

现象：softbus_server 起来后 `CommSvc: InitSoftBusServer# softbus framework init failed, err=-426049501`，之后 `server not init` 刷屏。

**定位过程**：把 601 的整套 softbus 库换进去故障照旧 → 排除库版本 → 是环境问题。抓 601 库的重启日志，逐行看 init 序列，找到：
```
LoadBusCenterPermissionJson# read file failed
BusCenterPermissionInit# load permission json fail
LnnInitPermission# load permission json fail
BusCenterServerInitFirstStep# Init lnn permission failed
InitServicesAndModules# softbus buscenter server init failed
```

**根因**：`/system/etc/communication/softbus/softbus_*_permission.json` 三个文件在我们的 `p60p_system.img` 里是 **root:root 0600**，而 softbus_server 跑在 **dsoftbus（uid 1024）** 用户下，读不了。

对照 601 模拟器镜像：同样这三个文件是 **0400 但属主 1024:1024（dsoftbus）**——所以模拟器里 dsoftbus 能读（属主就是自己）。

**这是镜像制作时文件属主信息丢失的结果**（payload 解包/重打包全变成了 root）。修复（debugfs sif）：
```
sif /system/etc/communication/softbus/<三个json> uid 1024
sif ... gid 1024
sif ... mode 0100400
```
改后 softbus framework init 不再失败、`server not init` 消失。

**⚠️ 这是系统性隐患**：整个镜像丢了对非 root 属主的记录。凡是以受限 uid 运行的服务（dsoftbus/huks_server/…）去读 0600/0400 root 文件的，都会踩坑。之后遇到服务莫名 init 失败，先查它要读的文件的属主。

## 级联随后全通

softbus 通了之后整条链自动恢复：
- DeviceManager(SA4802) 拿到 softbus → UDID 正常（镜像里 `const.product.devUdid` 本来就有值 `EMU...ARM`）
- distributeddata 的 `InitMetaData: get uuid failed` 消失
- SA 1301（datashare）可加载
- sceneboard 的 `DataShareHelper not initialized`/`no left retry times` 消失
- sceneboard 正常注册 DataShare observer（ret:0）、加载 Rdb、加载图标

## 桌面其实已完全建好（但没上屏）

sceneboard 的 HOME 日志显示桌面**完整加载成功**：
```
LauncherStartup: ... INIT_SCENE_BOARD, INIT_RDB, LOAD_UI_CONTENT, ENTRY_VIEW,
PHONE_STAGE, DESKTOP_VM, PERSIST_CONFIG, SCB_DESKTOP, PERSIST_CONFIG_PAGE (pages:3),
LOAD_DB, LOAD_BMS, DOCK_INIT, CORRECTOR, FILTER_BY_BMS, INIT_CACHE, GRID_INIT,
LOAD_GRID, INIT_LOCK, PAGING_FILTERING, VOTE_FINISHED
```
应用网格 3 页、dock、BMS、图标全建好。但它**从未 present 到物理显示器**。

## 决定性真相：转圈是宿主占位符，guest 从未出过一帧

之前以为窗口里的 "HarmonyOS+转圈" 是 guest 的开机动画。本轮用宿主 X 抓窗口（`tmp/xshot.py`，ctypes 直接 XGetImage 窗口 0xe00006），并做排除实验：

| 实验 | 结果 |
|---|---|
| 连续两帧 diff | 只在转圈区域 (227,429,263,466) 变化 → 转圈在动 |
| 杀掉 sceneboard 再抓 | 转圈照动 → 转圈不是 sceneboard 画的 |
| SIGSTOP 冻结 composer_host 再抓 | 转圈照动 → 转圈不经过 composer |
| composer FastPresent 断点 | 从未命中 → RS 从未向 composer present |

**结论：转圈是模拟器宿主的 Qt 窗口占位动画，guest 自始至终将 0 帧 present 到虚拟显示器。** sceneboard 桌面建好了但没到屏，RS 也从未把 splash present 出去。

## 当前唯一卡点：present 链路（sceneboard→RS→composer→显示器）

- vblank 通（composer↔RS 65Hz 应答），但 present（带内容的提交）从未发生。
- 真机 RS（895）日志仍有 `RenderFrame task too long: 21673ms`（一帧卡 21 秒）+ 偶发 `RSDrawFrame::SetEarlyZEnabled gpuContext is nullptr`（这是 RSDrawFrame 的缓存 context，主 GrContext 应已建立——无 "Init gpuContext is nullptr"/"drGPUContext is null" 报错）。
- SELinux 排除：render_service 只有一个 arkui_param 的读拒绝（无害），无 teleport/vulkan 拒绝。

## 下一步方向

查 sceneboard 的窗口为什么没提交给 RS：
- sceneboard 的主窗口（锁屏/桌面全屏窗）建没建、可见性如何
- sceneboard→RS 的 surface 连接/commit 是否发生
- RS 的 uni render 合成是否在跑、display 是否 on

## 工具沉淀

- `tmp/xshot.py`：宿主侧 ctypes 直读 X11 窗口像素 → ppm → png。绕开 guest 里全废的 screenCap/dumpLayout/uitest。窗口 id 用 `xwininfo -root -children` 找 "Emulator"。
- `tmp/ptrace_watch`：本轮新增 exec 模式（`-x lib offs ... -- cmd`，fork+TRACEME 起进程、等库映射后 SIGSTOP 下断）+ fp 链栈回溯（命中打 LR 归属）。注意：attach 后必须 CONT 全部线程；多断点紧邻时单步重放不可靠，关键点位要单独断。
