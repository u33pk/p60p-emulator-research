# 11 - ptrace 直击：composer_host 与 devmgr 双双卡在 kevent 等待

日期：2026-10-18（下午场）
状态：根因边界进一步收窄到 **kevent 设备事件流**；自研 ptrace_bt 工具落地，devmgr 文件级金丝雀（open/fopen 可用）是下一步的终局探针。镜像已还原基线（仅保留无害的 canary 驱动字符串补丁）。

## 1. 本场推进（相对 docs/10 的新增）

| 事项 | 结论 |
|------|------|
| VDI 回落猜想 | **证伪**：6.0 真机与 6.0 模拟器的全部 RS/HDI 库均无 `libdisplay_composer_vdi_impl`/回落代码串（v1 的回落是 6.1 特性）。"改名逼回落"路线放弃 |
| 自研 ptrace_bt | 用 SDK ohos clang 静态编译（tmp/ptrace_bt.c），可在 guest 抓任意进程每线程的 pc/lr/FP 回溯。已推送 /data/local/tmp/ptrace_bt（v2 和 600 的 userdata 各自独立，跨实例需重推） |
| composer_host 主线程栈 | `futex ← libhdf_utils(+0xb75c 区, fcn.0xb62c: ioctl 0x6201 重试循环) ← +0x8058 ← hdf_devhost main`。即**卡在 HDF kevent 等待**，"hdf device host start" 日志（在 kevent 等待之前）从未出现 |
| devmgr 主线程栈 | **与 composer_host 完全同款**（hdf_devmgr+0x4244 → libhdf_utils 同一路径 → futex）。另有 DevMgrUevent 线程（uevent 循环，正常）。IPC 线程在 binder 循环正常服务 |
| libhdf_utils 版本实验 | 换 48 版 utils：**卡点在 48 版的等价位置**（偏移 0x42ac/0xb75c/0x8058）→ 排除版本错配，是"事件流本身不来" |
| 关键事实重估 | vdi_impl/vendor_composer 在 maps ≠ Bind 跑过：hdf_devhost 启动时预载全部模块驱动（含其依赖链），所以"驱动已加载"不能证明 AddDevice 执行。AddDevice 的一切错误/launch 日志全零 + 主线程卡在 kevent 等待 = **设备事件从未到达此 host** |
| hilog 静默之谜 | composer_host 进程从零日志（含 host-start）：hilog 调用本身不阻塞（fire-and-forget），执行继续到 kevent 等待。pipe 是否已死不影响结论；render_service 也仅一条 hilog 规则（经 base_typeattr_52 全员放行），权限层面未见缺口 |

## 2. 现在的根因表述（最精确版本）

```
600（健康）:  host 附加 → devmgr 发 kevent 设备事件 → host 唤醒 → AddDevice→Bind→VDI→hotplug 轮询 → 服务注册 → RS → 桌面
v2（病）:    host 附加（?）→ devmgr 从未发出 composer 设备的 kevent 事件 → host 主线程永久 kevent 等待
             → 无 AddDevice/Bind/服务/hotplug → RS 无屏 → 永远转圈
```

未知点只剩一个：**devmgr 在把 display_composer 设备事件发往 host 11 的决策上发生了什么**。其它 17 个 host 能收到各自设备事件（12:49 启动时 user_auth/sensor/camera 等服务注册成功=它们走到了 PublishService），唯独 composer 收不到。

## 3. 下一步（终局探针，按序）

1. **devmgr 文件级金丝雀**：devmgr 二进制导入了 `open/fopen/access/write`，r2 在设备派发循环（0x7f64-0x7fbc）挂 fopen 标记文件（如 /data/local/tmp/disp_<hostName>），一次开机直接看到 devmgr 对 composer_host 的决策（发了/没发/跳过 preload 判断）。此法完全不依赖 hilog。
2. devmgr IPC 线程的 ptrace 时序：composer_host kill 触发 devmgr 重生+重派发的瞬间连抓 IPC 线程栈（机会窗小，备选）。
3. 若 devmgr 决策显示"已发送"→ 转向内核 hdf_kevent 驱动事件投递路径（host id 匹配过滤？）；若"未发送"→ 看 devmgr 设备表为何缺 composer（hcb 解析分支，r2 已定位 preload 校验代码 0x7f7c-0x7fa0）。

## 4. 操作纪律（新增）

- ptrace_bt 使用方法：`hdc file send tmp/ptrace_bt /data/local/tmp/ptrace_bt; chmod 755; /data/local/tmp/ptrace_bt <pid>`（每次新实例要重推；600 非 root 不可用）
- kill composer_host 安全（devmgr <13s 重生）；**kill render_service 依然绝对禁止**（graphic.cfg 连锁 reset foundation → 4 崩 → sysrq panic）
- 换库实验必须伴随 ptrace_bt 验证卡点是否移动，否则版本无关的假设会浪费一整轮（本轮教训）

## 5. 当前镜像状态

- p60p_system.img = 基线（libhdf_utils 已还原 107 版 101928 字节）
- p60pv2_vendor.img = 基线 + canary 驱动（drv10_canary.so：Bind 串改 DriverBinK 等，行为不变）
- tmp/ptrace_bt.c / ptrace_bt 为本场新工具资产
