# 20 - 换图形栈失败的教训与 Vulkan 墙的确认

> 状态：进行中。本轮在 docs/19（present 断点定位）基础上，验证"换 601 模拟器图形栈"这条路，并纠正一个重要的操作错误。

## 一、关键操作错误（教训）：debugfs 路径

**`/lib64/xxx`、`/bin/xxx` 的 debugfs 写入全部无效！** 镜像（system.img）里的真实路径是 `/system/lib64/`、`/system/bin/`（image 根 = guest 的 /system；guest 的 /lib64 是 ramdisk 里指过来的软链）。

- 今天一度用 `/lib64/...` 写的 dfs（swap601 / restore107）**全部没落地**——当时"601 RS 起不来"的结论是**错的**：那次 boot 跑的还是 107 RS，根本没换成。
- 验证方式：改完后 `debugfs -R "dump /system/lib64/xxx" img | md5sum` 对比源文件，必须一致才算落地。
- 正确的 dfs 路径：`/system/lib64/...`、`/system/bin/...`。

## 二、601 整套图形栈替换（真实执行后）的结果：失败，init 整机 reset 循环

把 601 的完整依赖闭包（23 个文件：render_service bin + librender_service(_base/_client) + libcomposer + libvsync + libdvsync + libskia_canvaskit + lib2d_graphics + libhyper_graphic_manager + libcolor_manager + libsocketpair + libcreate_pixelmap_surface + libgraphics_effect + libqos + libmemmgrclient + libconcurrent_task_client + libEGL + libGLESv3 + composer proxies/impl）用 `/system/` 路径真实换入后：

- guest 起来后 **init 判定启动失败，把所有进程 sig 9 杀掉 → sysrq 触发 kernel panic → 整机 reset 循环**。
- 原因（判断）：libskia_canvaskit / lib2d_graphics 这类 Drawing 引擎库是 **server 和全部 UI 客户端（sceneboard/ArkUI）共享**的——换成 601 的之后，107 的 sceneboard/ArkUI 符号对不上 → 整个 UI 栈崩 → 触发 boot 失败 reset。
- 结论：**不能局部换图形栈**。要么整套系统都是 601（那就不是手机 ROM 了），要么不换。已回退到 107 基线（pristine prism 恢复 + 重铺 600 GL 栈）。

## 三、由此坐实的最终结论

**P60P 手机 ROM(107) 的桌面在这台模拟器上起不来，是两堵硬墙叠加：**

1. **Vulkan 墙**：107 的 render_service（DrawableV2 架构）强制走 `RsVulkanContext`（CreateGrContext 无 GL 回退），而模拟器没有任何 Vulkan 驱动（600/601/手机都没有可移植的）。→ RS 渲染引擎起不来（gpuContext=null 每帧刷），渲染树里的显示节点（实测已创建、drawable 也在）从未被绘制 → 永不 present。
   - 且处理器选择走 RSUniRenderProcessor（uni 渲染，需 GPU），不走 RSSoftwareProcessor。
2. **系统服务级联墙**：huks 无 TEE → DeviceManager 拿不到本机 ID → distributeddata 的 KvStore 起不来 → DataShare 服务 proxy 空 → sceneboard 的 SCBScreenSM 卡死（"no left retry times"）→ 不下发 AddDisplayNodeToTree 命令 → 显示节点不挂树。

两堵墙独立存在，修哪一堵都不足以出桌面。

## 四、模拟器能出桌面的对照（为什么 600 行）

600/601 是**模拟器构建**：RS 是老架构（GL、自建屏节点、不依赖 sceneboard 挂树命令、不需要 VK）。手机 ROM(107) 是给真机硬件编的，这些都不成立。

## 五、可行方向（按代价排序）

1. **放弃在模拟器上出手机桌面**，改用模拟器镜像验证上层逻辑（601 基座）。
2. **给 guest 写一个软件 Vulkan 驱动**（SwiftShader/lavapipe 移植到 OHOS musl）——大工程。
3. **二进制手术 107 RS**：把 `RSNormalProcessExecutor::CreateGrContext` 的 VK 调用改成 GL（BuildFromGL），并让处理器走软件路径——深入但局部，不确定性能成。

## 附：本轮工具坑

- debugfs 写镜像必须用镜像内真实路径（/system/lib64、/system/bin），/lib64 是软链不落盘。
- 改大栈后 init 会判 boot 失败整机 reset（kernel.log 里 "send sig 9 to ..." + "sysrq: Trigger a crash"）。
- guest 会约 20 分钟自发冻结（qemu HeartBeat stop），长时间实验要抢在这个窗口内。

## 六、又一个操作教训（冻结根因）

guest 自发冻结（jbd2 D 状态卡住 → 心跳停 → 被杀）的根因：**在 guest 运行时用 debugfs 直接改它正在挂载的基础镜像**（ext4 状态不一致）。规则：改镜像前必须先 `pkill -x Emulator` 停掉 guest，改完再启动。
