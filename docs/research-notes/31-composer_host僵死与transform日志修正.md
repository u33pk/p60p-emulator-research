# 31. composer_host 需重启才会提交；transform_type 只是日志（修正 30 号）

日期：2026-10-20
状态：guest 侧渲染/合成链**全部健康**，宿主仍未上屏。承接 docs/29、docs/30。

---

## 1. 修正 docs/30 的错误结论

30 号把 `not support transform_type 8` 当成"宿主放弃绘制"，**这是错的**。

宿主 `sdk/emulator/Emulator` 里 `express_display.c` 的对应代码在 vaddr `0x796210`：

```
0x796210  cmp w0, 5                    ; transform_type == 5 ?
0x796214  b.eq 0x796274                ; → OK
0x796220  cmp w0, 0                    ; == 0 ?
0x796224  b.eq 0x796274                ; → OK
0x796234  cmp w0, 2                    ; 日志级别检查
0x796238  b.gt 0x796274                ; 级别高就连日志都不打，直接 OK
0x79623c..0x796270  打日志
        mov w3, 0x2c4                  ; 0x2c4 = 708 ← 正是日志里的行号，确认无误
0x796270  bl  HiLogPrint
0x796274  ← 所有分支（含打完日志）都汇聚到这里
0x79627c  ldr x2, [tbl]                ; 取绘制函数
0x796298  blr x2                       ; 无论如何都会调用
```

**`not support transform_type` 是纯日志，不是放弃绘制。** 所有路径都走到 `0x796274` 调用绘制函数。
30 号说的"宿主画层失败导致静默"不成立；事实是**整个 `opengl_paint_composer_layers` 只被调用过一次**。

（定位方式：字符串 `not support transform_type %d` @ `0x223a8a8`，
引用于 `add x3, x0, #0x8a8` @ `0x796248`，前面 `adrp x0, 0x223a000` @ `0x796244`。
注意 adrp 与 add **寄存器可以不同**，上一轮扫漏就是这个原因。）

---

## 2. 真正的操作性发现：composer_host 会"僵住"，kill 一次就活了

重启 `composer_host` 前，它 **0% CPU、`FrameBufferSurface` 空、日志里没有任何 Commit**。
`kill $(pidof composer_host)`（init 会拉起）之后立刻开始持续提交：

```
composer_host/DISP: GetDisplayCompChange:149  set the layers and type
composer_host/DISP: Commit:227
composer_host/DISP: CommitComposeLayer! 10
composer_host/DISP: GetCommandId:45  teleport_express cal command id, devId=10, funId=11, displayType=0
composer_host/DISP: Commit:230  the release fence is -1
composer_host/DISP: GetDisplayReleaseFence:178  layer id 0 fencefd -1
composer_host/DISP: EnableVsync:70
```

现在**每帧**都在 `CommitComposeLayer! 10`（devId=10, funId=11 发往宿主）。

⇒ **启动顺序/竞态**：composer_host 必须在 render_service 之后再重启一次才会进入提交循环。
启动脚本里应该 `kill $(pidof composer_host)` 一次。

---

## 3. `hdi express composition init` 从未出现

600 可用镜像（`tmp/600_boot_early.txt`）里有：

```
10-19 01:22:19.725  570  598 I C02515/DISP: [Init:38] hdi express composition init
```

我们这侧 **0 次**。

该日志来自 `/vendor/lib64/libdisplay_composer_vendor.z.so` 的
`OHOS::HDI::DISPLAY::HdiExpressComposition::Init()` @ vaddr `0xb268`：

```
HiLogPrint("... hdi express composition init")
fd = __open_chk(*(global 0x15930), O_RDWR)   ; 打开 express 设备
*(this+0x20) = fd
return 0
```

没有内部分支，且**本 .so 内没有 `bl` 到它** —— 是通过虚表
`_ZTVN4OHOS3HDI7DISPLAY21HdiExpressCompositionE` 被 `HdiComposer` 调的。
`HdiComposer(unique_ptr<HdiComposition>, unique_ptr<HdiComposition>)` 也定义在同一 .so。

**未确认**：composer_host 重启后提交循环已经跑起来，但这条 init 日志仍未出现。
可能它只在进程首次初始化时打一次、被 hilog 缓冲冲掉了；也可能 express 合成后端确实没初始化
而提交走的是别的策略。下一步应重启 composer_host 后**立刻**抓 hilog 看有没有这句。

另外 `libdisplay_composer_vendor.z.so` 里还有
`can not init HdiGfxComposition`、`CompositionType type %{public}d`
两条线索日志，当前日志里也都没出现。

---

## 4. 当前 guest 侧状态（全部健康）

| 项 | 值 |
|---|---|
| GPU context | `GL_RENDERER: Mali-G77`, `GL_VERSION: OpenGL ES 3.0 (4.6.0 NVIDIA 595.71.05)` |
| 屏幕 | `powerStatus=POWER_STATUS_ON, 1320x2232, name=express_display` |
| ScreenNode 缓冲 | `usedBufferListLen=4, freeBufferListLen=2`，`state = 1/0/0/3` 正常轮转 |
| express 分配 | `ExpressAllocMem` / `InitBufferHandle` / `ExpressMmap` / `DmaBufferSync` 全通 |
| composer_host | 每帧 `CommitComposeLayer! 10` |
| 渲染树 | SCBWallpaper4 / SCBDesktop5 + 壁纸真实像素 |

---

## 5. 剩余缺口

宿主 `qemu.log` 里 `opengl_paint_composer_layers` **至今只出现过一次**（16:13:06），
即使 guest 现在每帧 Commit，宿主也没有任何 paint/present 日志。

注意：**paint 成功时本来就不打日志**（只有 transform 不认识才打），
所以不能仅凭"没有日志"断定没画。需要换判据：

1. 换个能证实"窗口=guest 画面"的实验（例如 `uinput` 点一下让 guest 有可见反应，
   或改亮度/壁纸再截图对比）。
2. 若确实没画，追 `CommitComposeLayer` → `funId=11` → 宿主
   `display_decode_invoke` 的分发，看这条命令到了宿主之后走没走到
   `opengl_paint_composer_layers`。

---

## 6. 自检命令

```sh
# guest
hdc shell 'pidof composer_host'                       # 若没有提交日志，先 kill 它
hdc shell 'hilog -x' | grep 'composer_host/DISP'      # 应看到 CommitComposeLayer! 10
hdc shell 'hidumper -s RenderService -a "-a surface"' # 缓冲状态
hdc shell 'hidumper -s RenderService -a "-a gles"'    # GPU context

# host
tail -20 tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log
grep -c 'opengl_paint_composer_layers' tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log
```
