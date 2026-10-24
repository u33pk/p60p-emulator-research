# 55. 根因确定：guest 缺少发送 `boot-complete` 的 QemuParams，占位图从不撤除

日期：2026-10-21

## 结论

模拟器的开机占位图（黑底 + HarmonyOS logo + 转圈）由 Qt 控件
`BootAnimationLabel`（资源 `:/common/harmonyos_logo`）绘制，
由 `EmulatorWindowEvent::ShowBootAnimation()` / `StopBootAnimation()` 控制。

**撤除的触发链**：

```
guest 的 QemuParams ──写──> /dev/express_pipe 的 boot-params 管道
                            消息名: "boot-complete"
        ↓
宿主 BootCompletePipeClientRecv
        ↓
QemuManager::OnBootCompleted()  →  EmitGuestOSBootComplete()
        ↓
StopBootAnimation()  →  占位图消失，露出 guest 帧
```

宿主二进制里的证据（`../emulator/emulator-qemu/boot-params/BootComplete.cpp`）：

```
boot-complete          ← 管道消息名
pipe-ready
clipboard-content
BootCompletePipeInit / BootCompletePipeConnect / BootCompletePipeClientRecv
guest os boot completed.
INTEGRITY_CHECKED completed.
```

事件名集合（`RunStateSubject`）：
`systemreset` / `bootcompleted` / `isNotPublic` / `notInWhitelist` / `alive` /
`clipboardpipeready` / `integrityChecked` / `isNotBuildRoot` / `needSnapshotCheck`

## 我们缺什么

| | 6.0.0 模拟器镜像 | 手机原版 | 我们的 |
|---|---|---|---|
| `system/bin/QemuParams` | **有**（250208 字节） | **无** | **无** |
| `boot-complete` 字符串 | 有 | 无 | 无 |

`QemuParams` 是模拟器专有的 guest 侧助手，负责：
- `QemuBootParamsAdd`（回传 qemu 参数）
- **`Failed to notify BootComplete.`** ← 发送开机完成通知
- 走 `/dev/express_pipe` + 管道 `boot-params`

**手机 ROM 从来没有这个组件**，所以 guest 从不发送 `boot-complete`，
宿主就一直显示开机占位图 —— 与 docs/54 的三组对照完全吻合
（占位图的撤除与 paint/present 无关，因为它是独立的启动事件）。

## 顺带确认的机制

`display_present` 的 ops 调用（`0x79653c: blr x2`）确实是把 guest 帧放到屏幕的机制
（禁用后 6.0.0 从桌面变黑屏）。也就是说：
**guest 帧大概率一直在被呈现，只是被占位图盖住了。**

## 修复方案（按推荐顺序）

### A. 让 guest 发送 `boot-complete`（最贴近原设计）

1. 把 `tmp/e600_out/system/bin/QemuParams` 放进我们的 `/system/bin/`
2. 补齐它的动态依赖（`libpasteboard_*`、`libdatashare_consumer` 等，
   多数我们镜像里已有，需逐个核对）
3. 让它在开机后运行一次。`QemuParams` 在 6.0.0 里**没有 init cfg 引用**
   （只有 `file_contexts` 的 SELinux 标签），所以它的启动方式还没查清 ——
   可能是 param 触发、或由 hdcd/begetutil 拉起。
   可以先**手动加一个 init job**（如 `post-fs-data` 里 `start` 一个 service）。

### B. 写一个最小 guest 助手（更可控）

只做一件事：打开 `/dev/express_pipe`，向 `boot-params` 管道写 `boot-complete`。
依赖极少（只需 libc + 打开设备）。
管道协议可从 `QemuParams` 逆向（它有 `pipe:%s:%s` / `pipe:%s` 格式串）。

### C. 宿主侧强制撤除占位图（最快验证）

找到 `EmulatorWindowEvent::StopBootAnimation()` 的实现并强制调用，
或让 `OnBootCompleted()` 无条件触发。
**这一步可以先做**，用来验证"撤掉占位图后 guest 帧是否真的显示出来" ——
如果显示，就证明前面所有显示链路都是通的，只剩这一个开关。

> 建议先做 C 验证猜想，再做 A/B 落地成 guest 侧的正规方案。

## 状态

- `sdk/emulator/Emulator`：paint/present **已恢复**（docs/54 的禁用补丁已还原），
  仍带 docs/51 的字段 dump 插桩。原版备份 `tmp/Emulator.before_instr`
- `librender_service.z.so`：原版 + 补丁 1 + 强制 GL 两处 nop（docs/53）
- 6.0.0 的完整文件树已解出：`tmp/e600_out/`（7005 文件），
  `QemuParams` 在 `tmp/e600_out/system/bin/QemuParams`
