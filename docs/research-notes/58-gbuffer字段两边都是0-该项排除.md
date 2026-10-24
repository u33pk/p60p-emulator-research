# 58. gbuffer+0x30/+0x38 两边都是 0 —— 该项排除

日期：2026-10-21

## 实验

用 docs/51 的字段 dump 手法（改 `0x796264` 的 `ldr` 偏移），
把 `not support transform_type` 那条日志的取数源改成 gbuffer 对象的字段：

| 字段 | 我们 | 6.0.0（出屏 208KB） | 判定 |
|---|---|---|---|
| `gbuffer+0x30` | 0 | 0 | 排除 |
| `gbuffer+0x38` | **0** | **0** | **排除** |

paint 里这两个字段会被交换（`gbuffer->0x38 = gbuffer->0x30`），
原以为是像素双缓冲指针，实测**两边都是 0** —— 它们不是像素指针，
或者在这条路径上本就该是 0。

6.0.0 在同样的 0 值下正常出屏（208KB），所以这两项不是差异。

## 累计已排除（很长了）

- 图层结构 14 个字段逐个比对 —— 全同
- 目标矩形 1320×2232 —— 正确
- gbuffer 宽度 1320 —— 正确
- `gbuffer_from_global_map` / `display_write_gbuffer` / `display gbuffer is nullptr` —— 两边全 0
- `gbuffer+0x30` / `gbuffer+0x38` —— 两边全 0
- GL 版本 / `static_value_prepare` / bgra —— 噪音
- buffer HDI 不对称 —— 已修
- Vulkan 互操作 —— 已移除
- RS 绘制路径 GL/Vulkan 选择 —— 排除
- 开机占位图遮挡 —— 排除（撤掉后是黑屏）

## 现状

- **占位图已能撤掉**（NOP `QWidget::setParent` @ `0x11065a8`），露出**干净黑画布**
- guest 侧：渲染正常、提交 183 次、图层正确
- host 侧：paint + present 都执行，但输出是黑

⇒ 问题收敛到：**paint 画出来的是黑**（输入像素为空/错误），
或 **present 送到了错误的目标**。

## 下一步（建议优先做第 1 条）

1. **dump 像素内容本身**：目前所有字段 dump 都只能取"指针值"，
   要看像素需要多一次解引用。做法：
   在 `0x79623c-0x796264` 的 3 个指令槽里做 `layer → gbuffer → 指针 → 首 dword`，
   现在是 3 跳到 `gbuffer+0x30` 的**值**；要取 `*(gbuffer+0x30)` 还差一跳。
   可以把 `0x796240` 的 `ldr x4,[x0,#0x20]` 改成先把像素指针放进 x4，
   再让 `0x796264` 解引用 —— 但 x4 在中间会被 log 参数设置覆盖，
   需要换到 x5/x6/x7 之一（log 调用前的 `mov x5,w4` 那个位置可用）。
2. **对比 6.0.0 的 gbuffer 其它字段**（`+0x20` / `+0x28` / `+0x08` 等），
   找出哪个字段承载像素来源。
3. **直接查 guest 侧 `HdiLayer::SetLayerBuffer`** 有没有真的把句柄交下去
   （`libcomposer.z.so` 手机原版 + 601 的 `hdi_impl`，docs/46 已确认 ABI 兼容，
   但句柄传递可能仍断）。

## 状态

- `sdk/emulator/Emulator`：docs/51 字段 dump 插桩（`0x796264` 现取 `gbuffer+0x38`）
  + `0x11065a8` setParent NOP（占位图已隐藏）+ paint/present 已恢复
- `librender_service.z.so`：原版 + 补丁 1 + 强制 GL 两处 nop
- 镜像里仍有 `QemuParams` + `qemuparams.cfg`（docs/56，未生效）
- 原版 Emulator 备份 `tmp/Emulator.before_instr`
