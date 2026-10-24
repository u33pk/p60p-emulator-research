# 46. 攻界面出屏（三）：ABI 兼容已确认，帧从未到达宿主

日期：2026-10-20

## 本轮结论

1. **`libcomposer.z.so` 必须保持手机原版** —— 换 6.0.1 版再次导致 guest 内核 panic
   （第 2 次复现）。且 panic 机制看清了：是用户态进程写 `/proc/sysrq-trigger`
   （`Show Blocked State` → `Show backtrace` → crash），属于主动自毁，不是崩溃。
2. **`libcomposer` ↔ `libdisplay_composer_hdi_impl_1.3` 的 ABI 是兼容的**
   —— 两者之间只有 1 个共享符号 `IDisplayComposerInterface::Get(bool)`，
   是 HDI IDL 生成的稳定接口（同为 V1_3）。
   ⇒ **"图层结构体布局不匹配"的假设基本不成立**，搜索方向要换。
3. **宿主窗口在整个开机过程中从未出现过 guest 帧**（连 bootanimation 都没有）。

---

## 一、`libcomposer` 不能换

| 版本 | 结果 |
|---|---|
| 手机原版 `6fc226a0` | guest 正常启动、桌面可用 |
| 6.0.1 版 `c4f73804` | **guest 内核 panic，hdc 连不上** |

第 1 次（10-20 18:23）第 2 次（10-20 22:50）都复现。panic 栈显示
`write_sysrq_trigger` → `__handle_sysrq`，是用户态主动写的 sysrq。

结合 ABI 分析（见下），panic 更可能是 **完整性/校验机制**发现文件被换掉后自毁，
而不是符号不兼容。也就是说换库这条路被"镜像完整性保护"挡住了，
不是靠调对版本能绕过去的。

## 二、ABI 兼容性核实

```
libcomposer(手机) 未定义符号: 113
6.0.1 hdi_impl  导出符号: 30
两者交集(实际 ABI 依赖): 1
   OHOS::HDI::Display::Composer::V1_3::IDisplayComposerInterface::Get(bool)
```

只有这一个接口入口，而它是 HDI IDL 生成的版本化接口（`Display::Composer::V1_3`）。
只要双方都是 V1_3，vtable 布局由 IDL 决定，**天然一致**。
`libcomposer` 自带完整的 `HdiBackend / HdiOutput / HdiLayer` 实现（符号表里全是），
它经由这个接口下发 `SetLayerBuffer` / `SetLayerCompositionType` / `CreateLayer` 等调用。

⇒ 之前"手机 libcomposer 与 6.0.1 hdi_impl 图层结构体对不齐"的猜测**可以排除**。

## 三、宿主窗口从开机到桌面全程是占位图

开机过程每 ~12 秒截一次宿主窗口，共 10 次：

```
1..10  全部 42420~42487 字节（占位图），仅转圈动画让 md5 不同
```

guest 的 bootanimation 也是 guest 渲染出来的帧。**连它都没出现在窗口里**，
说明不是"桌面起来了但没呈现"，而是 **guest 的帧从来没送到宿主**。

## 四、其它排除项

- `libhwdisplay_proxy_1.0.z.so`（手机原版，之前没审过）：是
  `OHOS::HDI::Hwdisplay::V1_0` 背光/电源接口，符号里 layer/compos/vsync/gbuffer
  命中 **0**，与合成无关。
- `not support transform_type` 分支再确认（xref `0x796244`）：
  `cmp w0,5 / cmp w0,0` 任一命中就跳过日志，其它情况打日志，
  **所有路径都收敛到 `0x796274` 的绘制调用**。纯日志，不是跳画。

## 五、新的可疑点（未验证）

`libcomposer.z.so` 里有一条关键日志字符串：

```
layer map is empty, drop this frame          ← 图层表为空就丢帧
Need flush framebuffer, client composition layer num is %zu
Create hwc layer succeed, layerId is %u
PreProcessLayersComp failed, ret is %d
```

如果走到 `layer map is empty`，帧会被丢弃 —— 与"帧从未到达宿主"完全吻合，
而且宿主侧所有错误分支都是 0（因为宿主根本没收到东西，自然不报错）。

但这些是 `%{public}s:` 的详细日志，hilog 里一条都没有（当前 buffer 7169 行，
只有 sensor / nearlink / powermgr 等，图形服务日志被过滤或级别太高）。
`hidumper -s RenderService -a "rsLogFlag"` 需要具体标志名，本轮没调通。

## 六、下一步

1. 打开 `libcomposer` / render_service 的详细日志（`rsLogFlag` 的正确参数，
   或用 `hilog` 的 domain/level 控制），触发一帧，看是否打出
   `layer map is empty, drop this frame` 或 `Create hwc layer succeed`。
2. 若确实是图层表为空：查 `HdiOutput::CreateLayerLocked` / `SetLayerInfo`
   为何没建出层（可能与 `libdisplay_composer_hdi_impl_1.3` 的 `CreateLayer` 返回值有关）。
3. 备选：给宿主 `opengl_paint_composer_layers` 打补丁，强制打印
   `num / calc_size / layers_size`（改 `Gbuffer_Layers size is not equal` 那条校验
   的分支即可复用现成格式串），直接看 guest 提交了几层。
