# 35. 新差异：屏幕类型 INTERNAL vs EXTERNAL

日期：2026-10-20
状态：宿主 paint 每次提交都会跑（docs/34），但窗口仍不显示 guest 画面。
本轮找到一个新的结构性差异：**guest 认为自己的屏是"外接 HDMI 屏"**。承接 docs/29~34。

---

## 1. 关键差异

**600 可用镜像**（`tmp/600_boot_early.txt`）：

```
10-19 01:22:19.737  712  870 W C01406/RSScreen:
    init physical: {id: 0, w * h: [1320 * 2232], screenType: 1}
```

**我们的混合镜像**（`hidumper -s RenderService -a "-a screen"`）：

```
screen[0]: id=0, powerStatus=POWER_STATUS_ON, backlight=2279,
           screenType=EXTERNAL_TYPE,
           render resolution=1320x2232, physical resolution=1320x2232,
           isVirtual=false, ...
name=express_display, phyWidth=72, phyHeight=156,
supportLayers=10, virtualDispCount=1, propertyCount=0,
type=DISP_INTF_HDMI, supportWriteBack=false
```

⇒ 600 是 **1（INTERNAL，内屏）**，我们是 **EXTERNAL_TYPE + DISP_INTF_HDMI（外接 HDMI 屏）**。

分辨率、刷新率（1320x2232 @60）完全一致，唯独屏的"类型/接口"不同。

**这是很可能致命的**：桌面/launcher 与合成器对"内屏"和"外接屏"走的路径不同
（外接屏通常不做 wallpaper/桌面合成，或由另一条 present 链处理）。

### 从哪来

`screenType`/`type` 是 guest 从 display HDI 拿的：
`GetDisplayMods` 返回 `device_id = 10`，宿主 `express_display.c` 报 `device type: 0`。
我们用的 vendor 是 `tmp/rooted_image/p60pv2_vendor.img`（**601 模拟器 vendor**），
600 用的是 `phone_all_arm/vendor.img`。两者 vendor 结构不同
（600 的 `/vendor/lib64` 里**没有** `libdisplay_composer_vendor.z.so`，
说明它走的是另一套实现）。

⇒ **下一步优先验证**：把 vendor 换成 600 那套（或查 600 vendor 里 display 相关库在哪），
看 `screenType` 是否变回 1、桌面是否出屏。

---

## 2. 顺带澄清/修正

### 2.1 "diff 只有转圈"的推论有漏洞

docs/32 用"两帧之间只有转圈区域变化"来证明窗口是宿主占位图，**这个论证不严谨**：
RS 在桌面静止时本来就不重绘（缓冲 sequence 号不变），所以画面本来就该是静止的。

真正有效的判据是：

- **内容对不上**：guest 渲染树里的壁纸像素是蓝色系
  （`ARGB-0xFF3282C9 / ARGB-0xFF2C6DAD / ARGB-0xFFC3C4C6`），
  窗口屏幕区是黑底白字 HarmonyOS + 转圈。
- **输入送达 guest 但窗口无反应**（`multimodalinput` 收到 keycode，音量覆盖层没出现）。
- **RS 重启时窗口毫无变化**（RS 重绘会导致屏幕闪一下）。

综合仍指向"窗口不是 guest 画面"，但依据是上面三条，不是像素 diff。

### 2.2 `opengl_paint_composer_layers` 的早退分支

@ `0x795df4`：

```
0x795e58  ldr x0, [x29, 0x20]   ; arg1（GBuffer_Layers*）
0x795e5c  cmp x0, 0
0x795e60  b.ne 0x795ea8         ; 非空 → 继续
   ; 空则打 "layers is null"（行 0x282 = 642）然后返回
0x795ea4  b 0x796414
```

宿主日志里**从未出现 `layers is null`**，所以 paint 拿到的层数据指针是有效的。

### 2.3 宿主没有独立的皮肤/占位图资源

`sdk/emulator/`（只有 `properties/`、`plugins/`、`pc-bios/`）、
`tmp/deployed_p60pv2/`、`~/.Huawei`、`~/Library` 下都**没有** png/jpg 资源
—— 手机外框和占位图是嵌在 `Emulator` 二进制里的（Qt resource）。

---

## 3. uinput 坐标系

`uinput -T -c 292 415` 会报 "coordinates exceed the screen boundary"，
说明 **`-T` 用的是 guest 屏幕坐标系（1320x2232）**，不是窗口坐标（585x830）。
正确用法：

```sh
uinput -T -c 660 1116                     # 点屏幕中心
uinput -T -g 660 150 660 1800 600 1400    # 从顶部下拉（press>=500, total-press>=500）
```

（本轮试了下拉，仍只看到转圈变化；结合 2.1，这个判据本身就不足以定论。）

---

## 4. 建议的下一步（按性价比排序）

1. **换 vendor 验证 screenType**
   - 先看 `phone_all_arm/vendor.img` 里 display 相关库的实际位置
     （`/vendor/lib64` 下没有，可能在 `/vendor/lib64/chipset-sdk` 之类）。
   - 若能把 guest 的 `screenType` 变成 1（INTERNAL），桌面出屏概率很高。
2. **dump 共享内存的层记录**（docs/33 的 60 字节/层格式），
   确认层里的 gbuffer_id 是否真为 0 —— 这是 `guest_upload_gbuffer_data get null gbuffer` 的直接解释。
3. **child window 上屏**：`display_context_init` 发的 `MAIN_CREATE_CHILD_WINDOW`
   只是模拟器内部 GL 子表面，需确认它有没有被贴到主窗口。

---

## 5. 自检

```sh
hdc shell 'hidumper -s RenderService -a "-a screen"' | head -5   # 看 screenType
grep 'init physical' tmp/600_boot_early.txt                      # 600 的对照
hdc shell 'hidumper -s RenderService -a "-a gles"'               # GPU context 仍应正常
```
