# 61. SetLayerBuffer handle 假设证伪 —— 句柄非空

日期：2026-10-21

## 实验

把 `libcomposer.z.so` 里 `HdiDeviceImpl::SetLayerBuffer` 的**静默失败路径**
（`handle == null && fence == -1` 时返回 -3）改成 `b .` 自旋。
如果 handle 为空，render_service 会卡死、提交会骤降。

产物 `tmp/prov/libcomposer_spin.so`（md5 `2030c0f274`），
补丁点 vaddr `0x1b3e4` = 文件偏移 `0x1a3e4`：
`mov w0,-3`（`0x12800040`）→ `b .`（`0x14000000`）。

## 结果

```
提交次数 182   （正常约 183）
layer+0x30 计数正常递增（101 / 104 / 107 ...）
```

**自旋路径一次都没走到** ⇒ **`GraphicLayerBuffer.handle` 非空，
`SetLayerBuffer` 正常下发了句柄。**

docs/60 的"句柄为空导致画黑"假设**证伪**。

## 累计：结构与语义层面已全部对齐

- 图层结构 14 字段 —— 全同
- gbuffer 对象 `+0x20`/`+0x30`/`+0x38` —— 全同
- gbuffer 宽度、目标矩形 —— 正确
- 三条判空分支 + 23 条错误分支 —— 全 0
- **`SetLayerBuffer` 句柄传递 —— 正常（本轮）**
- GL 版本、绘制路径、占位图遮挡 —— 已排除

**guest 侧到宿主的数据通路，每一环都验证过是好的。但屏幕是黑的。**

## 新观察（可能是线索）

提交频率有差异：

| | 提交次数 | 时长 | 频率 |
|---|---|---|---|
| 6.0.0 | 82~97 | ~4 min | ~22/min |
| 我们 | 182 | ~3.5 min | **~52/min** |

我们提交**快一倍多**。可能是 vsync/驱动节奏不同，也可能是
`librender_service.z.so` 的强制 GL 补丁改变了渲染节奏。
尚未验证是否与不出屏有关。

## 下一步（换打法，不再逐字段比对）

数据通路已证完，问题只可能在**最终的 GL 呈现**上：

1. **验证绘制调用是否真的画出东西**
   在 6.0.0 上 NOP 掉 `0x7963cc: blr x2`（`ops->fn(0x9117, 0, gbuffer)` 绘制），
   看屏幕是否变黑 —— 确认这条调用就是"画上去"的那一步。
   若是，则在我们这边同样 NOP 一次看是否本就黑（等于没画）。

2. **查 ops 表** `*(0x7b44580)` 的实现
   （`0x796524` 处 `ldr x2,[x0]` 取的函数指针），
   看 opcode `0x9117`（绘制）与 `0x8d40`（呈现）各自做什么、
   从 gbuffer 哪个字段取像素。

3. **对比提交频率差异**：把 `librender_service.z.so` 的强制 GL 补丁
   恢复成强制 Vulkan（docs/52 的 `b 0x410570`），看频率与出屏是否变化。

## 状态

- 镜像：`libcomposer.z.so` = 自旋补丁版（`2030c0f274`），**下次实验前需换回**
  （`tmp/prov/libcomposer_keep.so` 是手机原版 `6fc226a0`）
- `sdk/emulator/Emulator`：字段 dump 插桩 + setParent NOP + paint/present 已恢复
- `librender_service.z.so`：原版 + 补丁 1 + 强制 GL 两处 nop
