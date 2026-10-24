# 32. 判据确认：模拟器窗口不是 guest 画面

日期：2026-10-20
状态：guest 侧完全健康 + 每帧 Commit，但**宿主窗口从未显示过 guest 内容**。承接 docs/29~31。

---

## 1. 决定性判据（本轮）

### 1.1 输入送达 guest，窗口无任何反应

```
hdc shell 'uinput -K -d 115 -u 115'     # 音量+，正常应弹出音量条覆盖层
hilog: multimodalinput/InputActiveSubscriberHandler: Notify subscriber id: 0, keycode:<private>
```

`multimodalinput` 明确收到并分发了 keycode，**但窗口画面毫无变化**。

### 1.2 像素级对比：只有转圈在动

```
diff bbox: (226, 429, 263, 463)     ← 正好是转圈图标那一小块
```

两帧之间**唯一**变化区域就是转圈弧线本身，说明窗口里只有那个转圈动画在跑。

### 1.3 内容对不上

guest 渲染树里的壁纸像素是蓝色系
（`ARGB-0xFF3282C9 / ARGB-0xFF2C6DAD / ARGB-0xFFC3C4C6`），
而窗口屏幕区是黑底白字 "HarmonyOS" + 转圈。两者完全不符。

### 1.4 X 窗口树：没有第二个窗口

```
0xe00006 "Emulator"  585x830+667+184     ← 唯一的模拟器窗口
0xe00008 "Emulator"  1x1                  ← 1x1，非显示窗口
```

宿主日志里的 `send_message_to_main_window(MAIN_CREATE_CHILD_WINDOW)` 是
**模拟器内部**的 child surface（OpenGL 子表面），不是独立 X 窗口。
所以 xshot 抓的 585x830 就是正确的那个窗口。

⇒ **结论：窗口显示的是宿主占位图，guest 帧从来没有被显示出来。**
之前"paint 成功不打日志所以可能其实在画"的顾虑可以排除了。

---

## 2. 宿主 display 函数集（`sdk/emulator/Emulator` 字符串表）

围绕 `opengl_paint_composer_layers` 的函数名表：

```
free_display_context            save_display_texture_ids
display_decode_invoke           display_context_init_gbuffer
display_context_init            display_context_receive_call
display_context_destroy         opengl_paint_composer_layers
display_present                 display_status_change
triplefold_status_change        fold_device_status_change
alloc_gbuffer_with_gralloc      gbuffer_data_guest_to_host
gbuffer_data_host_to_guest      touch_device_connect_screen
touch_device_reset_screen       apply_multi_screen
```

**`display_present` 与 `opengl_paint_composer_layers` 是两个函数**，
present 应该是前者的调用方。guest 侧每帧发的是
`GetCommandId: devId=10, funId=11, displayType=0`（`CommitComposeLayer`）。

---

## 3. 已排除

- **电源键触发 display 重初始化**：`uinput -K -d 116 -u 116` 两次，`opengl_paint_composer_layers`
  计数仍为 1（即只有 16:13:06 那一次），qemu.log 无新增 paint/present。
- **`not support transform_type 8` 是画层失败**：已证伪（docs/31），纯日志。
- **vsync 不走**：已证伪（docs/31），RS 每帧都在出帧、composer 每帧都在 Commit。

---

## 4. 剩下的两条线索

### 4.1 `guest_upload_gbuffer_data get null gbuffer, gbuffer_id : id 0`

宿主 `express_display.c:1014` 报这个错，**每次 render_service 重启都会出现一次**，
然后紧跟 `display terminate`。`gbuffer_id : 0` 是非法值 —— guest 在某个时机用 id 0
去上传 gbuffer 数据，宿主查不到。

宿主侧帧数据入口是 `gbuffer_data_guest_to_host` / `gbuffer_data_host_to_guest`，
gbuffer 注册在 `alloc_gbuffer_with_gralloc` / `display_context_init_gbuffer`。
guest 侧 `ExpressAllocMem` → `InitBufferHandle` → `express init gbuffer id 19e90000001a ret 0`
是成功的，但 host 端似乎没对上。

**下一步**：确认 host 的 `display_present` 是否被调用、以及
`gbuffer_data_guest_to_host` 是否拿到过非 0 的 gbuffer_id。
若始终是 0，问题在 guest 侧 `CommitComposeLayer` 没把 gbuffer_id 传过去。

### 4.2 `hdi express composition init` 仍未出现

见 docs/31 第 3 节。`HdiExpressComposition::Init()` 只在打开 express 设备时打一次。
它没出现可能意味着 express 合成后端没初始化，提交走了别的策略。

---

## 5. 复现本判据

```sh
export DISPLAY=:0 XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.<TOKEN>
cd <WORKSPACE>

# 输入测试
python3 tmp/xshot.py && cp tmp/desktop_win.ppm /tmp/a.ppm
hdc shell 'uinput -K -d 115 -u 115'
sleep 2
python3 tmp/xshot.py && cp tmp/desktop_win.ppm /tmp/b.ppm
python3 -c "
from PIL import Image, ImageChops
print(ImageChops.difference(Image.open('/tmp/a.ppm').convert('RGB'),
                            Image.open('/tmp/b.ppm').convert('RGB')).getbbox())"

# 窗口树
xwininfo -root -children | grep -i emulator

# 宿主 paint 计数
grep -c 'opengl_paint_composer_layers' tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log
```
