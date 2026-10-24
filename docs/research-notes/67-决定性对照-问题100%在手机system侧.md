# 67. 决定性对照：6.0.1 自己的镜像正常出屏 —— 问题 100% 在手机 system 侧

日期：2026-10-21

## 实验

把 `image_root` 下的符号链接全部切到 `system_6.0.1/`（6.0.1 的
system/vendor/userdata/ramdisk/sys_prod/Image/…），删 qcow2 冷启动，
用同一个 `Emulator` 二进制、同一实例目录跑。

## 结果

```
6.0.1 全套 HOST  205413 字节  →  正常出屏
```

| 配置 | host 窗口 |
|---|---|
| 6.0.0 官方镜像 | 206KB 出屏 |
| **6.0.1 官方镜像** | **205KB 出屏** ← 本轮 |
| 我们的手机 system + 601 vendor | 42KB 占位图 / 34KB 黑 |

⇒ **模拟器宿主 + 6.0.1 vendor 完全没问题。**
我们不出屏的原因 **100% 在手机 system 侧**，与宿主、与 601 vendor 无关。

这也解释了为什么之前所有宿主侧比对都"完全一致"：
**宿主本来就是好的**，差异全在 guest 交给它的内容里。

## 定位收窄

现在可以确定的边界：

```
[手机 system 侧]  →  601 vendor（composer_host）  →  宿主 Emulator  →  窗口
     ↑ 问题在这里                ↑ 正常                  ↑ 正常
```

已验证手机侧正常的部分：
- guest 渲染（`snapshot_display` 是完整锁屏）
- 图层结构 14 字段、目标矩形 1320×2232、gbuffer 尺寸
- `SetLayerBuffer` 句柄传递
- 宿主日志与 6.0.0 逐行一致

⇒ 差异在 **手机的 `libcomposer.z.so`（HdiBackend/HdiOutput/HdiLayer 组合引擎）
向 601 的 `libdisplay_composer_hdi_impl_1.3` 下发的调用序列**里，
某个 6.0.1 的 vendor 期待但手机版没发的调用（或反之）。

## 下一步（明确）

1. **对比两边的 HDI 调用序列**：手机 `libcomposer` 调用 `HdiDeviceImpl::*`
   （`CreateLayer` / `SetLayerBuffer` / `SetLayerCompositionType` /
   `PrepareScreenLayers` / `ReleaseLayers`…）与 6.0.1 自己的 `libcomposer` 调用的
   序列对比。可以在 601 的 `libcomposer.z.so`（`c4f73804`）里看它调了哪些
   `HdiDeviceImpl` 方法，再核对手机版是否都调了。
2. 或者给 601 的 `libdisplay_composer_hdi_impl_1.3` 加日志，记录收到的每个
   HDI 调用，跑两边对比。

> 第 1 条**纯静态、零冷启动成本**，建议先做。
> `nm -D` 列出两边 `libcomposer` 引用的 `HdiDeviceImpl::*` 符号做差集即可。

## 状态

- 符号链接已恢复（`system.img`→手机、`vendor.img`→`p60pv2_vendor`）
- `sdk/emulator/Emulator`：仍带字段 dump 插桩 + setParent NOP
- `libcomposer.z.so`：手机原版；`librender_service.z.so`：原版 + 补丁 1 + 强制 GL
