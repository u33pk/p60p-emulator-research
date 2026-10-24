# 36. 更正 35：screenType 无差异；宿主 paint/present 输入均有效

日期：2026-10-20
状态：docs/35 的核心假设被证伪。宿主 `paint` 与 `present` 的输入检查**全部通过**，
但窗口仍不显示 guest 画面。承接 docs/29~35。

---

## 1. 更正 docs/35：screenType 差异不存在

35 号说"我们 `screenType=EXTERNAL_TYPE`，600 是 `screenType: 1`（INTERNAL）"——**误读**。

我们的实际日志（重启 render_service 后立刻抓）：

```
10-20 17:29:48.583  2010  2249 W C01406/render_service/RSScreen:
    init physical: {id: 0, w * h: [1320 * 2232], screenType: 1}
10-20 17:29:54.803  2650  2650 I C04207/com.ohos.sceneboard/WMSFocus:
    OnScreenConnected(12443): name: UNKNOWN, screenId: 0, displayGroupId: 0, screenType: 1
```

**`screenType: 1`，与 600 的 `init physical: screenType: 1` 完全一致。**

`hidumper -s RenderService -a "-a screen"` 打印的 `screenType=EXTERNAL_TYPE`
是**另一个字段**（HDI display 的接口类型），跟 RS 的 `ScreenType` 不是同一个枚举。
35 号把两者当成一回事了。⇒ **screenType 线索撤销。**

---

## 2. vendor 对比：差异很小

之前查 600 vendor 时路径写成了 `/vendor/lib64/...`（映像根就是 `/vendor`，应为 `/lib64/...`），
导致误判"600 没有 `libdisplay_composer_vendor.z.so`"。实际两边都有：

| | 600 (`phone_all_arm/vendor.img`) | 601 (`p60pv2_vendor.img`) |
|---|---|---|
| `libdisplay_composer_vendor.z.so` | 85952 B，md5 `649eb437…` | 85936 B，md5 `fae0c483…` |
| `libdisplay_composer_service_*.so` | `_1.4` | `_1.3` |
| 额外 stub | `buffer_stub_1.4`、`commontype_stub_2.3`、`composer_stub_1.4` | 无 |

字符串差异只有 3 处：600 多
`VsyncCallBack cb`、`failed, mClientLayer is nullptr`，
以及 DT_NEEDED 多 `libsec_shared.z.so`。
**没有 screenType / display 类型相关的差异。**

---

## 3. `GetDisplayProperty` 失败两边都有

```
600: [GetDisplayProperty:225] <private> is not supported
     DisplayComposerStubGetDisplayProperty_ failed, error code is -2
我们: 同上
```

⇒ 不是差异点。

---

## 4. 宿主 paint / present 的输入检查全部通过

### `opengl_paint_composer_layers` @ `0x795df4`
`arg1 == NULL` 会打 `layers is null`（行 642）后返回。
qemu.log 中 **0 次** ⇒ 层数据指针有效。

### `display_present` @ `0x796434`
```
0x7964a4  ldr x0, [ctx+0x30]
0x7964a8  ldr x0, [x0, 0x20]
0x7964ac  cmp x0, 0
0x7964b0  b.eq → 打 "display gbuffer is nullptr"（行 746）后返回
0x7964b4  ldr x0, [x0, 0x28]
0x7964bc  cmp x0, 0
0x7964c0  b.ne 0x7964f4        ; 两个都非空才继续
   ...
   ; 0x7964f4 起：把 field_0x20 / field_0x28 对调（双缓冲），
   ; 然后 blr 调用 (0x8d40, ...) —— 0x8d40 像是命令码
```

qemu.log 中 `display gbuffer is nullptr` **0 次** ⇒ gbuffer 检查通过。

### gbuffer 报错全貌
qemu.log 里 `gbuffer` 相关只有**一种**模式，6 次：

```
express_display.c(gbuffer_data_guest_to_host:1014)]
    guest_upload_gbuffer_data get null gbuffer, gbuffer_id : id 0
```

每次 render_service 重启出现一次，紧接着 `display terminate`。
**这是 teardown 时刻的报错，不是稳态问题。**

---

## 5. 当前状态小结

| 环节 | 结论 |
|---|---|
| guest GPU/渲染/提交链 | 全通（docs/29、33） |
| guest screenType | `1`，与 600 一致 |
| vendor 差异 | 极小，与显示类型无关 |
| 宿主 `opengl_paint_composer_layers` | 每次 Commit 都调用，层指针有效 |
| 宿主 `display_present` | gbuffer 检查通过，做双缓冲对调后 `blr(0x8d40, …)` |
| 窗口 | 仍是宿主占位图 |

⇒ **paint 与 present 都在跑且输入都合法，但结果没到窗口。**

---

## 6. 剩下的两块没查

1. **`display_present` 里 `blr x2` 调的那个函数（参数 `0x8d40`）** ——
   这是真正往屏幕/子窗口送像素的一步。需要确认它拿到的纹理/目标是否正确。
2. **child window 上屏** —— `display_context_init` 发
   `MAIN_CREATE_CHILD_WINDOW`，`express_gpu_render.c(handle_child_window_event)`
   在处理事件，但是否把内容贴到主窗口未验证。
   线索：`slow child_event 2 time spend 36 queue_size 0`。

---

## 7. 自检

```sh
# 我们的 screenType（应为 1）
hdc shell 'hilog -r'; hdc shell 'kill $(pidof render_service)'
sleep 3; hdc shell 'hilog -x' | grep 'init physical'

# 600 对照
grep 'init physical' tmp/600_boot_early.txt

# 宿主两类错误都应为 0
L=tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log
grep -c 'layers is null' $L ; grep -c 'display gbuffer is nullptr' $L
```
