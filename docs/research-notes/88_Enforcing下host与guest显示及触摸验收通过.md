# 88. Enforcing 下 host/guest 显示与真实触摸验收通过（2026-10-24）

## 最终验收结论

P60P 真机 system 镜像 + 官方模拟器 vendor/内核已能正常显示和操作，SELinux 保持 **Enforcing**：

- host 锁屏正常，时钟随真实时间变化。
- 上滑触发 `UNLOCK_DIRECT`，解锁动画和系统 UI 正常。
- 下拉控制中心正常，点击齿轮可打开完整“设置”APP。
- 设置页可滚动。
- 电源键可熄屏，再次按下可重新点亮到锁屏。
- 通过系统“截屏”按钮取得 guest 原生 1320×2232 截图，内容与 host 一致，不再黑屏。
- 冷启动复验再次完成“锁屏 → 解锁 → 控制中心 → 设置”。复验时 `whoami=root`、`getenforce=Enforcing`、`bootevent.boot.completed=true`。

因此本轮目标“桌面在 host + guest 正常出现，滑动正常使用”已达成。这里“桌面正常”指系统 UI 可正常进入和操作；首次全新 userdata 的 launcher 仍可能记录 `DesktopLayoutCacheData: gridItemList is invalid`，应用可通过控制中心等系统入口打开。

## 真实输入方案

内核 `/proc/misc` 没有 `uinput`，但系统已有 `/dev/input/event2`（virtio touchscreen），范围为 1320×2232。`tmp/input_event_inject.c` 直接写标准 Linux `input_event`，不依赖 MMI 的 shell 注入 API：

```sh
hdc file send tmp/input_event_inject /data/local/tmp/input_event_inject
hdc shell 'chmod 755 /data/local/tmp/input_event_inject'

# 上滑解锁
hdc shell '/data/local/tmp/input_event_inject /dev/input/event2 swipe 660 1800 660 700'
# 下拉控制中心
hdc shell '/data/local/tmp/input_event_inject /dev/input/event2 swipe 1000 0 1000 1000'
# 点击控制中心右上角设置齿轮
hdc shell '/data/local/tmp/input_event_inject /dev/input/event2 swipe 1030 330 1030 330'
# 设置页滚动
hdc shell '/data/local/tmp/input_event_inject /dev/input/event2 swipe 700 1700 700 700'
# 电源键
hdc shell '/data/local/tmp/input_event_inject /dev/input/event8 power'
```

日志证明事件经 MMI 分发到 sceneboard，并出现 `SlideScreenLockVM: UNLOCK_DIRECT`。这不是“仅截图看起来正常”的误判。

## guest 截图

root 下 `snapshot_display` 仍受 displayId/access-token 工具链限制，报 `displayId 0 invalid`；`aa start` 也仍失败。它们不影响系统 UI 的真实显示和操作。

使用系统控制中心“截屏”按钮，可生成正常 guest 图片：

```
/storage/media/100/local/files/Photo/16/IMG_1792818671_000.jpg
```

取回：

```sh
hdc file recv /storage/media/100/local/files/Photo/16/IMG_1792818671_000.jpg tmp/guest_settings_capture.jpg
```

guest 原图：`tmp/guest_settings_capture.jpg`（1320×2232）；对应 host：`tmp/settings_scrolled_host.png`。

## 关键截图

- `tmp/cleanrs_host.png`：Enforcing 下首次正常锁屏。
- `tmp/direct_swipe_host.png`：真实上滑后的解锁画面。
- `tmp/control_center_host.png`：控制中心。
- `tmp/settings_open_host.png`：设置首页。
- `tmp/settings_scrolled_host.png`：设置页滚动后。
- `tmp/power_off_host.png`：电源键熄屏。
- `tmp/power_on_host.png`：再次点亮锁屏。
- `tmp/guest_settings_capture.jpg`：guest 系统截屏。
- `tmp/final_repro2_lock.png`、`tmp/final_repro2_settings.png`：冷启动复验。

## 启动稳定性说明

复验第一轮在启动早期被宿主 `Client heartbeat lost` 看门狗终止；不修改镜像直接第二轮冷启动即成功，之后 hdc、显示、触摸均正常。这是模拟器启动期随机不稳定，不是本轮镜像修改导致的确定性回归。若遇到同类失败，删除本实例 qcow2 后用相同镜像重试。

## 归档

最终镜像、启动脚本、触控源码/二进制、文档和截图归档于：

```
archive/harmony-p60p-enforcing-interactive/
```
