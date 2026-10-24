# 75. 稳定出屏 —— guest 自发 boot-complete（退役 host 强制触发）

日期：2026-10-22　**结论：出屏从「偶发」变为「稳定自动」**

## 一、为什么之前不稳定（docs/72 的 host 强制方案是治标）

docs/72 的出屏靠 host 侧 LD_PRELOAD glshim 在 150s 强制补发 boot-complete。
这是**时机敏感**的（docs/71 第五节：过早/过晚/重复都有害），实测会偶发
「卡在开机转圈、桌面不出帧」（sceneboard 的 surface 建了但没挂渲染树、0 buffer）。

根因：guest 从不自发 boot-complete，宿主只能靠猜。guest 不发的原因 = `QemuParams` 没跑起来。

## 二、QemuParams 跑不起来的两层根因（全部定位并修复）

`QemuParams` 是 guest 里唯一通过 `/dev/express_pipe` 给宿主发 `boot-complete` 的组件。
官方 vendor cfg `/vendor/etc/init.hmos.emulator.cfg` **本来就带**正确配置
（4 个服务、触发条件 `bootevent.boot.completed=true`），但跑不起来，两层原因：

### 根因 1：SELinux secon 类型不存在（exec 前就死）

```
ServiceStart started info QemuParams-bootcomplete(pid 18673)
[PLUGIN][ERROR] selinux_adp.c:79 Service error 22 ... failed to set secon u:r:emu_param:s0
Child process QemuParams-bootcomplete(pid 18673) exit with code : 21
```

cfg 里 4 个 QemuParams 服务都写 `"secon":"u:r:emu_param:s0"`，而 `emu_param` 类型
在**真机 SELinux 策略里不存在**（官方 6.0.1 system.img 有 58 处 emu_param 定义，
真机 p60p_system.img 有 0 处）。`setexeccon` 即使在 permissive 下也要校验类型存在，
返回 EINVAL，init 子进程 `_exit(21)`，**exec 从未发生**。

**修复**：`p60pv2_vendor.img` 的 `/etc/init.hmos.emulator.cfg`，4 个服务的
`secon` 由 `u:r:emu_param:s0` 改为 `u:r:limit_domain:s0`（真机策略已有该类型，
setexeccon 成功；permissive 下权限不挡）。

### 根因 2：P60P 的 QemuParams 二进制与系统库不匹配（exec 后也死）

SELinux 修好后 exec 能跑了，但立刻：

```
Error relocating /system/bin/QemuParams: _ZN4OHOS5AAFwk20AbilityManagerClient11KillProcessE...: symbol not found
Error relocating ... IPCObjectStub::AddRefreshRecipient ...: symbol not found
Error relocating ... MiscServices::PasteboardObserver::OnPasteboardEvent ...: symbol not found
exit=127
```

P60P ROM 的 QemuParams（250208 字节）是**较新版本**，链接的符号在当前系统库里没有。

**修复**：把 `p60p_system.img` 的 `/system/bin/QemuParams` 换成**官方 6.0.1 版**
（92960 字节，只依赖 libbegetutil/libhilog/libpasteboard_client/libc/libc++，
这些库真机系统里都有、符号齐全）。备份原版在 `tmp/QemuParams_p60p_orig`。

## 三、修复效果：guest 自发 boot-complete，全自动出屏

冷启动后**零干预**：
- init 在 boot 阶段自动起 `QemuParams boot-params`（设显示参数 dpi/cutoutPath 等）
- `bootevent.boot.completed=true`（init 内建 bootevent 机制，各服务声明的就绪事件
  全部 posted 后自动置位）触发 job → 起 `QemuParams boot-complete`
- QemuParams 走 `isNotPublic → isNotBuildRoot → bootcompleted` 握手，
  写 `/dev/express_pipe` 的 `boot-complete` 通道
- 宿主 `BootCompletePipeClientRecv` 收到 → 撤占位图、进 live-present → 桌面出屏
- 之后 QemuParams 进 3s 心跳循环长驻

**全程不需要 host 侧 glshim 强制 boot-complete**（glshim 退役，启动用 `run_emu_plain.sh`）。
锁屏时钟与 boot-complete 接收时刻一致，证明「guest 一就绪就发、宿主随即呈现」，无赛跑。

## 四、改动清单（本归档 #2 新增）

| 文件 | 改动 | md5 |
|---|---|---|
| `images/p60p_system.img` | `/system/bin/QemuParams` 换成官方 6.0.1 版（0755） | 见 DELTA_MANIFEST |
| `images/p60pv2_vendor.img` | `init.hmos.emulator.cfg` 4 个 QemuParams 服务 secon→limit_domain | 见 DELTA_MANIFEST |

启动脚本：`tmp/run_emu_plain.sh`（无 glshim，纯净）。

## 五、boot-complete 消息协议（备用，来自 QemuParams 逆向）

```
fd = open("/dev/express_pipe", O_RDWR)
write(fd, "pipe:qemud:boot-complete\0", 24)     # attach 通道（带 NUL）
# 之后每条消息 = 4字节ASCII小写hex长度 + payload，期望回 "ok"
send(fd, "000b" + "isNotPublic")
send(fd, "000e" + "isNotBuildRoot")
send(fd, "000d" + "bootcompleted")              # 关键
# 常驻：每 3s 发 "0005" + "alive" 心跳
```

## 六、稳定性验证（已实测）

连续 **3 轮冷启动**（每轮删 qcow2 重来、用 `run_emu_plain.sh` 无 glshim），全部自动出桌面：

| 轮次 | guest 自发 boot-complete | 桌面出屏 | 锁屏 PNG |
|---|---|---|---|
| 1 | 90s | ✓ | 224KB |
| 2 | 100s | ✓ | 223KB |
| 3 | 90s | ✓ | 223KB |

**3/3 通过**。boot-complete 时机稳定在 90~100s（guest 就绪即发），不再需要 host 强制。
（测试脚本 `tmp/stability_test.sh`；注意：判据要看 PNG 压缩后大小 >100KB，
PPM 原始尺寸恒为 ~1.45MB 不能作判据。）

对比修复前（host 强制触发）：同一组合曾连续 4 轮卡开机动画（见 docs/74 第四节）。
修复后 3/3 稳定，证明根因确实是「guest 不发 boot-complete」，而非镜像/参数/hardware。

## 七、遗留

- guest 侧 `snapshot_display` 仍全黑（capture 与呈现缓冲不一致，不影响出屏）
- 锁屏静止时时钟不主动刷新（交互后立即刷新）——这是 render 端 Commit 门控，与 boot-complete 无关
