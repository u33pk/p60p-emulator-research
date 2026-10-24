# 84. vdi 半成品 patch 引发 composer_host 确定性崩溃 —— 修复后暴露 hotplug 断点（2026-10-23 07:40）

## TL;DR

- **实操验证（本轮用户要求）结论：系统不是冻结，是显示链断**。电源键命令生效（WakeupDevice is called）、shell/hilog/cloud/samgr 全活、sceneboard 反复重启但每次都正常初始化到建渲染树。
- **发现并修复一个回归**：vendor `libdisplay_composer_vdi_impl.z.so` 里残留「破口 1」的半成品 patch（42 字节，0xc1f4 附近 `bl`→`ret/br` + 0xd2f4 块），导致 **composer_host 每次启动 1–2 秒必 SIGBUS 崩溃**，三份崩溃 pc 完全一致（`0x0049443a49444812`，小端读出是 `HDI:DIS...` 服务名字符串——IPC 派发表把字符串当函数指针跳）。还原干净官方版（md5 `d92ef936`）后 composer_host 稳定存活。
- **修复后系统大幅前进**：RS 主线程不再卡 RenderFrame fence（空闲在 `ep_poll`），sceneboard 建出 `SCBDesktop5`/`SCBWallpaper`/`SCBScenePanel` 桌面渲染树。
- **新断点（当前唯一阻塞）**：**物理屏幕从未注册**——`IsAllScreensPowerOff: screenPowerStatus_ is empty`、`snapshot_display` 报 displayId 列表为空、全程零 `OnHotPlug` 日志。

## 一、实操验证结果（截图 + 实际操作，非仅看画面）

| 项目 | 命令 | 结果 |
|---|---|---|
| 电源键 | `power-shell wakeup` ×3 | **生效**：`WakeupDevice is called`，powermgr IPC 正常 |
| 电源键（宿主） | XTEST 点模拟器侧栏电源钮 | 画面无变化（当时全黑，判据无效） |
| 上滑解锁 | `uinput -T -m 660 1900 660 600 300` | **失败**：所有坐标（含 100,100）都报 `exceed the screen boundary`——注入通道本身被拒，非坐标问题 |
| 打开设置 | `aa start -a MainAbility -b com.huawei.hmos.settings` | **失败**：`error: failed to execute your command.`（aa/bm 全挂） |
| UI 树 | `uitest dumpLayout` | **超时**：`Wait for subscribe uitest.broadcast.command.reply timeout`，产出 0 字节 json |
| guest 截图 | `snapshot_display -i 0` | **失败**：`displayId 0 invalid!`，supported displayIds 列表为空 |
| shell/服务 | hilog、ps、power-shell、cloud、samgr | **全部正常**——系统服务层非常活跃 |

**定性**：不是 VM 冻结（进程/CPU/hilog 都在走），是显示+输入+ability 三条链都断在「没有 displayId」这一根因上。

## 二、composer_host 确定性 SIGBUS（已修）

### 崩溃现场

```
Reason: Signal:SIGBUS(BUS_ADRALN)@0x0049443a49444812
Fault thread: OS_IPC_0 / OS_IPC_1
Process life time: 1–2s
三份崩溃 pc 完全一致 → 确定性
```

- pc `0x0049443a49444812` 与 lr `0x5349443a49444812` 小端字节读出是 `HDI:DIS...` —— **服务名字符串被当成代码地址跳转**，IPC 派发表损坏。
- x7 = `layerColor` 字符串片段，x26/x28 落在 `libhdf_ipc_adapter.z.so`。
- 结果：composer_host 崩溃 → init 放弃拉起 → RS 每 10ms 报 `get hdi service display_composer_service failed, -1` → DMS 无 displayId → sceneboard `GetDefaultDisplaySync` 拿 nullptr → `LIFECYCLE_HALF_TIMEOUT` 反复死。

### 根因与修复

镜像里 vdi 实为 42 字节 patch 后的半成品（破口 1 的残留，0xc1f4 的 `bl` 被改成跳转指令）：

