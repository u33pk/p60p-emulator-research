# 48. 更正 47 —— `gbuffer_id:0` 不是根因；插桩自身有 double-free

日期：2026-10-20

## 一、更正

**docs/47 的"根因：gbuffer_id 恒为 0"是错的。** 那是**插桩补丁自身的 double-free** 造成的假象。

插桩时我把 Commit 处理里"尺寸不匹配"分支的日志强制放出来，同时把该分支末尾的
`b err_return` 改成 `b OK` 继续执行。但**那个分支在跳转前已经 `g_free(buf)` 了**，
跳到 OK 路径后 paint 完又 `g_free(buf)` 一次 → `free(): double free detected in tcache 2`，
堆被破坏 → `gbuffer_from_global_map` 查询失败 → 打出海量 `gbuffer_id:0`。

### 干净对照（修好插桩后）

| | 6.0.0（出屏 206KB） | 我们（占位图 42KB） |
|---|---|---|
| `Gbuffer_Layers size` 提交次数 | 82 | 185 |
| `num / calc / layers_size` | 1 / 64 / 64 | 1 / 64 / 64 |
| `gbuffer_from_global_map is null` | **0** | **0** |
| `not support transform_type` | 1 | 1 |
| `MAIN_CREATE_CHILD_WINDOW` | 1 | 1 |
| `layers is null` / `display gbuffer is nullptr` / `guest_upload_gbuffer_data` / `Too many layers` | 0 | 0 |

**全部一致。** `gbuffer_from_global_map` 在两边都是 0，说明缓冲映射是正常的。

## 二、插桩补丁的最终正确版本（4 处）

| 偏移 | 原 | 改 | 作用 |
|---|---|---|---|
| `0x794560` | `b.eq 0x7945e4` | `nop` | 强制走日志分支 |
| `0x794574` | `b.gt 0x7945d8` | `nop` | 日志无条件执行 |
| `0x7945dc` | `bl g_free` | **`nop`** | **去掉错误分支的 free（关键修复）** |
| `0x7945e0` | `b 0x794e84` | `b 0x7945e4` | 打印后继续走 paint/present |

`display_decode_invoke` 的 Commit 路径（`0x794404`）结构：

```
buf = g_malloc0(size)
num = *(int*)buf                  ; 图层数
calc = num*60 + 4
if (size != calc) { log(...); g_free(buf); return; }   ← 原逻辑
bl 0x795df4                       ; opengl_paint_composer_layers
g_free(buf)
bl 0x796434                       ; display_present
```

备份：`tmp/Emulator.before_instr`（原版）。当前 `sdk/emulator/Emulator` 是 4 处插桩版。

## 三、仍然成立的事实

- guest 提交 **1 层、64 字节（1×60+4）**，线格式长度正确 —— 与 6.0.0 一致
- 宿主所有 gbuffer / paint 错误分支在两边都是 0
- 我们提交次数**更多**（185 vs 82），不是"没提交"
- `hidumper -s RenderService -a "surface"` 的图层语义（zOrder / transformType /
  compositionType / blendType / layerAlpha / layerRect / cropRect / 缓冲状态）
  与 6.0.0 **逐字段一致**

## 四、现状与下一步

差异已经被压缩到**唯一一个维度**：60 字节图层线格式的**内容**（或 gbuffer 像素内容）。
语义层完全一致，但宿主拿到后画出来的东西不同。

下一步：把这 60 字节 dump 出来做逐字节对比。
最省事的做法是改 Commit 处理里那条日志的取数来源 ——
`0x79457c` 的 `ldr w4,[x0]`（取 num）改成 `ldr w4,[x0,#4]` 之类，
把 `w5/x6/x7` 三个 printf 参数指向图层结构的不同偏移，
每次提交打 3 个字段，用几十次提交就能拼出完整 60 字节。
两边各 dump 一份即可对比。

> 教训：给宿主打插桩时，**必须检查被绕过的分支有没有资源释放**。
> 这次的 double-free 让我得出一个错误的根因，浪费了一轮。
