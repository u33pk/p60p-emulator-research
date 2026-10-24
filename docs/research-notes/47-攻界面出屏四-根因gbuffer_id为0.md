# 47. 攻界面出屏（四）：根因锁定 —— gbuffer_id 恒为 0

日期：2026-10-20

## 根因（一句话）

guest 提交的图层里 **`gbuffer_id` 恒为 0**，宿主 `opengl_paint_composer_layers`
按这个 id 去全局 gbuffer 表里查缓冲，查不到 → 画空气 → 窗口停在占位图。

日志实测：`gbuffer_from_global_map is null. gbuffer_id:0` 出现 **44475 次**，
取值分布 **100% 是 0**。

---

## 一、怎么拿到的：给宿主打插桩补丁

之前所有宿主日志在我们与 6.0.0 正常案例之间**逐条一致**，看不到差异，
因为关键路径的日志都被级别门控挡住。所以给 `sdk/emulator/Emulator` 打了
**3 处保留原行为**的插桩补丁，把 Commit 处理里那条尺寸校验的日志强制放出来：

| 偏移 | 原 | 改 | 作用 |
|---|---|---|---|
| `0x794560` | `b.eq 0x7945e4` | `nop` | 强制走日志分支 |
| `0x794574` | `b.gt 0x7945d8` | `nop` | 日志无条件执行 |
| `0x7945e0` | `b 0x794e84` | `b 0x7945e4` | 打印后继续走 paint/present，不中断 |

`display_decode_invoke` 的 Commit 路径（`0x794404`）结构已核实：

```
buf = g_malloc0(size)
num = *(int*)buf                      ; 图层数
calc = num*60 + 4
if (size != calc) { log("Gbuffer_Layers size is not equal ..."); g_free(buf); return; }
bl 0x795df4                           ; opengl_paint_composer_layers
g_free(buf)
bl 0x796434                           ; display_present
```

备份：`tmp/Emulator.before_instr`（= 原 `tmp/Emulator.sigpatched.20261017`）。
当前 `sdk/emulator/Emulator` md5 `c30b56a8…`，是**插桩版**。

## 二、插桩得到的事实

```
Gbuffer_Layers size is not equal to data size num 1 calc size 64 layers_size 64
```

- **图层数 = 1**
- **calc = layers_size = 64**（1×60+4），**尺寸完全正确**
  （这条日志是我强制放出来的，实际走的是"相等"分支，原逻辑判定通过）

⇒ guest 侧送的是**1 层、格式正确**。问题不在层数、不在线格式长度。

然后 paint 里：

```
opengl_paint_composer_layers:714  gbuffer_from_global_map is null. gbuffer_id:0
```

宿主按 `gbuffer_id` 查 `gbuffer_from_global_map`，查不到 → 该层没有像素来源。

## 三、因果链澄清（重要，别搞反）

**换 buffer HDI 之前**：`find null prt` ×2（Commit 被丢），
`gbuffer_from_global_map is null` = **0** —— 因为 paint 根本没跑到。

**换 buffer HDI 之后**（docs/45）：`find null prt` = 0，
`gbuffer_from_global_map is null` = **44475** —— transport 通了，paint 跑了，
才暴露出 gbuffer 问题。

⇒ **buffer HDI 那次替换是对的**（把调用丢弃修好了），它不是引入问题，而是让下一层问题显形。
现在的位置比之前更靠前。

## 四、gbuffer 是怎么来的

符号依赖链：

```
libcomposer.z.so (手机原版)
   └─ NEEDED libdisplay_composer_hdi_impl_1.3.z.so (6.0.1)
        └─ OHOS::HDI::Base::NativeBuffer::SetBufferHandle(BufferHandle*, ...)
             ↑ 把句柄塞进 composer 调用

libdisplay_buffer_hdi_impl_v1_3.z.so (6.0.1)
   └─ OHOS::HDI::Display::Buffer::V1_0::IAllocator::Get()
   └─ OHOS::HDI::Display::Buffer::V1_0::IMapper::Get()
   └─ OHOS::HDI::Display::Buffer::V1_1::IMetadata::Get()
             ↑ 缓冲分配/映射
```

即：缓冲由 **buffer HDI**（`IAllocator`/`IMapper`）分配，
句柄由 **composer HDI**（`NativeBuffer::SetBufferHandle`）带上层调用。
宿主收到后应把句柄登记进 `gbuffer_from_global_map` 并返回 id。

本次开机 **`alloc_gbuffer` / `create display gbuffer` / `display_context_init_gbuffer`
一条日志都没有** —— 全局表从没被填过，所以查任何 id 都是 null。

## 五、下一步

1. 查宿主 `gbuffer_from_global_map` 的**写入侧**：谁调 `alloc_gbuffer` /
   `create display gbuffer`，触发条件是什么（很可能是某个 funId 的
   "注册缓冲"调用，guest 侧没发）。
2. 对照 6.0.0：插桩版跑一次 6.0.0 镜像，看它的 `num/calc/size`
   以及 `gbuffer_from_global_map` 是否为 0 —— 直接确认 id 分配差异。
3. 若是 guest 没发注册调用：查 `libcomposer`（手机）与
   `libdisplay_buffer_hdi_impl_v1_3`（6.0.1）之间缓冲句柄的传递是否断了
   （`libcomposer` 并不直接 NEEDED buffer HDI，中间隔了 `libsurface` /
   `librender_service_base`）。

## 六、当前状态

- guest：完整锁屏、可交互（未变）
- host：仍是占位图，但**已定位到具体缺失对象（gbuffer 映射）**
- 宿主日志里除 `gbuffer_from_global_map` 外所有错误分支仍为 0
