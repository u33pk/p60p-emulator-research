# 56. 落地 QemuParams 未生效 —— 需查启动方式

日期：2026-10-21

## 本轮做了什么

按 docs/55 的方案 A 落地：

1. 把 6.0.0 的 `system/bin/QemuParams`（250208 字节，md5 `13b16a8c51`）写进
   我们的 `/system/bin/`，mode 0755，selinux `u:object_r:system_file:s0`
2. 新增 `/system/etc/init/qemuparams.cfg`：

```json
{
    "jobs" : [{ "name" : "post-fs-data", "cmds" : [ "start qemuparams" ] }],
    "services" : [{
        "name" : "qemuparams",
        "path" : ["/system/bin/QemuParams"],
        "uid" : "root", "gid" : [ "root" ],
        "disabled" : 1, "once" : 1
    }]
}
```

3. 删 qcow2 冷启动

## 结果

- 窗口仍是 **42KB 占位图**（未出屏、也未变黑屏）
- 宿主日志只有 `express_pipe.c(dev_read:755) Clean up all existing stale pipes.`，
  **`boot-complete` 一次都没收到**（`grep -c boot.?complete = 0`）
- 之后 hdc 完全卡住，无法进一步确认 guest 侧状态

⇒ **`QemuParams` 没有成功发出 `boot-complete`**。

## 依赖核对（重要更正）

docs/55 里说依赖"多数缺"是**错误**的 —— 那次检查用错了路径。
重新逐个查（`/system/lib64`、`/system/lib64/platformsdk`、`/system/lib64/chipset-sdk`、
`/lib64`、`/system/lib`）后，**全部 18 个依赖都在**，都在
`/system/lib64/platformsdk/` 下：

```
libbegetutil.z.so  libhilog.so  libpasteboard_client.z.so  libpasteboard_data.z.so
libutils.z.so  libconfigpolicy_util.z.so  libcesfwk_innerkits.z.so  libwant.z.so
libzuri.z.so  libability_manager.z.so  libdatashare_consumer.z.so  libsamgr_proxy.z.so
libtime_client.z.so  libsec_shared.z.so  libi18n_sa_client.z.so  libipc_single.z.so
libc.so  libc++.so
```

⇒ 依赖不是障碍，问题在**启动方式或参数**。

## `QemuParams` 的行为（从字符串推断）

```
SystemSetParameter / SetStringValue success, key: %{public}s
boot-complete                    ← 管道消息
bootcompleted                    ← 参数名
pipe:%s:%s   pipe:%s             ← 管道格式
Failed to notify BootComplete.
Failed to notify the image is not build-root.
windowOptions / arkUIOptions     ← 还处理别的 qemu 参数
```

它是一个**多功能助手**（回传 qemu 参数 + 发开机完成通知），
**需要参数指定做什么**（我们用无参启动，可能什么都不做就退出）。

## 下一步

1. **查清 QemuParams 的启动方式与参数**：
   - `strings` 里没有 usage，说明参数是内部约定 —— 需逆向它的 `main()`
   - 或在 6.0.0 的 guest 里实际观察它怎么被拉起（`ps` / init 的 service 列表 /
     `param get` 触发器）
2. **更快的验证路径（方案 B）**：不依赖 QemuParams，自己写个最小助手，
   只做"打开 `/dev/express_pipe`，向 `boot-params` 管道写 `boot-complete`"
   （协议从 `QemuParams` 逆向：`pipe:%s:%s` 格式）
3. **最快的验证路径（方案 C）**：宿主强制 `StopBootAnimation()`，
   先证明"占位图撤掉后 guest 帧就显示出来"。

> 建议顺序：**C（证明猜想）→ B（最小可用实现）**，A 的参数问题可以并行逆向。

## 状态

- 镜像里已加 `QemuParams` + `qemuparams.cfg`（本轮产物，可留可删）
- `sdk/emulator/Emulator`：paint/present 已恢复，仍带 docs/51 字段 dump 插桩
- `librender_service.z.so`：原版 + 补丁 1 + 强制 GL 两处 nop
- hdc 当前不稳定，冷启动后需尽快 tconn
