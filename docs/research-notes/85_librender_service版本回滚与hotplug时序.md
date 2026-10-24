# 85. librender_service 版本回滚恢复 GL 渲染链 + hotplug 时序规律（2026-10-23 08:20）

## TL;DR

- **画面从全黑 → bootanimation 正常渲染（转圈界面）**：把 system `librender_service.z.so` 换回归档版（md5 `87ccfa650c`，即「手机原版+2补丁」）后，EGL/GL 渲染链恢复，bootanimation 能正常绘制。当前镜像里的 `43a30162df` 版是回归源头。
- **hotplug 时序规律（实证）**：`DoHotPlugCallback` 只在 **composer_host 进程启动时发一次**。RS 若错过就永远无屏（`screenPowerStatus_ is empty`）。**`pkill composer_host` → 它被拉起时重发 hotplug → RS 必收到**（3/3 复现，屏幕 0 注册 1320x2232@60，`Init succeed`）。
- **composer_host 确定性 SIGBUS 已修**（docs/84）：vdi 半成品 patch 残留是元凶，还原干净官方版（`d92ef936`）后稳定。
- 仍未通：DMS 视图 displayId 为空（SSM 回调错过注册窗口）、uinput/aa/uitest 全挂、hdc TCP 转发会整体消失需重启。

## 一、本轮实操验证（用户要求：实际操作判冻结）

| 项目 | 结果 |
|---|---|
| `power-shell wakeup` | **生效**（WakeupDevice is called） |
| uinput 上滑/点击 | **失败**——任意坐标都报超界（MMI 无 displayId，同根因） |
| `aa start` 设置 | **失败**（`error: failed to execute your command`） |
| `uitest dumpLayout` | **超时**（订阅 reply 超时，0 字节） |
| shell/hilog/cloud/samgr | 全部活跃——**系统不是冻结** |

## 二、hotplug 时序规律（本轮核心方法论）

```
composer_host 启动 ──发一次 DoHotPlugCallback──> RS RegScreenHotplug 回调
    （错过 = 永久无屏，直到 composer_host 再次启动）
```

实测序列（hp.log 全程落盘）：
```
DoHotPlugCallback → OnHotPlug(0,1) → ProcessScreenConnected
→ defaultScreenId=0 → add screen 1320*2232 (capability 72*156)
→ SetScreenBacklight level 2279 → Init succeed
```

**操作法**：`hdc shell pkill -x composer_host`，等 6 秒即可。冷启动时 RS 与 composer_host 赛跑，RS 常错过——这就是「冷启动无屏、RS 重启后有屏」的原因。**待修**：把该重发固化进启动脚本（boot-complete 后自动 kill composer_host）。

注意 `TrySimpleProcessHotPlugEvents: isHwcDead_:1` 会先出现，属正常竞态。

## 三、GL 渲染链断点：librender_service 版本

镜像比对（当前 rooted_image vs archive/harmony-p60p-on-emulator/images）：

| 文件 | 当前 | 归档（出桌面） | 判定 |
|---|---|---|---|
| libEGL.so | c35c14421d | 同 | OK |
| libdgles.z.so | eec4af98a9 | 同 | OK |
| libdisplay_composer_hdi_impl_1.3 | 6ee9f6fa68 | 同 | OK |
| libdisplay_composer_proxy_1.3 | 186b081293 | 同 | OK |
| **librender_service.z.so** | **43a30162df** | **87ccfa650c** | **DIFF ← 根因** |

归档 DELTA_MANIFEST 记录该文件为「手机原版 + 2 处补丁」（文档 52：补丁 2 强制 Vulkan 绘制路径）。换回后：
- `LoadEgl Failed` / `eglMakeCurrent is invalid` 消失
- bootanimation 正常渲染（宿主截图可见 HarmonyOS logo + spinner 动画）

**备份**：`tmp/librender_service_current_bak.so`（43a30162df 回归版）、`tmp/librender_service.z.so`（cur）。

### 附：libgralloc_priv.z.so

p60p_tree 有此库但镜像漏打，已补进 vendor（md5 `9d270587…`，导出 `convert_buffer_handle`）。对系统进程仍报 namespace/errno=13（非致命），graphics 域可加载。

## 四、仍未解决

1. **DMS displayId 为空**：RS 有屏 0，但 `TriggerCallbacks: screenChangeCallbacks_.size() 0`——SSM 注册回调晚于 hotplug 事件。待做：等 SSM 注册后再 kill composer_host，或给 RSScreenManager 的回调列表预挂监听。
2. **uinput/aa/uitest 挂**：均依赖 displayId，预计 DMS 通后自愈。
3. **hdc TCP 转发消失**（Emulator 的 5555 监听没了但进程活）：需重启模拟器；guest /data/local/tmp 会被清空。
4. **冷启动时序**：需固化 kill composer_host 到启动流程。
5. **画面停在 bootanimation**：boot-complete 链（QemuParams → /dev/express_pipe → 宿主）需复核——归档 #2 靠它出桌面。

## 五、debugfs 写文件必丢 SELinux 标签（08:40 修，重要方法论）

**现象**：改过 vendor cfg / 库文件后 hdc 的 5555 端口整体消失、guest 转圈卡死、服务起不来，且**回滚内容也没用**。

**根因**：`debugfs -w write` 创建的文件**没有 `security.selinux` xattr**。镜像 SELinux=enforcing（当前态），无标签文件 init 读不了 / dlopen 被拒 → QemuParams/hdcd 起不来 → hdc 转发不建立。

**检测**：`debugfs -R 'ea_list <path>' <img>`——正常文件有 `security.selinux = "u:object_r:xxx:s0"`，debugfs 写入的为空。

**修复**：`debugfs -w -R 'ea_set <path> security.selinux u:object_r:vendor_lib_file:s0' <img>`（etc 文件用 `vendor_etc_file`，system 库用 `system_lib_file`）。本轮修复 4 个文件后 hdc 立即恢复。

**铁律**：今后每次 debugfs 写入后必须 ea_set 补标签 + ea_list 验证。

## 六、SELinux enforcing vs permissive

当前镜像 `SELINUX=enforcing`，归档出桌面版是 `permissive`。enforcing 是用户明确要求的目标态（docs/76），代价是 uinput/aa/dumpLayout 受限更严。后续做 selinux 规则时以此为基线。

## 七、当前断点（08:42 实测）

kill composer_host 后 hotplug 每次必达 RS（屏幕 0 注册 1320x2232、`Init succeed`），但 **`TriggerCallbacks` 从未出现、`screenChangeCallbacks_.size() 0`**——ScreenSessionManager（SA:3299）从不把回调注册到 RSScreenManager，导致 DMS 视图 displayId 为空、snapshot_display 报 `displayId 0 invalid`、uinput/aa/uitest 全挂。

即：**RS 侧有屏，DMS 侧无屏，中间的 SSM→RS 回调注册链断**。下一步应查 SSM 侧为何不调 `AddScreenChangeCallback`（SSM 在 foundation 还是独立进程、它拿到 RS 代理后的注册路径）。

## 八、下一步

1. SSM→RS 回调注册链（当前唯一断点）：抓 SSM 侧日志定位它为何不注册
2. displayId 通后验证 uinput/aa/uitest 自愈
3. 出图后：滑动验证 → 归档
