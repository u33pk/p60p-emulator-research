# 74. ohos.boot.hardware 注入链路 + kirin9000s patch + 显示不稳定诊断

日期：2026-10-22

## 一、`ohos.boot.hardware` 为什么是宿主机注入的

完整链路（已逆向定位）：

```
Emulator 二进制硬编码 token  →  QemuParameters.cpp 拼 cmdline  →  QEMU -append
        →  guest /proc/cmdline 的 hardware=xxx  →  param 守护进程写成只读参数
```

- `sdk/emulator/Emulator` 数据段硬编码两个 token：
  - `0x43c2e08`：`hardware=hmos.emulator `（24 字节槽，结尾空格 + NUL）
  - `0x43c2e20`：`hardware=ohos.emu.arm `（另一架构变体）
- 选择逻辑（`0x1099b54` 起）：
  `if (os.apiVersion >= 12 && hdc.mode.bridge == "on") → hmos.emulator，否则 → ohos.emu.arm`
- cmdline 是 **token 拼接**（std::string，非定长 memcpy），主拼接函数 `0x1099b18`，
  由 QEMU argv 组装 `0x10974f8` 调用，结果作 `-append`。
- guest 侧 `param set ohos.boot.hardware` 报 `errNum 107`（只读），**运行时改不掉**。

**config.ini 没有任何能直接设 hardware 值的键**（可识别键约 40 个：
`deviceModel/productSeries/vendorCountry/uuid/os.apiVersion/hw.cpu.arch/hw.lcd.*` 等，
无 `hardware/kernelArgs/append/cmdline`）。唯一杠杆是把 `os.apiVersion` 改成 <12 切到
`ohos.emu.arm` 分支，但仍是模拟器标记且会丢 `qemu.dpi`/`cutoutPath`，无用。

其余同源于 cmdline 的注入项（都有 config.ini 键，不用 patch 二进制）：
`devmodel=`←`deviceModel`、`const.build.product=`←`productSeries`、`vendorcountry=`←`vendorCountry`、
`ohos.boot.udid=`←`uuid`、`ohos.boot.qemu.dpi=`←`hw.lcd.density`、
`const.product.{device,real_device}_radius=`←`hw.{device,realDevice}.radius`。

## 二、patch 方案（两步必须一起，否则启动失败）

**第 1 步 patch 二进制**（槽位 24 字节，新值 + NUL ≤ 23 字符，须保留结尾空格）：
```
0x43c2e08: "hardware=hmos.emulator " → "hardware=kirin9000s "
```
真机 hardware 名 = `kirin9000s`（证据：真机 vendor 有 `init.kirin9000s.cfg`/`fstab.kirin9000s`）。
patch 后 md5 `e98afe0b3cddc140d90861243808f3f0`，备份在 `tmp/Emulator.kirin9000s`。

**第 2 步 vendor 镜像补同名 cfg**（`ohos.boot.hardware` 是 init 变量替换键，
启动时加载 `/vendor/etc/init.${ohos.boot.hardware}.cfg` 并挂 `/vendor/etc/fstab.${ohos.boot.hardware}`）：
```
init.hmos.emulator.cfg      → init.kirin9000s.cfg
init.hmos.emulator.usb.cfg  → init.kirin9000s.usb.cfg
fstab.hmos.emulator         → fstab.kirin9000s
```
（内容原样复制即可，模拟器 vendor 的 cfg 内容本来就适配这套环境。）

**验证**：`param get ohos.boot.hardware` = `kirin9000s`，`/proc/cmdline` 含 `hardware=kirin9000s`，无崩溃。

## 三、A/B 对照：kirin9000s 与「卡开机动画」无关

| 轮次 | 二进制 | vendor | userdata | 结果 |
|---|---|---|---|---|
| 1 | kirin9000s | +kirin9000s cfg | fresh | 卡动画 |
| 2 | hmos.emulator | +kirin9000s cfg | fresh | 卡动画 |
| 3 | hmos.emulator | 已清理 | fresh | 卡动画(200s) |
| 4 | hmos.emulator | 已清理 | warm(承3) | 卡动画(900s) |
| 5 | hmos.emulator | 已清理 | fresh | **桌面正常** |

结论：kirin9000s / vendor cfg / fresh/warm userdata **都不是**卡动画的原因。

## 四、显示不稳定的根因（比 docs/72 更深一层）

卡动画时 guest 侧实测：
- `bootevent.boot.completed=true`、`bootevent.bootanimation.finished=true`，bootanim 进程已退
- sceneboard 在跑、无崩溃，窗口管理器有 31 个窗口（锁屏 `SCBScreenLock11` 已聚焦 z=2000）
- **但 RenderService 图层树只有 ScreenNode + FrameBuffer 两个 surface**
- `hidumper -s RenderService -a nodeNotOnTree`：**24 个 sceneboard surface 建了没挂树，
  `usedBufferListLen=0`（从没往里画过内容）**
- 宿主侧 glshim 的 boot-complete 已触发（`BOOTFIX: done`）、glReadPixels 在做，但接近停滞

即：**宿主进了 live-present，但 guest 的 sceneboard 没把桌面帧交给合成器**，
窗口永远停在 boot 占位图（HarmonyOS logo + 转圈）。

`QemuParams`（guest 唯一发 boot-complete / 处理显示参数的组件，`/system/bin/QemuParams`）
**启动后随即退出**（`startup.service.ctl.QemuParams-*.pid` 全是死 pid）。docs/71/56 已记。
host 侧 glshim 强制 boot-complete 是**时机敏感**的（docs/71 第五节：过早/过晚/重复都有害），
这是出屏不稳定的根源。

## 五、当前恢复态（归档 #1 对应状态）

- 二进制：原版 `hmos.emulator`（md5 `ace992646a7e…` = `tmp/Emulator.before_instr`）
- vendor：kirin9000s cfg 已清理
- 出屏验证：`screenshots/74_desktop_clean.png`（204KB，设置/图库/状态栏/壁纸齐全，
  uinput 滑动交互实时响应）
- 身份：ALN-AL00 / HUAWEI Mate 60 Pro（保持 docs/73 成果）

## 六、遗留：稳定复现的方向

host 强制 boot-complete 不稳。根上的修法是**让 guest 自发 boot-complete**：
1. 修好 `QemuParams`（查清为何启动即退出），或
2. guest 侧写最小助手往 `/dev/express_pipe` 的 `boot-params` 管道写 `boot-complete`
   （`/dev/express_pipe` 已确认存在，char 10:54）
