# 44. 攻界面出屏（一）：vendor vsync 补丁已排除，`find null prt` 是新首要嫌疑

日期：2026-10-20

目标：让模拟器窗口真正显示 guest 桌面（而不是开机占位图）。

## 本轮结论（一句话）

vendor 侧那 4 处二进制补丁**不是**不出屏的原因 —— 回退到 6.0.1 原版后 guest 照常、
窗口仍是占位图。顺带发现这 4 处补丁**根本不需要**，可以从改动清单里删掉。

新首要嫌疑：宿主 `fill_teleport_express_queue_elem` 的 `find null prt!!!` ——
guest 传了未注册的对象指针，宿主把这次调用**直接丢弃**，出现时机正好卡在显示握手中。

---

## 一、先纠一个上一轮的误判

之前按"文件偏移"定位补丁，误以为它们在 `HdiLayer::SetLayerBuffer` 等送帧函数里。

**错在 `libdisplay_composer_vendor.z.so` 的 `vaddr ≠ 文件偏移`**：

```
LOAD  offset 0x008024 -> vaddr 0x00009024   R E    （代码段，偏移差 +0x1000）
LOAD  offset 0x0132a0 -> vaddr 0x000152a0   RW
```

文件偏移 `0x11050` 实际是 vaddr `0x12050`。按 vaddr 重新归属后，4 处补丁全部落在
**`SorftVsync::WorkThread()`**（vaddr `0x11f8c` – `0x12158`）—— 软件 vsync 线程。

> 教训：逆向任何非主执行段对齐的 `.so`，先 `readelf -lW` 看 LOAD 偏移，再谈地址。
> （同批的 `hdf_devmgr` 也有 +0x1000 偏移。）

## 二、4 处补丁的精确语义

`SorftVsync::WorkThread` 是个 60Hz 软 vsync 循环：加锁 → 看标志 → condvar 等待 →
解锁 → `usleep(自适应周期 + 0x3c06)` → 调 `this+0x70` 的回调 → 循环。

| vaddr | 原版 | 改成 | 效果 |
|---|---|---|---|
| `0x12050` | `cbnz w8, 0x1207c` | `b 0x1207c` | **永不 condvar 等待**，直接解锁 |
| `0x12084` | `cbz w25, 0x1211c` | `nop` | **永不因 enable 标志退出**线程 |
| `0x12094` | `add w25, w8, w27` | `mov w25, w27` | 固定 `15366µs`，**忽略自适应周期** |
| `0x12114` | `bl HiLogPrint` | `nop` | **把 "callback is null" 告警 NOP 掉** |

净效果：让软 vsync 线程绕过一切条件、以固定 ~65Hz 空转，并**掩盖回调为空的事实**。

第 4 处最可疑 —— 如果回调正常，就没有告警需要 NOP。而 `WorkThread` 里
`cbnz x0, 0x12030` 是"回调非空就调用"，为空则只打这条告警。
**回调为空 = vsync 根本没送达**，与"不出屏"高度吻合。

`ReqesterVBlankCb`（vaddr `0x121d0`）是注册入口，把 shared_ptr 写进 `this+0x70`，
正是 `WorkThread` 读的槽位。它是导出符号、外部调用，静态扫不出调用者
（`EnableVsync` / `WorkThread` / `Init` 同样是 0 次直接 `bl`），
说明走虚表或外部库。

## 三、实验：回退这 4 处补丁

把 `libdisplay_composer_vendor.z.so` 换回 6.0.1 原版（md5 `cc1e8b1a…`），
删 vendor qcow2 冷启动：

| | 回退前 | 回退后 |
|---|---|---|
| guest（`snapshot_display`） | 754KB 完整锁屏 | **729KB 完整锁屏**（时钟 10:19 / 10月20日 星期二 / 电量100） |
| host（模拟器窗口） | 42KB 占位图 | **42KB 占位图** |

⇒ **不是原因**。而且 guest 不受影响，说明这 4 处补丁是历史实验残留，**可以从最小改动清单删除**。

## 四、新首要嫌疑：`find null prt!!!`

宿主日志里，我们与 6.0.0 正常出屏那次**唯一**的硬差异就是这 2 条告警
（6.0.0 一次都没有），出现在显示握手的 `device type: 0` 之后、
第二条 `Get Display id : 0, power state :0` 之前（6.0.0 是紧接着就打，我们隔 3 秒）。

逆向（字符串 `find null prt!!!` @ vaddr `0x222ffd0`，xref 在 `0x77d3d8`）：

```
; fill_teleport_express_queue_elem，遍历队列项（每项 16 字节）
  if (elem->type != 4) continue
  if (elem->ptr != *(global 0x7c88f18)) continue   ; 必须等于"空指针哨兵"
  if (ctx->0xc != 1) continue
  if (ctx->0x10 != 0) continue
  log("find null prt!!!")                          ; line 446，仅日志级别<=1 时打
  elem->ptr = 0                                    ; ← 把该队列项清零 = 丢弃这次调用
```

即：guest 发起的 teleport_express 调用，其对象指针是 `guest_null_ptr_init:699`
注册的那个**空指针哨兵**（本轮实测值 `264435883402216`），宿主识别后**直接丢弃**。

**这是 guest→宿主的一次调用被吃掉**，而且正好卡在显示握手中间。
下一步就查：guest 侧是谁传了这个哨兵、这次调用本该是什么
（很可能是注册显示缓冲 / 提交呈现之类的对象注册调用）。

## 五、顺手修的工具

`tmp/xshot.py` 之前写死窗口 id `0xe00006`，模拟器重启后 id 变化就 `BadWindow`。
已改成按窗口名 `Emulator` + `map_state==2` + 面积最大自动选取。
另外 `XImage.data` 声明成 `c_char_p` 会被 ctypes 当 NUL 结尾字符串处理导致段错误，
已改成 `c_void_p`。

## 六、当前判据与状态

- guest 侧：完整锁屏 + `uinput` 可交互（滑动后画面实时变）
- host 侧：仍是 HarmonyOS + 转圈占位图
- 已排除：`display_present` 早退、Vulkan 互操作、GL 版本噪音、配置差异、
  vendor vsync 补丁（本轮）
- 首要嫌疑：`find null prt!!!` 的 2 次调用丢弃

截图：`archive/harmony-p60p-on-emulator/screenshots/`（后续补本轮对比图）。
