# 28 — render_service 崩溃根因 + 模拟器稳定性恶化

日期：2026-10-20

## 一、render_service 段错误根因（崩溃转储实证）

从 `/data/log/faultlog/faultlogger/cppcrash-render_service-*.log` 拿到完整栈：

```
Reason: Signal:SIGSEGV(SEGV_MAPERR)@000000000000000000
        probably caused by NULL pointer dereference
Fault thread: Tid:6764, Name:RSUniRenderThre

#00 pc 0000000000000000 Not mapped        ← 调用空函数指针
#01 pc 0x386920 librender_service_base.z.so
        OHOS::Rosen::NativeBufferUtils::MakeFromNativeWindowBuffer(shared_ptr<GPUContext>, ...)
#02 pc 0x385df8 librender_service_base.z.so
        OHOS::Rosen::RSSurfaceOhosVulkan::RequestFrame(...)+1464
#03 pc 0x1e8a98 librender_service.z.so RSScreenRenderNodeDrawable::RequestFrame(...)
#04 pc 0x49bd94 librender_service.z.so RSScreenRenderNodeDrawable::OnDraw(...)+4576
```

崩溃点代码（vaddr 0x386920）：

```asm
0x386908  ldr x8, [x26]        ; 某对象
0x38690c  ldr x8, [x8]         ; vtable
0x38691c  ldr x8, [x8, 0x1b8]  ; vtable[0x1b8] —— 为 NULL
0x386920  blr x8               ; ← 空指针调用，SIGSEGV
0x386924  cbnz w0, 0x386f94    ; 失败分支（打日志后返回）
```

**因果关系**：这是缓冲区分配失败的**下游后果**——
`RequestBuffer` 失败（SELinux 导致 allocator_host 拿不到 fd）后，
`MakeFromNativeWindowBuffer` 仍拿着无效缓冲去调 Vulkan 虚函数（vtable+0x1b8，
推测是 `vkGetNativeBufferPropertiesOHOS` 之类的 OHOS 扩展函数），
该函数指针为 NULL → 崩溃。

崩溃级联：`render_service` SIGSEGV → `allocator_host` 退出 → `foundation` 被 SIGKILL
→ `critical service crashed foundation` → `ExecReboot panic` → 整机重启（即内核日志里的
`sysrq triggered crash`，那是 HarmonyOS 的正常关机流程）。

**修好分配问题就能同时消除崩溃。**

### 防御性补丁（已验证可打，暂回退）

把 `blr x8` 改成 `b 0x386f94`（失败分支），即可避免崩溃、走错误返回：

```
vaddr 0x386920 → file offset 0x385920   （rsb_cur.so 的 .text 段 vaddr-file 差 0x1000）
0xd63f0100 (blr x8) → 0x1400019d (b 0x386f94)
```

验证过可写入镜像，但因模拟器不稳定暂回退（见下）。

## 二、模拟器稳定性恶化（新问题）

现在模拟器**稳定在启动后 ~30 秒被自杀**：

```
crash_server.log:
[Critical] [CrashReportServer.cpp(StartCheckClientHeartbeat:366)]Client heartbeat lost, exit
```

- 可复现（连测 3 次都是 t=30s DEAD）
- **不是**崩溃补丁引起的（回退后一样）
- **不是**宿主资源问题（25Gi 可用、load 0.82）
- 之前（未打 listener 补丁、RS 不渲染时）模拟器能连续跑 8 小时

推测：RS 开始真正渲染后，模拟器的 Vulkan/GPU 转发层被压住，心跳线程饿死。
即 **模拟器的图形转发能力撑不住手机镜像的渲染负载**。

## 三、本轮操作教训

1. **全局 `setenforce 0` 不可取**：加 init 配置在 `post-fs-data` 写
   `/sys/fs/selinux/enforce 0`，会让整个系统行为异常。已移除。
   应改成**只给 `/dev/teleport_express` 换正确的 SELinux 类型**，
   或注入一条 `allow allocator_host dev_file:chr_file { open read write ioctl };`
2. **抓崩溃栈用 faultlog**：`/data/log/faultlog/faultlogger/cppcrash-*.log`
   比 hilog 高效得多，直接给出 PC、寄存器、内存、调用栈。
3. **hilog 动态调日志级别**（比二进制补丁省事）：
   `hilog -T <tag> -b D` 把某 tag 开到 Debug；`hilog --tag=<tag> -x` 过滤。

## 四、当前镜像状态

- `librender_service.z.so` —— listener 补丁（0x39b2b8）**保留**
- `librender_service_base.z.so` —— `VK_OHOS_external_memory` 已还原；
  崩溃防御补丁**已回退**
- `graphic.para` —— `persist.sys.graphic.GpuApitype=1`
- `zz_selinux.cfg` —— **已移除**

## 五、下一步

1. **解决模拟器 30 秒自杀**（当前最大障碍，否则无法验证任何修复）：
   - 对照测试：把 `GpuApitype` 去掉（GL 路径、RS 不渲染）看模拟器是否恢复稳定
   - 若是渲染负载压垮转发层，需要降级渲染路径或限制帧率
2. 稳定后实施 SELinux 正式修复（改设备上下文或注入规则），验证分配成功
3. 分配成功后，若仍有 vtable+0x1b8 空指针，再打防御补丁或补全该函数指针
4. 最后验证桌面出屏
