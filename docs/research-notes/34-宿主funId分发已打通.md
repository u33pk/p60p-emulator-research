# 34. 宿主 funId 分发已打通：Commit 确实会调 paint

日期：2026-10-20
状态：宿主 `display_decode_invoke` 的 funId→处理器映射已反出，
**Commit 每次都会调用 paint 函数** —— 缺口进一步收窄到"paint 结果→窗口"这一段。承接 docs/29~33。

---

## 1. funId 解码与分发（`sdk/emulator/Emulator`）

`display_decode_invoke` @ `0x794048`：

```
0x794130  ldr  x0, [x0]            ; 命令字（8 字节）
0x794134  and  w0, w0, 0xffffff    ; funId = 低 24 位
0x794138  cmp  w0, 0xa             ; == 10 ?
0x79413c  b.eq 0x794638            ; → ShowWindow
0x794144  b.hi 0x794188            ; > 10 往下
```

二分 switch 完整映射：

| funId | 处理器 | 行为 |
|---|---|---|
| 1 | `0x794218` | |
| 3 | `0x794658` | 读 0x24 字节头，调 `0x798208` |
| 4 | `0x7946dc` | |
| 6 | `0x7947f0` | |
| 7 | `0x794850` | |
| **10** | **`0x794638`** | **`context->field_0x60 = 1`**（"已显示"标志） |
| **11** | **`0x794404`** | **CommitComposeLayer**（见下） |
| 12 | `0x7948b4` | |
| 13 | `0x794a30` | 触摸时反复调用 |
| 14 | `0x794a8c` | |
| 15 | `0x794648` | `context->field_0x60 = 2` |
| 16 | `0x794bd4` | |
| 17 | `0x794cd4` | |
| 18 | — | |

（guest 侧 `*(x20)==1` 时命令字是 `(devId=10<<32)|funId`，
`and w0,w0,0xffffff` 取出的正是 funId，与日志 `devId=10, funId=11` 一致。）

---

## 2. `ShowWindow`（funId=10）@ `0x794638`

```
ldr x0, [x29, 0x70]     ; display context
mov w1, 1
str w1, [x0, 0x60]      ; context->state = 1
b   0x794e84            ; 返回
```

**极其简单，只置一个"已显示"标志。** funId=15 则置 2。
所以 ShowWindow 本身不会画任何东西，只是把 display context 标记为可见。

---

## 3. `CommitComposeLayer`（funId=11）@ `0x794404`

```
w0 = 读回包结果            ; <=0 → 0x794dd0 错误
x0 = [x29,0x110]          ; size
if size <= 3      → 0x794dd8 错误
expect = 12*60 + 4 = 724  ; 0x794444..0x794458 算出来
if size > 724     → 打日志（行 0xce = 206）后仍继续
buf = g_malloc0(size)
... 读入 ...
0x7945ec  bl 0x795df4     ; ← 调 paint（opengl_paint_composer_layers 所在区）
0x7945fc  bl 0x796434     ; ← 调 display_present 所在区
0x794630  bl 0x7a2f30
```

**关键结论：Commit 处理器每次都会调用 paint 函数。**

⇒ docs/32 里"宿主 paint 只跑过一次"的判断要修正：
**paint 每次提交都会跑**，只是成功时没有日志，唯一那条
`not support transform_type 8` 是 paint 内部的一条告警。

---

## 4. 重新定位缺口

既然 paint 每次都跑，而窗口依旧只有宿主占位图（docs/32 判据：输入送达 guest 无反应、
只有转圈在动、内容与 guest 壁纸像素不符、RS 空闲不重绘则转圈仍在动 → 转圈是宿主画的），
那么缺口在 **paint 之后 → 窗口** 这一段：

候选（宿主 `express_display.c` 函数集，见 docs/32 第 2 节）：

1. **child window 未真正上屏**
   `display_context_init` 会 `send_message_to_main_window(MAIN_CREATE_CHILD_WINDOW)`，
   `express_gpu_render.c(handle_child_window_event:504) slow child_event 2` 说明
   child window 事件在处理，但可能只是创建了内部 GL 子表面、没把内容贴到主窗口。
2. **`gbuffer_data_guest_to_host` 的 `gbuffer_id : id 0`**
   `express_display.c:1014`，每次 render_service 重启报一次。
   若宿主拿不到像素，paint 画的是空内容。
3. **`context->field_0x60` 状态机**
   ShowWindow 置 1、funId=15 置 2。paint/present 是否检查该标志、以及谁会把它清掉。

---

## 5. 下一步建议顺序

1. 先确认 **paint 到底画没画出东西**：在 `0x795df4`（paint 入口）附近找一条成功路径，
   看它用的纹理/gbuffer 来自哪；或者直接看 `opengl_paint_composer_layers`
   另外三个日志点（`0x795e84`、`0x7962cc`、`0x79634c`）分别是什么条件，
   能当探针用。
2. 再查 `gbuffer_id = 0`：guest 侧 `InitBufferHandle` 注册的是
   `gbuffer id 19e90000001a`，宿主查表却得到 0，怀疑是**表的 key 传错**。
   结合 docs/33 的线格式（`GBuffer_Layers*` 在共享内存、层记录 60 字节），
   可以直接 dump 共享内存确认层记录里的 gbuffer_id 字段。
3. 最后查 child window 上屏。

---

## 6. 自检

```sh
# guest：重启 composer_host 触发完整序列，再点一下强制提交
hdc shell 'hilog -r'; hdc shell 'kill $(pidof composer_host)'
sleep 2; hdc shell 'uinput -T -c 292 415'; sleep 4
hdc shell 'hilog -x' | grep -oE 'funId=[0-9]+' | sort | uniq -c

# host：paint 计数（成功不打日志，所以只反映告警次数）
grep -c 'opengl_paint_composer_layers' tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log
```
