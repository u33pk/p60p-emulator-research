# SELinux 与 root

## 当前安全状态

`getenforce` 返回 `Enforcing`，HDC shell 返回 `uid=0`，`/data` 可读写。但这不等于所有域都在 enforcing。

最终策略中以下六个域单独 `typepermissive`：

- `sh`、`hdcd`：研究用 root shell；
- `ueventd`：避免冷启动重扫崩溃导致设备节点和 access-token 连锁失败；
- `composer_host`、`display_engine_service`、`allocator_host`：显示链兼容。

`render_service` 不在这份 permissive 清单中；其 EGL 标签和 `dev_file.map` 已单独修复。公开描述时应准确说“全局 Enforcing + 指定域 permissive”。

## 关键规则

- QemuParams 使用完整 `emu_param` 域，不存在该类型时，即使全局 permissive 也无法 setexeccon；
- `/dev/express_pipe`、QemuParams 可执行文件和 qemu 参数需要配套标签；
- render_service 对 `dev_file` 的字符设备权限包含 `map`；
- debugfs 写回后恢复 exec、库和配置文件各自的 SELinux xattr。

## root HDC

`ohos.para` 使用 `const.secure=0`、`const.debuggable=1`，HDC 服务定义以 root 运行并设置 `secon=u:r:hdcd:s0`。配置见 `configs/hdcd.root.cfg`。

这会显著降低系统安全性。不要将该实例用于生产账号、支付、未审核应用或敏感数据。permissive 域也应在后续研究中继续收紧，而不是当作理想终态。

## 常见误判

- `id` 是 root，不代表 SELinux 允许访问所有目录；
- 全局 Enforcing，不代表每个域都 enforcing；
- root shell 能加载库，不代表 render_service 域也能加载；
- 没打印 avc，不代表没有拒绝，dontaudit 和日志限流可能隐藏问题。
