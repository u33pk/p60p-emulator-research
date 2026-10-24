# 33. guest 显示管线完整跑通，问题确定在宿主侧

日期：2026-10-20
状态：guest 侧 `init → PushFirstFrame → ShowWindow → CommitComposeLayer` 全链路正确执行，
宿主收到命令但窗口仍是占位图。承接 docs/29~32。

---

## 1. 线格式（逆向 `libdisplay_composer_vendor.z.so`）

### `ExpressConnection::CommitComposeLayer(int, int, GBuffer_Layers*, unsigned int)` @ `0x9374`

参数校验（`0x93e4`）：

```
*(int*)GBuffer_Layers == arg1            // 层计数一致
arg2 == arg1 * 60 + 4                    // 总长 = 4 字节头 + N × 60 字节层记录
```

不满足则打 `ExpressConnection::CommitComposeLayer err! layer_num ... layers_size ...`（行 71）。
**当前日志里从未出现该错误**，说明传参一直是对的。

发送（`0x94bc`）：

```
ldp w8, w0, [x20]              ; fd 相关
mov x9, 0xb ; funId = 11
bfi x22, x21, 0x20, 0x20       ; x22 = funId | (displayType << 32)
movk x9, 0xa, lsl 32           ; x9 = (devId=10 << 32) | funId=11
mov w2, 0x20                   ; 只写 32 字节
stp x24, x19, [sp, 0x28]       ; [size, GBuffer_Layers*]
csel x8, x9, x22, eq
stp x8, x9, [sp, 0x18]         ; 16 字节命令头
bl write                       ; write(fd, buf, 32)
```

⇒ **`CommitComposeLayer` 只写 32 字节命令头**，真正的层数据（`GBuffer_Layers*` 指针 +
size）放在共享内存里给宿主去读。层记录 60 字节/层。

### `ExpressConnection::ShowWindow(unsigned int)` @ `0x94f4`

紧接在 Commit 后面，`mov w22, 0xa` —— **funId=10**。这是"显示窗口"的调用。

---

## 2. 实测：guest 全链路都跑了

重启 `composer_host` 后抓到完整启动序列：

```
DISP_CACHE_MGR: create SharedMemQueue, count=32768, size=131100   ← 共享内存队列建好
DISP_CACHE_MGR: smq init succ
DisplayComposerVdiImpl constructor
Init:87  hdi session init
DiscoveryDisplay:49  discovery screenNum is 1
Init:48  hdi display init
CreateHdiLayer:213
Init:55  the hdi display id is 0
GetDisplayMods:110
Init:42  emulator create display 0 1320 2232 0 10
GetDisplayStatus:159  GetDisplayStatus devId 10
Init:74  emulator create display index 0 screen id 0 device_id 10 pixel w 1320 h 2232
Init:38  hdi express composition init          ← docs/31 担心的这句，其实一直有
PushFirstFrame:224  invoke PushFirstFrame
ShowWindow:99  ShowWindow devId 10             ← funId=10
HdiNetLinkMonitor:28
```

funId 分布（本次抓取）：

| funId | 次数 | 含义 |
|---|---|---|
| 10 | 1 | `ShowWindow` |
| 11 | 1 | `CommitComposeLayer` |
| 13 | 64 | 触摸后反复调用（`SetDisplayStatus` 同步出现 63 次） |
| 16777228/230/232/233 | 1~2 | 高位带 displayType 的命令 |

**docs/31 第 3 节"`hdi express composition init` 从未出现"的担忧可以撤销** ——
它在 composer_host 启动序列里就有，只是之前抓日志的时机不对。

---

## 3. 触摸只触发 SetDisplayStatus，不触发提交

```
hdc shell 'uinput -T -c 292 415'
→ composer_host: SetDisplayStatus devId 10   ×63
→ GetCommandId: devId=10, funId=13            ×64
→ 无 CommitComposeLayer
```

也就是说触摸后 composer 只在同步显示状态，没有提交新帧。
（RS 侧桌面静止时本来就不重绘，sequence 号不变。）

---

## 4. 结论：guest 侧无问题，缺口在宿主

guest 侧证据链完整且正确：

| 环节 | 状态 |
|---|---|
| GPU context | `Mali-G77` / `OpenGL ES 3.0 (4.6.0 NVIDIA 595.71.05)` |
| 缓冲队列 | `state = 1/0/0/3` 正常，2 空闲 |
| express 共享内存 | `SharedMemQueue count=32768 size=131100` 建立成功 |
| express 分配 | `ExpressAllocMem` / `InitBufferHandle` / `ExpressMmap` / `DmaBufferSync` 全通 |
| 合成后端 | `hdi express composition init` ✓ |
| 首帧 | `PushFirstFrame` ✓ |
| 显示窗口 | `ShowWindow devId 10` (funId=10) ✓ |
| 层提交 | `CommitComposeLayer! 10` (funId=11)，参数校验通过 ✓ |

而宿主 `qemu.log` 在同一批调用之后**没有任何 paint/present 日志**，
窗口依旧是占位图（docs/32 的判据：输入送达 guest 但窗口无反应、只有转圈在动、
内容与 guest 壁纸像素不符）。

---

## 5. 下一步（宿主侧）

宿主 `sdk/emulator/Emulator` 的 `express_display.c` 函数集（见 docs/32 第 2 节）：

- `display_decode_invoke` —— 入口分发
- `display_present` —— 应当是提交/上屏入口
- `opengl_paint_composer_layers` —— 实际画层（16:13:06 只跑过一次）
- `gbuffer_data_guest_to_host` / `gbuffer_data_host_to_guest` —— 帧数据搬运
- `alloc_gbuffer_with_gralloc` / `display_context_init_gbuffer` —— gbuffer 注册

要查的两件事：

1. **funId=10 / funId=11 到宿主后走到了哪个分支**。
   `display_decode_invoke` 的 funId→函数映射需要反汇编。
   线索：宿主里 `FUNID_Get_Display_Mods` 对应的是查询类调用并有日志，
   而 ShowWindow/Commit 没有日志，说明它们走的是静默分支。
2. **`guest_upload_gbuffer_data get null gbuffer, gbuffer_id : id 0`**
   （`express_display.c:1014`）仍是唯一的报错线索，每次 render_service 重启出现一次。
   `gbuffer_id : 0` 说明宿主按 id 查表查不到 —— 结合上面的线格式，
   怀疑宿主读 `GBuffer_Layers` 共享内存时拿到的 gbuffer_id 是 0
   （guest 侧 `InitBufferHandle` 明明注册了 `gbuffer id 19e90000001a`）。

---

## 6. 自检

```sh
# 重启 composer_host 触发完整 init 序列
hdc shell 'hilog -r'
hdc shell 'kill $(pidof composer_host)'
sleep 2; hdc shell 'uinput -T -c 292 415'   # 强制重绘
sleep 5
hdc shell 'hilog -x' | grep 'composer_host/DISP' | grep -v GetCommandId
hdc shell 'hilog -x' | grep -oE 'funId=[0-9]+' | sort | uniq -c

# 宿主
grep -c 'opengl_paint_composer_layers' tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log
```
