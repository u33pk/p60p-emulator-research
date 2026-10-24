# 30. 出屏链路卡点：宿主 `opengl_paint_composer_layers` 拒绝 transform_type 8

日期：2026-10-20
状态：**卡点已精确定位**，尚未修复。承接 docs/29（DGLES 多副本导致 GL 上下文 TLS 分裂）。

---

## 1. 现状（29 号修复之后）

GPU 上下文已经通了，guest 侧渲染链完整：

- `hidumper -s RenderService -a "-a gles"` → `GL_RENDERER: Mali-G77`，`GL_VERSION: OpenGL ES 3.0 (4.6.0 NVIDIA 595.71.05)`
- `d_eglSwapBuffers_special ... thread output size 63694, API_num 55` → RS **确实在出帧**，GL 命令经 teleport_express 发往宿主 GPU
- 渲染树含真实像素（`SCBWallpaper4` / `SCBDesktop5` / 壁纸 pixelmap `ARGB-0xFF3282C9 ...`）
- 缓冲队列健康：`usedBufferListLen=4, freeBufferListLen=2`，`bufferQueueCache state = 3/1/0/0`

但模拟器窗口**仍显示宿主占位图**（黑底白字 HarmonyOS + 转圈）。
判据：窗口画面与 guest 壁纸像素（蓝色系）完全不符，且 RSTree 里是桌面不是开机动画。

---

## 2. 宿主侧日志（`tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log`）

关键一行，**整段日志里只出现过一次**：

```
2026-10-20 16:13:06.417 E [express_display.c(opengl_paint_composer_layers:708)] not support transform_type 8
```

时间点正好是 GL 修复后桌面首次起来的时刻。此后 8 分钟 qemu.log 里**再无任何 paint/present**，
直到 16:21:40 重启 render_service 才出现：

```
[teleport_express_call.c(fill_teleport_express_queue_elem:446)] find null prt!!!
[express_display.c(gbuffer_data_guest_to_host:1014)] guest_upload_gbuffer_data get null gbuffer, gbuffer_id : id 0
[express_display.c(display_decode_invoke:155)] display terminate
```

⇒ **composer 只提交了一次，宿主画层时因 transform_type 8 直接放弃，之后管线就静默了。**

宿主 `express_display.c` 各消息出现次数（qemu.log 全量统计）：

| 次数 | 消息 |
|---|---|
| 199 | `Get Display id : 0, power state :0`（从未变成非 0） |
| 113 | `screen num: N` / `device type: N` / `FUNID_Get_Display_Mods return display[...]` |
| 97 | `No need to apply multi-screen.` |
| 73 | `send_message_to_main_window(MAIN_CREATE_CHILD_WINDOW)` |
| 51 | `display terminate` |
| 3 | `guest_upload_gbuffer_data get null gbuffer, gbuffer_id : id 0` |
| **1** | **`not support transform_type 8`** |

---

## 3. transform_type 8 是什么

`native_sysroot/usr/include/native_buffer/buffer_common.h` 的
`OH_NativeBuffer_TransformType`：

```
0  NATIVEBUFFER_ROTATE_NONE
1  NATIVEBUFFER_ROTATE_90
2  NATIVEBUFFER_ROTATE_180
3  NATIVEBUFFER_ROTATE_270
4  NATIVEBUFFER_FLIP_H
5  NATIVEBUFFER_FLIP_V
6  NATIVEBUFFER_FLIP_H_ROT90
7  NATIVEBUFFER_FLIP_V_ROT90
8  NATIVEBUFFER_FLIP_H_ROT180     ← 宿主拒绝的就是这个
9  NATIVEBUFFER_FLIP_V_ROT180
10 NATIVEBUFFER_FLIP_H_ROT270
11 NATIVEBUFFER_FLIP_V_ROT270
```

8 在 NDK 枚举里是**合法值**，只是宿主的 `opengl_paint_composer_layers` 没实现它。

guest 侧 RS 的 LayerInfo 里 ScreenNode 是 `transformType = 12 <uninitialized>`
（12 超出枚举范围），host 侧收到的是 8 —— 两边的枚举空间/映射不一致，值得追。

---

## 4. 下一步（两条路，任选其一）

**A. 修宿主**：`sdk/emulator/Emulator`（130MB，AArch64 PIE，无符号表）
里 `express_display.c` 的 `opengl_paint_composer_layers` 在不支持 transform_type 时
直接放弃。改法是把未知值按 `ROTATE_NONE` 处理（或补上 8 的分支）。

已定位字符串：

```
"not support transform_type %d"  @ file/vaddr 0x223a8a8
"opengl_paint_composer_layers"   @ 0x223b0c0   （函数名表）
```

**未完成**：还没找到引用该字符串的代码位置。
试过 `adrp+add`（同寄存器）、`adr`、以及全文件搜 8/4 字节绝对指针，均无命中；
需要放宽到「adrp 目标页 0x223a000 的 219 处 + 任意寄存器 add #0x8a8」的组合匹配，
或改从 `readelf -r` 的 `R_AARCH64_RELATIVE` addend 反查。
注意 `Emulator` 有备份 `tmp/Emulator.orig.20261017` 与
`tmp/Emulator.sigpatched.20261017`，改前确认当前跑的是哪个。

**B. 修 guest**：让 composer 提交的 layer transform 是宿主支持的值（0）。
查 `composer_host` → `SetLayerTransform` / RS `RSUniRenderComposerAdapter`
里 transformType 从 12 到 8 的映射，改成 0。

---

## 5. 顺带确认的事

- `express` 传输层本身是好的：kernel.log 里 `express_hotplug open/read` 每秒一次，
  `express_cache_free: free cache pages 22799 of 179636`（约 700MB 共享缓存在用）。
- `power state :0` 一直如此，**不是**显示电源问题（199 次全为 0，包含正常期）。
- `vsyncId` 会缓慢爬（211→215），并非完全冻结；RS 也确实出帧了（见第 1 节）。
  所以**真正的卡点是宿主画层失败**，不是 vsync。docs/29 末尾把 vsync 当唯一缺口的判断需要修正。
- 另有 `glv3_trans.c: invoke call id 100000000 not exist!, fun id: 0` 与
  `Host: Interop extension not available: VK_KHR_external_memory_win32`，
  前者是 guest/host GL3 协议有一条调用对不上，暂未影响出帧，先记着。

---

## 6. 自检命令

```sh
# guest
hdc shell 'hidumper -s RenderService -a "-a gles"    # GPU context
hdc shell 'hidumper -s RenderService -a "-a surface" # 层与缓冲队列
hdc shell 'hidumper -s RenderService -a "-a RSTree"  # 渲染树内容

# host
grep 'opengl_paint_composer_layers\|transform_type\|display terminate' \
    tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log | tail

# 窗口截图（需 DISPLAY + XAUTHORITY）
export DISPLAY=:0 XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.<TOKEN>
python3 tmp/xshot.py      # 在 <WORKSPACE> 下运行
```
