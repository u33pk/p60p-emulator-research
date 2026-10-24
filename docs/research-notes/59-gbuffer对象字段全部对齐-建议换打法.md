# 59. gbuffer+0x20 = 2 两边一致 —— gbuffer 对象字段也全部对齐

日期：2026-10-21

## 实验

继续字段 dump：`gbuffer+0x20`（`display_present` 里作为参数传给 ops 的值）。

| 字段 | 我们 | 6.0.0（出屏） | 判定 |
|---|---|---|---|
| `gbuffer+0x20` | **2** | **2** | 一致，排除 |
| `gbuffer+0x30` | 0 | 0 | 排除（docs/58） |
| `gbuffer+0x38` | 0 | 0 | 排除（docs/58） |

## 现状：可测的结构面已基本穷尽

已逐项比对且**全部一致**：

- 图层结构 14 个字段
- gbuffer 对象 `+0x20` / `+0x30` / `+0x38`
- gbuffer 宽度 1320、目标矩形 1320×2232
- 三条判空分支计数（两边全 0）
- 宿主 gbuffer/paint 23 条错误分支
- GL 版本、`static_value_prepare`、bgra
- RS 绘制路径 GL/Vulkan 选择
- 占位图遮挡（已撤掉，仍是黑屏）

**宿主日志与 6.0.0 逐行一致，所有可 dump 的结构字段也一致。**

## 判断

结构层面的比对已经走到尽头。剩下的差异只可能在：

1. **像素内容本身**（需要多一跳解引用才能 dump，
   现有 3 个指令槽不够 —— 见 docs/58 的做法分析）
2. **GL 上下文 / 纹理绑定状态**（运行时状态，静态 dump 不到）
3. **guest 侧 `SetLayerBuffer` 的句柄传递**（结构对了但句柄可能没交下去）

## 建议下一轮换打法（不再逐字段比对）

**A. 直接查 guest 侧句柄传递**
`libcomposer.z.so`（手机原版）的 `HdiLayer::SetLayerBuffer()` 是它把
`BufferHandle` 交给 `libdisplay_composer_hdi_impl_1.3`（6.0.1）。
在 guest 侧给它加日志（改 `libcomposer.z.so` 的字符串/分支），
确认它是否真的被调用、handle 是否非空。

**B. 用 6.0.0 的 guest 反向验证**
把 6.0.0 的 `libcomposer.z.so` + `libdisplay_composer_hdi_impl_1.3` 一起
换进我们的镜像（保持同源），看是否出屏 —— 但 ABI 是 HDI 1.4 vs 1.3，可能不兼容。

**C. 从宿主 GL 侧入手**
`ops->fn(0x9117, 0, gbuffer)` 是绘制调用。找这个 ops 表
（`*(0x7b44580)`）的实现，看它从 gbuffer 的哪个字段取像素、
有没有可能取到空。

> 个人倾向 **A**：它直接针对"像素为什么是黑"，
> 而且 guest 侧改起来比宿主更可控。

## 状态

- `sdk/emulator/Emulator`：字段 dump 插桩（`0x796264` 现取 `gbuffer+0x20`）
  + `0x11065a8` setParent NOP（占位图隐藏）+ paint/present 已恢复
- `librender_service.z.so`：原版 + 补丁 1 + 强制 GL 两处 nop
- hdc 传输不稳（`hdc shell` / `hdc file send/recv` 频繁挂起），
  冷启动后 tconn 有时也慢 —— 下轮可能需要改用镜像内自启脚本代替 hdc
