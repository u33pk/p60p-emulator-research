# 68. graphic.cfg 差异排除；import 集完全一致；调查现状总结

日期：2026-10-21

## 本轮两件事

### 1. 静态对比 `libcomposer` 的调用集 —— 无差异

手机版与 6.0.1 版 `libcomposer.z.so` 的**导入符号集完全一致**（各 105 个），
唯一差异是日志 API（`HiLogPrintDictNew` vs `HiLogPrint`）和 `strlen`/`RefBase::CanPromote`。

⇒ **手机版没有少调任何外部接口。** 差异只能在调用的**序列/取值**，不在调用集。

### 2. `graphic.cfg` 换 6.0.1 版 —— 不解决

两边 `graphic.cfg` 的 `render_service` service 定义**逐字段一致**，
唯一差异是我们的多了 `"disabled": 1` + 2 个 job（`bootevent.composer_host.ready`
→ `start render_service`、`bootevent.wms.fullscreen.ready` → `stop bootanimation`）。
`graphic.para` 与 6.0.1 **完全一致**。

把 `graphic.cfg` 换成 6.0.1 版（去掉 disabled 与那 2 个 job）后冷启动：

```
HOST 34369 字节 → 黑屏（占位图已被 setParent NOP 隐藏）
提交 195 次、layer+0x0c/0x24 = 1320、gbuffer_null = 0
```

guest 一切正常（render_service 由 init 自启也没问题），但**仍不出屏**。
⇒ 该假设排除。那 2 个 job 不是原因（但暂留 6.0.1 版配置，更贴近原设计）。

---

## 调查现状（24 轮 / 约 6 小时）

### 已确定的事实

1. **问题 100% 在手机 system 侧**（docs/67 决定性对照）
   - 6.0.0 官方镜像 → 出屏
   - 6.0.1 官方镜像 → 出屏
   - 我们的手机 system + 601 vendor → 不出屏
2. **guest 侧完全正常**：`snapshot_display` 是完整锁屏、可交互、195 次/开机提交
3. **宿主侧接收正常**：图层 1 层、64 字节、目标矩形 1320×2232、gbuffer 尺寸正确、
   所有判空与错误分支为 0、宿主日志与 6.0.0 逐行一致
4. **绘制调用确实执行**（`0x796154` 的 `blr x4`，NOP 掉 6.0.0 会黑屏）

### 已排除（累计 20+ 项）

图层 14 字段 · gbuffer 4 字段 · 目标矩形 · gbuffer 尺寸 · `SetLayerBuffer` 句柄 ·
判空/错误分支 · GL 版本 · `static_value_prepare` · bgra · Vulkan 互操作 ·
RS 绘制路径 GL/Vulkan · 绘制调用点 · 占位图遮挡 · buffer HDI 不对称（已修）·
`find null prt`（已修）· `libcomposer` 调用集 · `graphic.cfg`/`graphic.para` ·
`libhwdisplay_proxy` · vendor vsync 补丁

### 剩余可能（按优先级）

**A. gbuffer 像素内容为空**（最可能）
   绘制函数 `fn(x,y,w,h)` 从绑定的纹理取像素。纹理在 paint 之外绑定。
   gbuffer 对象 `+0x00/+0x20/+0x30/+0x38` 已查，剩余 `+0x04/+0x08/+0x10/+0x14/+0x1c/+0x28/+0x2c`
   未查，真像素指针可能在其中之一。→ 逐个 dump，或直接查 `**(0x7b41920)` ops 实现。

**B. 手机 `libcomposer` 的调用序列/取值**（调用集相同但顺序/参数可能不同）
   → 给 601 的 `libdisplay_composer_hdi_impl_1.3` 加日志，跑两边对比序列。

**C. 手机 `render_service` 的渲染产物**
   → 对比 6.0.1 的 `render_service` 与手机版在相同输入下的输出缓冲。

## 状态

- `graphic.cfg`：已换成 6.0.1 版（guest 正常，暂留）
- `sdk/emulator/Emulator`：字段 dump 插桩 + `0x11065a8` setParent NOP
  （**注**：占位图已隐藏，现在黑屏=没出屏；要看占位图需还原该补丁）
- `libcomposer.z.so`：手机原版；`librender_service.z.so`：原版 + 补丁 1 + 强制 GL
- 符号链接：system→手机、vendor→p60pv2_vendor
