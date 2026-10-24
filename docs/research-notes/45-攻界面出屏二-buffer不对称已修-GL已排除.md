# 45. 攻界面出屏（二）：buffer HDI 不对称已修复，GL 版本已决定性排除

日期：2026-10-20

## 本轮两条硬结论

1. **修掉了一个真 bug**：`libdisplay_buffer_*` 通道的 system 侧是手机原版、
   vendor 侧是 6.0.1，**协议不对称**，导致宿主把 2 次调用直接丢弃
   （`find null prt!!!`）。换成 6.0.1 后告警消失，宿主日志与 6.0.0 正常案例**逐行一致**。
2. **决定性排除 GL 版本**：6.0.0 在同样的 `host gl 46` 下照样正常出屏。

---

## 一、buffer HDI 不对称 —— 真因之一

### 发现

`render_service` 实际加载的显示相关库：

```
composer 通道   /system/lib64/libdisplay_composer_hdi_impl_1.3.z.so   ← 已换成 6.0.1
                /system/lib64/libdisplay_composer_proxy_1.{0,1,2,3}.z.so  ← 已换成 6.0.1
buffer  通道   /system/lib64/chipset-sdk/libdisplay_buffer_hdi_impl_v1_3.z.so   ← 手机原版
                /system/lib64/chipset-sdk/libdisplay_buffer_proxy_1.3.z.so      ← 手机原版
                /system/lib64/chipset-sdk-sp/libdisplay_buffer_proxy_1.{0,1,2}.z.so ← 手机原版
```

vendor 侧（`composer_host`）加载的是 6.0.1 的
`libdisplay_buffer_vdi_impl / stub_1.{0,1,2} / vendor`。
**composer 通道换了、buffer 通道没换** —— 一端说 6.0.1 方言、另一端说手机方言。

之前这两个文件 mtime 是 20-Oct（重写过），但内容与原版逐字节一致，
所以全量 diff 没列出来，差点漏掉。

尺寸差异也说明问题：`libdisplay_buffer_hdi_impl_v1_3.z.so`
手机原版 **64480**（完整实现）vs 6.0.1 **29176**（模拟器桩）。

### 修复

把这 5 个换成 6.0.1 版本：

```
system/lib64/chipset-sdk/libdisplay_buffer_hdi_impl_v1_3.z.so    c972114d(64480) -> 51173ec4(29176)
system/lib64/chipset-sdk/libdisplay_buffer_proxy_1.3.z.so        b3e2b089(47664) -> 4490f9fa(46688)
system/lib64/chipset-sdk-sp/libdisplay_buffer_proxy_1.0.z.so     f3c3ac4b(51432) -> 96c15a63(49896)
system/lib64/chipset-sdk-sp/libdisplay_buffer_proxy_1.1.z.so     dc73e54f(38584) -> d8bc970f(38472)
system/lib64/chipset-sdk-sp/libdisplay_buffer_proxy_1.2.z.so     6a9e2fbd(40312) -> 0eb0ac1f(40448)
```

### 效果

宿主显示握手序列从

```
Get Display id : 0, power state :0
device type: 0
find null prt!!!                      ×2   ← 调用被丢弃
        （隔 3 秒）
Get Display id : 0, power state :0
```

变成

```
Get Display id : 0, power state :0
device type: 0
Get Display id : 0, power state :0    ← 紧接着，与 6.0.0 完全一致
```

`find null prt` 计数：修复前 2，修复后 **0**，6.0.0 也是 0。

宿主 gbuffer / paint 全部错误分支逐条核对（`Too many layers`、
`Gbuffer_Layers size is not equal`、`layers is null`、`display gbuffer is nullptr`、
`alloc gbuffer failed`、`guest_upload_gbuffer_data`、`glMapBufferRange error` …共 23 条），
我们与 6.0.0 **全部都是 0**，完全一致。

guest 侧 `SetDisplayConstraint` / `SetLayerMaskInfo ... is not supported` 两条告警
在 6.0.0 正常时**也有**，是噪音。

## 二、GL 版本 —— 决定性排除

之前注意到我们与 6.0.0 有两个宿主侧差异：
`host gl 46` vs `45`，以及 `when creating static vaules 500`（`0x500` = `GL_INVALID_ENUM`）。

逆向 `static_value_prepare`（xref `0x79f474`）：那个 `500` 是一次
GL 调用的返回码，非 0 就打这条；之后代码把两个上限钳到 32/16。
`current image not support bgra` 只在 4.5 分支打。确实两条路径。

但做了对照实验后排除：

| 配置 | host gl | guest | host 窗口 |
|---|---|---|---|
| 6.0.0 官方镜像 | **46** | 675KB 锁屏 | **205KB 正常出屏** |
| 我们的镜像 | **46** | 750KB 锁屏 | 42KB 占位图 |

**同会话、同 GL 版本、同宿主二进制**，6.0.0 出屏、我们不出。
⇒ `host gl 45/46`、`static_value_prepare` 的 `0x500`、bgra 分支**全是噪音**。

（顺带：`host gl 45/46` 是随机的，10-18 就混着出现；
10-20 14:09 之后的开机恰好都是 46，之前所有截图判定都在 46 上，才显得像相关。）

## 三、当前定位

宿主日志、guest 日志、GL 版本、错误分支、窗口树全部与 6.0.0 对齐，
**唯独不出屏** ⇒ 差异在 guest 交给宿主的**图层数据本身**。

新首要嫌疑：`system/lib64/libcomposer.z.so` 是**手机原版**（一直没换），
而它把图层交给的 `libdisplay_composer_hdi_impl_1.3.z.so` 已经是 6.0.1 的 ——
图层结构体布局可能对不齐。

已知线格式：`CommitComposeLayer` 只 `write(fd, buf, 32)` 写命令头，
`GBuffer_Layers*` + size 在共享内存，校验 `size == layerCount*60 + 4`，每层 60 字节。
该校验能过（`Gbuffer_Layers size is not equal` 计数 0），说明**总字节数对**，
但**每层 60 字节内部的字段布局**可能与宿主期望不一致。

> 注意：换 `libcomposer.z.so` 成 6.0.1 版本之前试过，触发
> `sysrq: Trigger a crash` 内核 panic。但那次 panic 是 sysrq 主动触发的，
> 与 libcomposer 的因果关系其实**没有严格证明**，值得用更谨慎的方式重试
> （例如先只换 `libdisplay_composer_hdi_impl` 回手机原版，
> 保持 `libcomposer` 手机原版，看能否对齐）。

## 四、工具与截图

- 归档新增：`13/14`（buffer 修复后 guest/host）、`15/16`（6.0.0 gl46 对照 guest/host）
- `tmp/xshot.py` 已支持自动找 Emulator 窗口（窗口 id 每次启动都会变）

## 五、下一步

1. 首选：让 `libcomposer.z.so` 与 `libdisplay_composer_hdi_impl_1.3.z.so`
   来自同一构建（都是手机原版，或都是 6.0.1），二选一冷启动对照。
2. 若仍不出屏：dump 出 guest 侧提交的 `GBuffer_Layers` 每层 60 字节内容，
   与 6.0.0 同位置 dump 对比字段布局。
