# 故障排查

## HDC 不通

检查 Emulator 是否仍运行、端口是否与 `P60P_HDC_PORT` 一致，以及 hdcd 是否因丢失 `hdcd_exec` 标签而无法 exec。修改基镜像后还要确认没有继续启动旧 qcow2 覆盖层。

## 一直显示开机动画

按顺序检查：

1. composer_host 是否就绪；
2. render_service 是否加载唯一的 DGLES 实现；
3. `/dev/teleport_express` 是否可 mmap；
4. SceneBoard/WMS 是否完成；
5. `bootevent.boot.completed` 是否为 true；
6. QemuParams 是否运行并通过 `/dev/express_pipe` 发出 boot-complete；
7. host 日志是否收到 Guest OS Boot Completed。

不要先用 host 强制 boot-complete 掩盖 guest 未就绪，否则会引入新的时序问题。

## 黑屏或 EGL_BAD_SURFACE

检查四个 impl 链接及其 SELinux 标签、render_service 实际 maps、图形缓冲尺寸和 `dev_file.map`。分配成功但 mmap `Permission denied` 是策略问题，不是显存不足的直接证据。

## 启动后 critical panic

检查 hdf_devmgr、hdcd、QemuParams 等文件标签，以及是否把真机专用图形参数全部搬到模拟器。critical 服务退出会引发整机 panic，应找最早失败的组件，而不是只看最后一条 reboot。

## 解锁后没有图标

执行 `scripts/seed_launcher.sh`，检查 `work/seed_launcher.log` 和 `gridlayout_info`。如果表非空但仍无图标，应检查资源 ID、icon_info 和 SceneBoard 日志，脚本不会覆盖已有布局。

## 截图正常但无法操作

实际检查 event 设备编号、ABS 范围和 guest 坐标。用电源键、上滑和打开设置分别验证，避免把静态帧、显示冻结和输入失败混为一谈。

## 账号异常

抓取 `hilog -x`，先确认 HWID 是否 auth success，再看 OUCS、attestation、TSMS 和风险检测。不要用网络代理反复重试来掩盖本地凭证缺失。
