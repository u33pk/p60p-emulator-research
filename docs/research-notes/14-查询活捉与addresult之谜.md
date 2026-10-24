# 14 - 查询活捉与 add-result 之谜

日期：2026-10-18（深夜场）
状态：还原至基线（libhdf_ipc_adapter 换回 107 版 109440 字节，系统稳定）。本轮把查询侧证据链补完，并锁定最后一个待验假设。

## 1. 新证据（early-boot 分片完整捕捉）

对 16:52 基线启动的 T+0 分片（30MB）全文检索：

- `devsvc_manager_stub: StubGetService service display_composer_service not found` —— **查询者包括 samgr/SAMGR 本身**（3 次）、multimodalinput（数十次）、appspawn、sensor/audio/user_auth/light/vibrator/power_host、time_service、deviceauth、netmanager、bluetooth、accesstoken
- `devsvc_manager_stub: add service %{public}s, %{public}d ← display_composer_service` + `servmgr add service, result is %{public}d ← display_composer_service`（composer_host 侧）——**add 与查询在同一次启动都发生了**，result 值是 dict 引用不可见
- RS（render_service）在整个 early 窗口**没有** composer 查询记录——它的查询要么在 hdc 连接前（>25s 丢失），要么走其他路径；multimodalinput/samgr 是主要见证者

## 2. 实验记录（两个失败但排除路线的实验）

| 实验 | 结果 | 排除 |
|------|------|------|
| devmgr GetObject extraKey 比较改 b.al（0xb4d8） | 无显示 | extraKey 闸门不是主因（或该 walk 不在查询路径上） |
| hash 比较整体 nop（0xb4c4/0xb4c8） | 无显示且系统无异常 | 同上——**该 walk 可能根本不是活动查询路径** |
| libhdf_ipc_adapter 换 48 版 | add 日志格式都变了，无法对比，无显示 | 不单独生效（且 107 客户端库混用风险大），已还原 |

注意：后两个实验的"无显示"判定都受 RS 只在启动早期查询一次、事后无重试窗口的限制——**以后所有查询实验必须配合 early-boot 连续 hilog 流或 persist 首分片**。

## 3. 当前最优先假设（未验）

**add-result 误读**：host 侧 publish 返回 0（LaunchNode 未走失败分支，信号陷阱证实），但 servmgr proxy 内部日志 "result is %{public}d" 的 result 值可能非 0（107 客户端解析 48 stub 应答格式错位）。若 result≠0，48 devmgr 可能实际拒绝了 add（名字表里的条目是"查询日志/dict 池"而非活记录——我 ptrace_chain 走到的环可能是某张静态/历史表，不是 GetObject 的 mgr+0x68 活表）。

验证法（下轮第一个动作）：信号陷阱挂在 stub add 的应答写入处 / proxy 的 result 读取处，或直接用 ptrace 在 devmgr add 时读应答码。

## 4. 工具/方法资产

- devmgr 自身日志（devsvc_manager_stub，[nodict]）在**实时 hilog 可见**——host 侧才需要信号陷阱
- 完整查询者名单（第 1 节）说明 composer 是系统级关键服务，修好即全局受益
- 五个 ptrace 工具 + 信号陷阱方法论 + early-boot 分片检索流程全部就位

## 5. 下一步（严格按序）

1. trap "result is" 值：libhdf_ipc_adapter(107) 里该日志点的 result 寄存器落盘（fopen canary 或信号区分）
2. 若 result≠0 → 解析错位实锤 → 修 host 侧 proxy 的应答解析（r2 patch 107 lib）或换 stub 协议对齐
3. 若 result=0 → add 真成功 → 用 ptrace 在查询时刻 diff mgr+0x68 活表头 vs 我的环链表头（确认两张表）
4. 修复后立即验证：snapshot_display 出图 + 桌面截图 + docs 收尾

## 6. 追加（同日深夜）：add 成功日志实证 + 查询者行为

- 16:52 启动分片计数：**add service 成功日志（devmgr 侧）含 display_composer_service 共 4 条**（user_auth 也是 4 条，同型）——**devmgr 的 add 处理走到了成功日志**，add 被接受；同期 not-found 查询 71 条
- kill composer_host 触发 devmgr <13s 重生，但**不引发其他 host 对 composer 的重查询**（b9 分片里 sensor/audio_host 的 composer 查询是一次性开机行为）
- devmgr 主线程在查询洪峰期间仍 parked 于 kevent 等待，IPC 线程处理查询（normal）
- 推论收敛：**add 成功 + 节点在环链 + hash 正确 + 权限有 → 查询必在某处被拒绝**。GetObject 的 walk（0xb44c）是否真是活动查询路径存疑（nop hash 实验无变化）

## 7. 下轮第一动作（三连信号一次性映射查询路径）

devmgr 二进制打三个陷阱一次启动：
1. GetObject 入口（0xb44c）→ udf(4)：查询是否到达此函数
2. walk 命中点（0xb544）→ brk(5)：哪些查询成功（对照时点）
3. not-found 出口（0xb528）→ abort(6)：哪些查询落空

对照 kernel.log 时间戳与 hilog 查询流，一次启动即可判定"查询是否走 GetObject"及"composer 查询死于哪一环"。若查询不走 GetObject → 顺 stub 分发表（0x10018 blr x20 的 jump table）找真正处理器。
