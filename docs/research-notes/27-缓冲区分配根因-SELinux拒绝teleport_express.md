# 27 — 缓冲区分配根因：SELinux 拒绝 allocator_host 访问 teleport_express

日期：2026-10-20

## 结论（本里程碑）

**缓冲区分配失败的根因找到了**：SELinux 拒绝 `allocator_host` 打开
`/dev/teleport_express`。

```
avc:  denied  { read write } for pid=663 comm="OS_IPC_1_680"
  name="teleport_express" dev="tmpfs" ino=249
  scontext=u:r:allocator_host:s0
  tcontext=u:object_r:dev_file:s0
  tclass=chr_file  permissive=0
```

- 主体：`u:r:allocator_host:s0`（`/vendor/bin/hdf_devhost`，HDF 分配服务）
- 客体：`/dev/teleport_express`，类型是**通用的 `dev_file`**
- 拒绝的操作：`chr_file` 的 `read write`

反汇编证实失败点就是 `open()`：`ExpressAllocMem` 在 0x2dd4 `__open_chk` 后
0x2ddc `tbnz w0, 0x1f, 0x2e74`（fd 为负即跳错误分支），
0x2e74 就是打 `teleport_express can not get fd %d error %d!` 的地方
（`mov w6, 0xfb` = 源码行号 251）。

`error 0` 是栈槽位为 0（`str wzr, [sp]`），不是 errno——所以看起来"没错误却拿不到 fd"。

## 方法：用 hilog 动态调日志级别（比二进制补丁省事）

vendor 的 `ExpressAllocMem` 本来就有请求参数日志，只是 Debug 级默认不打：

```
hilog -T DISP -b D        # 把 DISP 模块的日志级别设为 Debug
hilog --tag=DISP -x       # 只看该模块
```

抓到的分配请求：

```
[ExpressAllocMem:236] ExpressAllocMem requeset width 1320, heigt 2232, format 12, usage 708
[GetFormatPixelSize:147] fmtIn 12 : PIXEL_FMT_RGBA_8888, outFmt 4
[ExpressAllocMem:251] teleport_express can not get fd -1 error 0!
```

即 **1320x2232 RGBA_8888，usage=0x708**（hex）。请求本身完全正常，
不是格式/尺寸/usage 标志位被拒——就是打不开设备。

## 佐证

- `/dev/teleport_express` 存在，`crw-rw-rw-`，SELinux 上下文 `u:object_r:dev_file:s0`
- 同一时刻**只有 render_service 打开着该设备**，allocator_host 一个也没打开
- render_service 能打开，allocator_host 不能 —— 与 SELinux 域差异一致
  （render_service 的域有该权限，allocator_host 的域没有）

## 未决问题

`setenforce 0` 后的复测**没有干净地做完**（guest 因 foundation 被反复 SIGKILL
而重启，日志采集时序错位）。需要一次干净验证：

1. 启动后**立即** `setenforce 0`，再开 `hilog -T DISP -b D` 抓分配日志；
2. 若分配成功（`express init gbuffer id ...` 出现、`OnDraw` 不再报错），
   即可确认 SELinux 是唯一原因，再做正式修复；
3. 若仍失败，则要查设备是否独占（render_service 已占用）等次级原因。

## 修复方向（按推荐顺序）

1. **改设备节点的 SELinux 上下文**（最干净）：给 `/dev/teleport_express` 一个
   `allocator_host` 有权限的类型（参考 600/601 模拟器镜像里该设备的上下文，
   或看 vendor 的 ueventd/sepolicy 里 HDF 设备的通用类型）。
   可在 vendor 镜像的 ueventd.config 里加条目，或启动脚本里 `chcon`。
2. **注入 SELinux 允许规则**：`allow allocator_host dev_file:chr_file { open read write ioctl };`
   加进 vendor 的 sepolicy CIL（用户此前明确接受"注入 selinux 规则"）。
3. **临时方案**：开机即 `setenforce 0`（模拟器测试环境可接受，但不干净）。

## 附带发现：foundation 被 SIGKILL 的不稳定

日志里 foundation 反复 `exit with signal : 9`（pids 5923/6406/6770），
每次随后 `critical service crashed foundation` → `ExecReboot panic` → 整机重启。
**不是 foundation 自己段错误，是被 SIGKILL**，且没有 OOM 记录。
时间上与 composer_host 重启相邻（`on-restart: services:restartrender_service`
→ `reset composer_host` 的级联）。这是独立的稳定性问题，与缓冲区分配无关，
但会打断调试，需要留意。

## 当前镜像状态

- `librender_service.z.so` —— listener 补丁（0x39b2b8）保留
- `librender_service_base.z.so` —— `VK_OHOS_external_memory` 已还原
- `graphic.para` —— `persist.sys.graphic.GpuApitype=1`
- `chipset-sdk/libdisplay_buffer_*` —— 手机原版（上轮实验已撤销）
