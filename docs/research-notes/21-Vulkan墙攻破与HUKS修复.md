# 21 - Vulkan墙攻破 + HUKS修复 + 服务级联剩余断点

日期：2026-10-20

## 本轮两大架构级突破

### 突破1：Vulkan 墙攻破（真机 RS 现在能用 GPU）

**之前的错误结论**（见 docs/20）：模拟器全系没有 Vulkan 驱动。**错**。本轮在 `tmp/emu_sys_sub`（OpenHarmony 6.1.1.125 模拟器系统镜像）里发现了华为模拟器**自带的完整 Vulkan 转发栈**：

- guest 侧 ICD：`/system/lib64/libzvulkan.z.so`（Vulkan API 1.3.275），源码 `device/hmos_emulator/hardware/zvulkan/express_vk_*_guest.cpp`
- 传输通道：虚拟设备 **`/dev/teleport_express`**（guest→host 的 express 管道，类比 gfxstream/Venus）
- ICD 注册文件：`/system/etc/vulkan/icd.d/express_icd.arm64.json`

**断点本质**：不是宿主不支持、不是转发不支持，而是我们拼的 p60p guest 里**一个可用 ICD 都没有**——手机 vendor 的 `vulkan.hvgr_v200.so` 要真机 GPU（模拟器里没有），模拟器的 express ICD 又没搬进来。

**修复动作**（3 步）：

1. 把 `libzvulkan.z.so` + `express_icd.arm64.json` 写进 `p60p_system.img` 的 `/system/lib64/` 和 `/system/etc/vulkan/icd.d/`（标签 `system_lib_file` / `system_etc_file`）。
   - 验证：guest 里 `/dev/teleport_express` 本来就在（0666）；`vktest` 建实例成功、枚举 3 个物理设备、扩展齐全（VK_KHR_external_memory*/synchronization2/OHOS_native_buffer 等全有）。

2. **rs_base 字符串补丁**：107 的 `RsVulkanInterface::CreateDevice` 强制请求 `VK_OHOS_external_memory`，而 express ICD 只有 `VK_OHOS_native_buffer` → vkCreateDevice 报 EXTENSION_NOT_PRESENT。把 `librender_service_base.z.so` 里 rodata 0x22d820 的字符串 `VK_OHOS_external_memory` 原地改成 `VK_KHR_external_memory`（更短，带 \0 填充；该扩展 ICD 支持）。实证：harness 里 CreateDevice/CreateSkiaBackendContext 全成功。
   - 注意：该扩展真正用到的函数 `vkGetNativeBufferPropertiesOHOS`/`vkQueueSignalReleaseImageOHOS` 本来就在 ICD 里，改名无功能损失。

3. **librender_service.z.so 分支补丁**：真机 RS 的 `RSBaseRenderEngine::Init` 里，Vulkan 创建路径（0x410570 `GetSingleton`+`CreateDrawingContext`）被 `cbnz w21` 门控——w21 是"EGL 已初始化"标志，但因每次重试都新建 RenderContext 而恒为 0，导致永远不走 Vulkan。把 0x410518 的 `cbnz w21, 0x410570` 改成无条件跳转 `b 0x410570`（机器码 0x14000016）。
   - 实证：改后真机 RS（render_service 进程）的 maps 里出现了 **libzvulkan.z.so**——Vulkan 链路在真机 RS 里活了。

**关键工具/方法**（本轮沉淀）：
- `tmp/ptrace_watch`（guest 里 /data/local/tmp/）：多断点 ptrace 追踪器，命中打印全寄存器+LR 归属库。教训：attach 后必须 CONT 所有线程，否则进程冻结断点永不命中；单步+重放实现连续命中。
- `tmp/rstest3/4/5/6`：直接 dlopen `librender_service_base.z.so` 调 `RsVulkanContext::GetSingleton`/`CreateDrawingContext` 等导出符号，秒级复现 RS 的 GPU 初始化（不用重启 guest）。
- `tmp/dltest`：dlopen 任意 .z.so 验证依赖兼容（用于挑移植库）。
- 手动再跑一个 `/system/bin/render_service`（hdcd shell 里 nohup）可在不重启的情况下复现真机 RS 的初始化日志（`SetUpGrContext drGPUContext is null` 等）。

