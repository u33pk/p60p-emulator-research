# 69. hdf_devmgr 补丁排除；libcomposer 实现集是 6.0.1 的超集

日期：2026-10-21

## 本轮两项

### 1. `libcomposer` 的**实现集**对比 —— 手机版是 6.0.1 的超集

已定义符号：手机版 264 个、6.0.1 版 261 个。
**6.0.1 独有 0 个**；手机独有 3 个（`HdiLayer::CheckRet`、
`HdiOutput::CheckFbSurface` 的 hilog 格式串、`HwcDeathRecipient::OnRemoteDied`）。

结合 docs/68 的导入集对比（105 个完全一致），可以确定：
**手机 `libcomposer` 的接口面与 6.0.1 完全兼容且更全**，不存在"少实现了某个方法"。

### 2. `hdf_devmgr` 补丁回退 —— 不解决

docs/67 的 6.0.1 全套镜像对照用的是**原版 vendor**（含原版 `hdf_devmgr`），
而我们的 vendor 里 `hdf_devmgr` 一直带着 4 字节补丁（`DevmgrServiceGetInstance`
改调用目标）。这是一个此前未测试的变量。

回退到 6.0.1 原版（md5 `992fdb6a`）后冷启动：

```
HOST 34369 字节 → 仍黑屏
```

⇒ 该补丁不是原因。（暂留原版，更贴近 6.0.1。）

---

## 累计排除清单（25+ 项）

**结构/数据**：图层 14 字段 · gbuffer 4 字段 · 目标矩形 · gbuffer 尺寸 ·
`SetLayerBuffer` 句柄 · `libcomposer` 导入集 · `libcomposer` 实现集

**宿主侧**：判空分支 · 23 条错误分支 · GL 版本 · `static_value_prepare` · bgra ·
绘制调用点 · 绘制路径选择 · 占位图遮挡 · 宿主日志逐行一致

**配置/二进制**：`graphic.cfg`/`graphic.para` · buffer HDI 不对称（已修）·
`find null prt`（已修）· `libhwdisplay_proxy` · vendor vsync 补丁 · `hdf_devmgr` 补丁

**对照实验**：6.0.0 全套出屏 · 6.0.1 全套出屏 · 我们不出屏 → 问题 100% 在手机 system 侧

## 剩余可能（缩小到 2 条）

**A. gbuffer 像素内容为空**
   绘制函数从绑定纹理取像素，纹理在 paint 之外绑定。
   gbuffer 对象 4 个字段已查（0/2/0/0），还剩 7 个字段未查。

**B. 手机 `render_service` 的渲染产物 / 调用序列**
   接口面相同，但**调用顺序、参数取值**可能不同。
   → 给 601 的 `libdisplay_composer_hdi_impl_1.3` 加日志，跑两边对比 HDI 调用序列。
   这是目前最直接、最可能出结果的一条。

## 状态

- `hdf_devmgr`：已还原 6.0.1 原版
- `graphic.cfg`：6.0.1 版（docs/68）
- `sdk/emulator/Emulator`：字段 dump 插桩 + `0x11065a8` setParent NOP（占位图已隐藏）
- `libcomposer.z.so`：手机原版；`librender_service.z.so`：原版 + 补丁 1 + 强制 GL
