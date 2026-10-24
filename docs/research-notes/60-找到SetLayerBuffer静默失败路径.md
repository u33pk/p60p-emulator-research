# 60. 找到 SetLayerBuffer 的静默失败路径（handle 为空返回 -3）

日期：2026-10-21

## 发现

`libcomposer.z.so`（手机原版）的
`OHOS::Rosen::HdiDeviceImpl::SetLayerBuffer(uint, uint, GraphicLayerBuffer const&)`
（vaddr `0x1b3a4`）里有一条**静默失败**路径：

```
0x1b3bc  x8 = *(0x3c000+0x298)      ; HDI 接口指针
0x1b3c0  cbz x8, 0x1b3ec            ; 接口为空 → 打日志，返回 -4
0x1b3d0  x8 = [x3]                  ; layerBuffer.handle
0x1b3d4  cbnz x8, 0x1b44c           ; handle 非空 → 继续下发
0x1b3d8  w8 = [x20, 8]              ; layerBuffer.fence
0x1b3dc  cmn w8, 1                  ; fence == -1 ?
0x1b3e0  b.ne 0x1b44c               ; 不是 -1 → 继续
0x1b3e4  mov w0, -3                 ; ← 返回 -3，完全不打日志
0x1b3e8  b 0x1b438                  ; 返回
```

**即：`handle == null && fence == -1` 时静默返回 -3，图层就没有缓冲
→ paint 画出来必然是黑。**

这与现象高度吻合：图层结构全对、gbuffer 对象全对、宿主 paint/present 都跑，
但屏幕是黑 —— **因为句柄从来没交下去**。

## 本轮改动

把 `0x1b3e8` 的 `b 0x1b438`（返回）改成 `b 0x1b3ec`（走日志路径），
这样 handle 为空时会在 guest hilog 里留下痕迹。

产物 `tmp/prov/libcomposer_log.so`（md5 `dc0bb96bda`），已写入镜像。

> `libcomposer.z.so` 也是 `vaddr = 文件偏移 + 0x1000`
> （代码段 LOAD：`offset 0x1115c → vaddr 0x1215c`）。
> 补丁点：vaddr `0x1b3e8` = 文件偏移 `0x1a3e8`。

## 未完成

**hdc 完全无响应**（`hilog` / `echo alive` 都挂起），
无法读取 guest 日志验证 handle 是否为空。

hdc 这几轮越来越不稳（`shell` / `file send/recv` 频繁挂起），
已经连续多轮挡住 guest 侧观测。

## 下一步（绕开 hdc）

1. **镜像内自启脚本**：在 `post-fs-data` 起一个 service，
   循环跑 `hilog -z ... > /data/local/tmp/hilog.txt`，
   把日志落到文件，再从宿主侧用 debugfs 读镜像里的 userdata 拿 ——
   或者干脆让脚本把结果写进一个**宿主能直接看到的地方**。
2. **让失败在宿主侧显形**：把 `0x1b3e4` 的静默 `mov w0,-3` 改成
   调用一个必然在宿主日志留下痕迹的动作（比如故意发一个非法 funId）。
3. **直接看 `GraphicLayerBuffer.handle` 的来源**：
   `HdiLayer::SetLayerBuffer()`（vaddr `0x1ec44`）怎么填这个结构，
   以及 `libdisplay_buffer_*`（6.0.1）返回的句柄是否被正确写进去。

> 优先做 **2**：不依赖 hdc，一次冷启动就能从宿主 qemu.log 看出结论。

## 状态

- 镜像：`libcomposer.z.so` 已打日志补丁（`dc0bb96bda`）
- `sdk/emulator/Emulator`：字段 dump 插桩 + `0x11065a8` setParent NOP + paint/present 已恢复
- `librender_service.z.so`：原版 + 补丁 1 + 强制 GL 两处 nop
