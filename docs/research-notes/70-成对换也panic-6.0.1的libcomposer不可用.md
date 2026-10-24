# 70. 成对换 libcomposer+librender_service_base 也 panic —— 6.0.1 的 libcomposer 不可用

日期：2026-10-21

## 实验

此前单换 `libcomposer.z.so`（6.0.1 版）两次都触发 guest 内核 panic
（`sysrq triggered crash`）。怀疑是它 NEEDED `librender_service_base.z.so`
而两者不同源导致。本轮**成对**换成 6.0.1 版：

```
libcomposer.z.so            -> c4f73804 (6.0.1)
librender_service_base.z.so -> f74a46a7 (6.0.1)
```

## 结果

**仍然 panic**（kernel.log `2026-10-21 07:32:59` `Kernel panic - not syncing: sysrq triggered crash`，
是本次新发生的，不是历史累积）。

⇒ **不是 `libcomposer` ↔ `librender_service_base` 不匹配**。
6.0.1 的 `libcomposer` 在手机系统里**根本无法运行**。

结合 docs/69（接口面完全兼容且更全），说明问题不是 ABI/接口，
而是**运行时完整性/校验**：手机系统对 `libcomposer.z.so` 有校验，换掉就自毁。

⇒ **`libcomposer.z.so` 必须保持手机原版**，这条路彻底堵死。

已恢复：`libcomposer` → `6fc226a0`（手机原版）、
`librender_service_base` → `5584f963`（手机原版 + 之前的 VK 补丁已还原）。

## 结论

「用 6.0.1 的组合引擎替换手机的」这条路**不可行**。
问题必须在**手机原版 `libcomposer` 的行为**里解决，
或者绕过它（例如改 `libdisplay_composer_hdi_impl_1.3` 侧的适配）。

## 剩余可能（docs/69 的两条仍然有效）

**A. gbuffer 像素内容为空** —— gbuffer 对象还剩 7 个字段未查，真像素指针可能在其中之一

**B. 手机 `libcomposer` 的调用序列/参数取值不同**
   接口面相同，但顺序/取值可能不同。
   → **给 601 的 `libdisplay_composer_hdi_impl_1.3` 加日志**，
     在它这一侧记录收到的每个 HDI 调用（方法名 + 关键参数），
     跑两边（我们的手机 system / 6.0.1 的 system）对比序列。
     这是目前**最直接、最可能出结果**的一条，而且**不需要动手机的任何二进制**。

## 状态

- `libcomposer.z.so`：手机原版（`6fc226a0`）
- `librender_service_base.z.so`：手机原版（`5584f963`）
- `hdf_devmgr`：6.0.1 原版；`graphic.cfg`：6.0.1 版
- `sdk/emulator/Emulator`：字段 dump 插桩 + `0x11065a8` setParent NOP（占位图已隐藏）
