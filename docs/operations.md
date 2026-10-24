# 触控、截图与日常操作

## HDC

```sh
scripts/smoke_check.sh
# 或手动使用 SDK 中的 hdc 连接 config.sh 指定的 127.0.0.1:端口
```

正常研究实例的 HDC 地址为 `127.0.0.1:5555`，可通过 `P60P_HDC_PORT` 修改。

## 编译真实输入工具

部分环境没有 `/dev/uinput`，系统 `uinput` CLI 也可能受 displayId/access-token 限制。`tools/input_event_inject.c` 直接写 virtio touchscreen 的标准 Linux input event。

```sh
CC=aarch64-linux-musl-gcc scripts/build_input_event_inject.sh
hdc file send work/input_event_inject /data/local/tmp/input_event_inject
hdc shell 'chmod 755 /data/local/tmp/input_event_inject'
```

先查询实际设备：

```sh
hdc shell '/data/local/tmp/input_event_inject /dev/input/event2 query'
```

本次环境中 event2 是触摸屏，event8 是电源键；其他实例应重新确认。

1220×2700 下常用操作：

```sh
# 上滑解锁
hdc shell '/data/local/tmp/input_event_inject /dev/input/event2 swipe 610 2200 610 900'
# 下拉控制中心
hdc shell '/data/local/tmp/input_event_inject /dev/input/event2 swipe 920 0 920 1200'
# 页面滚动
hdc shell '/data/local/tmp/input_event_inject /dev/input/event2 swipe 650 2000 650 900'
# 电源键
hdc shell '/data/local/tmp/input_event_inject /dev/input/event8 power'
```

点击可用起点和终点相同的 swipe。坐标是 guest 屏幕空间，不是 host 窗口坐标。

## 截图

```sh
scripts/capture_screenshot.sh
```

截图进入 `work/screenshots/`。`-screenshotPath` 应传目录，不是目标 PNG 文件名。

验收时同时检查 host 与 guest。root 的 `snapshot_display` 在当前环境可能报 displayId/access-token 错误，可以使用系统控制中心的截屏功能，再从 Photo 目录取回 guest 原图。不要只凭一张 host 图就宣称系统可交互；还应上滑、打开设置或按电源键验证。

`tools/x11_capture.py` 是底层 X11 备用工具，依赖 Pillow，需要自行提供窗口 ID 和尺寸；日常使用优先选择上面的 Emulator 截图命令。