### 突破2：HUKS 修复（TEE 缺失绕过）

**断点本质**：手机 107 的 HUKS 只带 `libhuks_proxy_1.1.z.so`（转发到 TEE 侧引擎的代理），**没有软件引擎**；模拟器没有 TEE 设备节点 → 所有密钥操作失败 → huks_service 永不注册 SA 3510。

**修复**：从 601 模拟器镜像（`system_6.0.1/system.img`）搬入软件引擎：
- `/system/lib64/libhuks_service.z.so` ← 601 版（dlopen 软件引擎，与 107 ABI 兼容，dltest 验证 OK）
- `/system/lib64/libhuks_engine_core_standard.z.so` ← 601 版（纯 OpenSSL 软件实现，不需要 TEE）
- 注意：6.1.1 版的 libhuks_service 不行——它引用了 107 libipc_single 里没有的符号 `IPCObjectStub::RemoveRefreshRecipient`（版本倾斜），601 版兼容。
- 实证：`GetSystemAbility 3510 is null` / `HksSendRequest fail` 错误消失，`bootevent.boot.completed=true`（首次）。

## 仍然断的级联（桌面没出来的原因）

级联链（自顶向下）：
```
sceneboard 挂树/显示
  ← 需要 DataShare（读 orientation 等设置）
    ← DataShare 服务 = SA 1301 = distributeddata 提供
      ← distributeddata 要本机 UUID（DeviceManagerAdapter::ToUDID）
        ← DeviceManager（SA 4802）要 softbus 出 UDID
          ← softbus_server 框架初始化失败
```

**当前卡点：softbus_server 框架初始化失败**，`CommSvc: InitSoftBusServer# softbus framework init failed, err = -426049501`（0xE69B0023）。
- 伴随：`CommEvent: g_calledApiCntlist is null`、`ReleaseDevUdidInfoNode# device udid list lock fail`。
- **已排除库版本**：把 601 的 libsoftbus_server/libdsoftbus_server_plugin/libdsoftbus_service_ext_frame 整套换入，**故障一模一样** → 是环境性问题（配置/网络接口/内核特性/ffrt），不是库版本。
- 嫌疑：所有进程都有 `ffrt: blockaware init fail ret[22]` + `DelayedWorker monitorfd create failed errno:9/22`——ffrt 的 DelayedWorker 建不出 monitor fd，softbus 的 LooperInit/TimerInit 可能因此失败。需查这个 ffrt fd 问题在 601 模拟器里是否同样存在（区分良性/致命）。

下游表现：
- distributeddata：`InitMetaData: get uuid failed`
- settingsdata：`GetDistributedDataManager failed` → DataShareHelper null
- sceneboard：`SCBScreenSM: init orientation settings DataShare error 15700010` → `no left retry times` → 不下发挂树命令
- 无 launcher 进程；截屏 `Failed to get display pixelMap`（无内容可截）

## 镜像当前状态（tmp/rooted_image/p60p_system.img）

107 原版 + 以下改动：
- `/system/lib64/libzvulkan.z.so`（6.1.1 express ICD）+ `/system/etc/vulkan/icd.d/express_icd.arm64.json`
- `/system/lib64/librender_service_base.z.so`（VK 扩展名补丁）
- `/system/lib64/librender_service.z.so`（0x410518 强走 Vulkan 路径补丁）
- `/system/lib64/libhuks_service.z.so` + `libhuks_engine_core_standard.z.so`（601 软件 HUKS）
- `/system/lib64/libsoftbus_server.z.so` + `libdsoftbus_server_plugin.z.so` + `libdsoftbus_service_ext_frame.z.so`（601 版，无效但无害，可回退）
- 早前：600 GL 栈（libdgles 等）+ 48 个 vendor composer proxies/impl（vblank 补丁）

## 下一步选项

- A. 继续啃 softbus 框架初始化（环境性，需查 ffrt monitorfd / 网络接口 / 配置）。
- B. 给 softbus 预置 UDID 文件绕过生成（若框架 init 不依赖生成过程）。
- C. 评估是否能绕过整条 softbus→DM→distributeddata 链（如直接给 distributeddata 喂 UDID，或 sceneboard 去 DataShare 依赖打补丁）。
