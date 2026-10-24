# 89. P60P 桌面无应用图标：根因与 userdata 自动修复（2026-10-24）

## 结论

锁屏后只有壁纸、没有应用图标的问题已解决。最终方案不修改 system/vendor/sys_prod 镜像，也不修改 SceneBoard.hap，而是在启动时检测并修复 launcher 的 userdata 布局数据库。

最终全新 userdata 冷启动已验证：

- 启动脚本自动完成布局修复，无需手工执行 SQL。
- 解锁后第一页显示设置、图库、计算器、日历、时钟、文件管理、备忘录、应用市场。
- 底部 Dock 显示联系人、信息、浏览器、相机。
- 左滑第二页显示主题、音乐、视频、联系人等 20 个应用入口。
- 点击“设置”图标可真正打开设置 APP，不是仅有静态画面。
- `gridlayout_info` 最终为 32 行，三条数据库触发器均保留。
- shell 为 root，SELinux 保持 `Enforcing`。

## 根因分析

这不是 BMS 没有安装应用，也不是 GPU 无法绘制图标。

首次检查时得到：

- BMS `installed_bundle` 有 186 个应用。
- launcher `icon_info` 已缓存 173～178 个应用图标。
- launcher `gridlayout_info` 为 0 行。
- sceneboard 持续打印 `DesktopLayoutCacheData: the gridItemList is invalid`。

干净 userdata 冷启动的 `LauncherStartup` 记录显示，`PERSIST_CONFIG_PAGE` 和 `PERSIST_CONFIG_DB` 已完成，但之后没有完成 `LOAD_CONFIG` 或 `LOAD_DB`。对 SceneBoard 的 ArkTS 字节码检查可见，空数据库分支会注册默认 JSON 布局回调；当前混合镜像的首启过程没有完成该回调和布局落库。后续启动直接读取这个空表，因此桌面一直为空。

修复布局后还发现两个必须同时处理的条件：

1. 手工种入的入口必须填写 BMS 真实的 `appIcon_id/appLabel_id`。只填 bundle/module/ability 会先出现应用名称但图标图像为空。
2. 首次开机应用扫描和图标缓存存在时序。落库后的第一次 sceneboard 重启可能仍只显示名称，等待扫描稳定后再重启一次才完整显示图标。启动脚本因此执行两次延迟刷新，而不是仅凭数据库行数宣布成功。

## 最终文件

- `tmp/seed_launcher.sql`：15 个官方预装应用入口、资源 ID 和 Dock 布局。
- `tmp/seed_launcher.sh`：等待 HDC 和 launcher DB，仅在 `gridlayout_info` 为 0 时修复，校验 15 行种子数据，然后延迟刷新 sceneboard。
- `tmp/run_emu_plain.sh`：启动 Emulator 前，在后台调用上述修复脚本。

SQL 临时移除并恢复三条 `naturalbase_rdb_gridlayout_info_*` 触发器。原因是独立 `sqlite3` 进程没有 SceneBoard 注册的 `get_raw_sys_time()` 等函数，直接 INSERT/DELETE 会失败。脚本执行完毕后三条触发器全部恢复，不是永久删触发器。

非空数据库不会被重写，因此用户后续自行调整桌面不会被启动脚本覆盖。

## 启动与手工恢复

正常启动仍使用：

```sh
tmp/run_emu_plain.sh
```

若需对当前运行的空桌面手工执行一次：

```sh
tmp/seed_launcher.sh
```

日志位于 `tmp/seed_launcher.log`，成功结尾为：

```text
launcher layout seeded
```

脚本会主动执行 `hdc tconn`，清理参数输出中的空白字符，并检查 guest SQL 文件和落库行数，避免 HDC 返回成功但 guest 命令实际失败的误报。

## 验收证据

- `tmp/89_final_coldboot_icons_host.png`：最终全新冷启动，第一页图标和 Dock 完整。
- `tmp/89_final_coldboot_settings_host.png`：本实例点击设置图标后打开的设置 APP。
- `tmp/89_final_coldboot_second_page_host.png`：本实例左滑后的第二页。
- `tmp/89_second_page_guest.jpg`：通过系统截屏功能取得的 1320×2232 guest 原图，与 host 内容一致。

三个分区镜像和 Emulator 的 MD5 与上一版完全一致：

```text
95cc8cfd399291e6a3273dcc7ca0fec2  tmp/rooted_image/p60p_system.img
7ba534406c32ba04bddfe43b2ba4b4f9  tmp/rooted_image/p60pv2_vendor.img
e0d7cf5b622419f7f32a9b69127cca62  tmp/rooted_image/p60pv2_sysprod.img
ace992646a7e0f50c432ba45557fe1ef  sdk/emulator/Emulator
```

## 归档

修复脚本、触控工具、host 截图工具和本文截图归档于：

```text
archive/harmony-p60p-launcher-icons/
```