| 版本 | md5 | 与 clean 的差异 | 效果 |
|---|---|---|---|
| 干净官方（vcmp2/off_…） | `d92ef936…` | 基准 | composer_host **稳定** |
| 镜像内（半成品 patch） | `ccf5d144…` | 42B：0xc1f4 `bl→br` + 0xd2f4 块 | composer_host **必崩 1–2s** |
| verify_vdi.so 备份 | `5a1c3b89…` | 37B：0x6a8c `bl`替换 + 0xd2f4 块 | 本轮未测 |

修复：`debugfs -w` 把干净官方版写回 `p60pv2_vendor.img` 的 `/lib64/libdisplay_composer_vdi_impl.z.so`，删 qcow2 重启。**验证**：composer_host（PID 674）稳定运行，崩溃停止。

**教训（对破口 1）**：任何 vdi 注入必须完整实现、单独验证 composer_host 存活后再观察效果；0xc1f4 一带的改动会直接打烂 IPC 派发，症状是指令级确定性 SIGBUS。

## 三、修复后的新状态（前进一大步）

- RS 主线程 **`ep_poll` 空闲**（此前 70s+ 永驻 RenderFrame fence）——fence 死锁随 composer 存活而消失，docs/83 的因果链被打破。
- sceneboard 稳定运行（不再 LIFECYCLE_HALF_TIMEOUT），并成功创建渲染节点：
  `SCBScenePanel1` / `BackgroundBlurView2` / `TransparentView3` / `SCBWallpaper4` / **`SCBDesktop5`** / `sceneboardEngineServiceAbility`
- HGM 初始化成功（60/90/120Hz 软件 vsync rate 注册）。

## 四、当前唯一断点：物理屏幕未注册（hotplug 链）

症状：
```
RSScreenManager: IsAllScreensPowerOff: screenPowerStatus_ is empty   ← 无任何屏幕
RSScreen: GetScreenColorGamut failed
snapshot_display: displayId 0 invalid!  supported displayIds: (空)
全程零 OnHotPlug / DoHotPlugCallback 到达 RS
```

composer_host 侧可见 `DisplayComposerVdiImpl start thread hotplug`、`DoHotPlugCallback` 字符串（h000 strings），即 hotplug 线程有启动痕迹，但事件未抵达 RS。

hotplug 正常链（docs/80）：RS Init → `HdiDevice::GetInstance` → `IDisplayComposerInterface::Get`（SMQ）→ `RegDisplayHotPlugCallback` → composer hotplug 线程 → `OnHotPlug(0,1)` → 屏幕 0 连接。

docs/80 验证该链在 SMQ 双 NOP 后是通的（屏幕 0 连接、SetDisplayPowerStatus ON）。SMQ patch 复核仍在（vaddr 0x1fc58/0x1fef8 = `1f2003d5`）。**版本无误**（docs/82 确认稳定态即 d92ef936）。差异只能来自 docs/80 之后的改动：libvsync 软件模式 patch、libchipset_vsync fake、vsync_on 服务、samgr 6.0 三件套、system.img 属性改动。

**下轮抓法**：`hilog > file &` 挂持续抓取再 kill render_service，看 `RSScreenManager::Init`/`RegScreenHotplug`/`HdiDevice::GetInstance` 全过程，定位断在哪一环。

## 五、环境备注

- guest 分辨率确认：`config.ini` `hw.lcd.single.width=1320 height=2232`。
- hdc 通道会整体消失（Emulator 的 TCP 5555 监听消失，进程仍活），需重启模拟器恢复；guest 工具在 /data/local/tmp 会被清空。
- uinput 对任意坐标都报超界 = MMI 侧拿不到 display，与 displayId 缺失同根因，预计 hotplug 通后自愈。
- 半成品 vdi 留档：`tmp/vdi_patched_halfdone_bak.so`。

## 六、下一步

1. 挂 hilog 落盘 → kill RS → 定位 Init/HotPlug 断环（首要）
2. 对照模拟器原版镜像的 hotplug 时序（必要时）
3. hotplug 通 → displayId 出现 → 顺带验证：guest 截图、uinput 注入、aa start（三者应随 displayId 自愈）
4. 桌面出图后：滑动验证 → 宿主鼠标 → 归档
