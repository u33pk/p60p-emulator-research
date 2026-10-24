# 78. 里程碑：画面冻结根因定位 = RS 硬依赖 chipset_vsync_service（2026-10-22）

## 本轮验证链（全部实测）

1. **排除"虚拟机卡死"**：guest 内核/服务/sceneboard 全活（docs/77）
2. **排除 transform_type 8**：官方镜像同样报该错误但持续出帧（错误罕见且非致命）
3. **对照实验（决定性）**：官方 6.0.1 镜像（tmp/deployed + tmp/image_root, HarmonyOS_Phone）
   - 锁屏时钟实时走动（04:31→04:33→04:34）→ present 管线完全正常
   - guest 内 `uinput -T -g` 滑动**解锁成功**进入桌面 → guest 内注入链路完全正常
   - 宿主 XTEST 鼠标拖拽/点击/按键 **无反应**（与镜像无关的宿主侧问题）
4. **P60P 冻结根因**：`hilog -b D` 后触发 suspend，RS 日志爆出：
   ```
   hdf_devmgr: StubGetService service chipset_vsync_service not found
   render_service/hdi_servmgr_client: get hdi service chipset_vsync_service failed, -1
   render_service/chipset_vsync_host_proxy: Get:get remote object failed!
   ```
   - RS（VSyncGenerator 线程 futex 空转）拿不到硬件 vsync → 无人调度帧 → 锁屏时钟冻结
   - 合成器仍按 ~10Hz 重提交旧图层（teleport 消息流持续、wchar 微增），所以画面是"旧帧重绘"而非黑屏

## 深入结论

- `chipset_vsync_service` 属 `OHOS::HDI::Camera::ChipsetVsync::V1_0/V1_1` 命名空间——真机上由麒麟芯片相机/ISP 组件注册（RS 日志中 Client 侧有 `chipset_vsync_service get failed and Timeout. Stop get` 字样）
- **全文件系统搜索确认**：P60P 组合镜像（system+vendor）里没有任何组件注册该服务（真机依赖的芯片闭源组件不在 ROM dump 里）
- 官方 6.0.1 镜像连 libchipset_vsync 都没有（RS 是标准模拟器构建，走 composer HDI vsync）
- 换库实验：vendor 显示合成/缓冲 8 个库换成官方版（md5 校验生效）→ 服务依然未注册（进一步证明注册者不在这些库）
- 版本差距：P60P = 6.1.0.126/api24，官方模拟器 = 6.0.0.48/api20 → **不能**换 RS 栈（ABI 赌博），只能给 P60P 补服务
- `persist.sys.graphic.vsyncControlEnabled` 属性开关实测无效

## 接口规格（已从 libchipset_vsync_proxy_1.0/1.1 符号表提取，供实现参考）

客户端→服务（proxy）：`SetCallback(cb)` / `SetCallback_V1_1(cb, extraObj?)` / `GetVersion(&maj,&min)` / `Reconnect`
服务→客户端（callback stub 解析）：`GetVsyncInfo(RSVsyncInfo)` / `VoteFrameRate(int)` / `GetVersion`
- 库文件（P60P system 自带客户端全套）：`/system/lib64/libchipset_vsync.z.so`、`libchipset_vsync_proxy_1.0/1.1.z.so`
- RS 侧入口：dlopen libchipset_vsync.z.so → `InitChipsetVsyncImpl` / `SetVsyncImpl`
- SELinux 已就绪：`/vendor/etc/selinux/targeted/contexts/hdf_service_contexts` 里有 chipset_vsync_service 标签

## 修复方案（下一步）

实现一个 fake `chipset_vsync_service`：独立 native 守护进程，hdi servmgr 注册该服务名，60Hz 定时器驱动回调（GetVsyncInfo 喂时间戳 / VoteFrameRate）。需要：
1. objdump 逆向 proxy 提取确切 IPC 码 + MessageParcel 布局（SetCallback_V1_1_ @0x9dcc、CallbackStub::OnRemoteRequest @0x7b94 等）
2. aarch64 OHOS  musl 编译（sdk toolchains 有 clang）
3. init cfg 接入 + cil 加注册/通信 allow 规则
4. 验证：时钟走动 + 解锁进桌面 + 画面持续刷新

## 遗留问题清单（更新）

| 问题 | 状态 | 备注 |
|---|---|---|
| present 冻结 | 根因已定，待实现 fake 服务 | 本轮核心成果 |
| 宿主鼠标输入 | 两镜像都不通，宿主 Emulator 输入转发问题 | 与镜像无关，优先级可后置（guest 内 uinput 可替代） |
| P60P guest 内 uinput 被吞 | 待查（官方上可用，shell 用户就行） | 可能随 vsync 修复自愈（UI 不渲染时注入无视觉反馈但 MMI 也没日志） |
| guest 截图黑屏 | 已知无害 | capture 缓冲不一致 |
