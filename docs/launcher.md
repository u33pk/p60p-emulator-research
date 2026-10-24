# 桌面布局自动修复

## 根因

空桌面时，BMS 已有 186 个应用，`icon_info` 有 173～178 条图标缓存，但 `gridlayout_info` 为 0，SceneBoard 持续报告 `gridItemList is invalid`。因此问题不是应用没安装，也不是 GPU 不绘制图标。

首启默认 JSON 布局回调没有完成落库，后续启动又直接读取空表。只写 bundle/module/ability 名称还会出现“有文字、无图标”，所以种子数据同时填写已核对的 `appIcon_id/appLabel_id`。

## 使用

正常启动时 `run_emulator.sh` 已在后台调用修复脚本。也可手工执行：

```sh
scripts/seed_launcher.sh
```

日志在 `work/seed_launcher.log`。

脚本只处理 `gridlayout_info=0` 的数据库。非空布局直接退出，不覆盖用户调整。成功种入 15 个基础入口后执行两次 SceneBoard 延迟刷新；第二次用于等待应用扫描和图标缓存稳定，不能随意删除。

## SQL 触发器

独立 sqlite3 没有 SceneBoard 注册的 `get_raw_sys_time()` 等函数，因此 SQL 在事务内临时移除三条 NaturalBase 触发器，提交前恢复。它不是永久删除同步触发器。

资源 ID 与具体系统应用构建有关。换 ROM 后需重新核对，不要假定所有版本通用。
