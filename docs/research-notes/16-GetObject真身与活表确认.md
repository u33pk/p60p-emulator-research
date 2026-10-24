# 16 - GetObject 真身与活表最终确认

日期：2026-10-18（深夜二场）
重大纠偏 + 重大确认：

## 1. 符号大纠错（此前分析张冠李戴）

跳板表（0x11a40）解码揭穿：
- **0xb44c = DevSvcManagerRemoveService**（摘除+释放节点！）——我之前反编译的"hash 查询 walk"其实是**删除服务**的代码
- **0xb428/0xb42c = DevSvcManagerGetService**（24 字节：调 GetObject 返回 [record]）
- **0xb348 = DevSvcManagerGetObject 真身**（真正的查询 walk，结构与 Remove 类似但**返回 node->extraKey（+0x18）**，不做 extraKey 比对）
- 查询真实路径：dispatch(0xffe8 `blr [x19+0x38]`=跳板表基址→entry0=GetObject) → GetObject(hash walk mgr+0x68) → GetService([record])

之前对 0xb44c（Remove）做的 almatch 实验因此无效（该函数不在查询路径）。blr x20 陷阱（0x10018）是**第二分发**（[x19+0x10] 按码索引 Add/List 等），第一分发在 0xffe8。

## 2. 活表最终确认（铁证）

- DevSvcManagerGetInstance 全局单例：[devmgr基址+0x14758] = mgr = **0xa8066960**
- **mgr+0x68 = 0xa80669c8 = 我用 ptrace_chain 走过的环链表头**（低 32 位 80669c8 完全吻合）
- composer 节点（hash=0x0babe50f）此刻**就在这张活表里**，环完整，x18/x20 指针有效
- RemoveService 理论排除：稳定运行 10+ 分钟后节点仍在（若被死亡摘除会消失）

## 3. 已排除清单（全部实测）

| 环节 | 结果 |
|------|------|
| add | devmgr 成功日志实证（4条） |
| 节点入活表 | ptrace 铁证（mgr+0x68 环中） |
| hash 正确 | 手算 h131&0x7fffffff = 节点值 |
| GetPara 解析 | 三个读取失败陷阱全部零触发（解析成功） |
| GetObject walk | 必命中（hash 对+在环中） |
| 节点 extraKey/x20 | deref 有效（与 user_auth 同构） |
| 摘除理论 | 节点稳定存活 |
| SELinux | 客户端 get 放行齐全 |

## 4. 唯一剩余嫌疑（下轮第一动作）

**GetObject 的第一个参数（x0）在 0xffe0-0xffe8 调用点传的是 stub(x19) 还是 mgr**——若传错对象，walk 走 stub+0x68（野表）必落空，与全部证据吻合（add 用真 mgr 故成功；查询用错对象故落空）。需在 0xffb8-0xffe8 做完整寄存器追踪确认 x19 当时的身份；若坐实，修复 = 改调用点传参（或确认 stub 与 mgr 偏移关系），一处指令级补丁。

若 x19=mgr 无误 → 则剩下唯一可能：查询应答在更上层（ProcessSkeleton 对象分发/接口 token 检查）被拦截，顺 0x10020 的失败路径与"remoteService is null"日志点继续。

## 5. 追加：stub 嵌入 mgr（x19 嫌疑排除）+ 无效码路径排除

- fcn.febc 参数追踪：x19 = "this" 对象贯穿全程；DevSvcManagerStub 结构**内嵌 mgr**（stub+0x68 == mgr+0x68），0xffe8 调用 GetObject(stub,...) 传参无误
- stub 构造处 [obj+0x38] 唯一写入 = 0xc380 ← **DevHostServiceProxyAddDevice 0x11a6c**（属 DevHostServiceProxy 类，非 servmgr stub——devmgr 内含多 stub 类，此前混淆）
- 无效码路径（0xff54 b.hi 0x100a4）udf 陷阱：**零触发** → 107 客户端的查询码在 48 合法范围（1-8）内，不走无效码分支
- qemu 再次在 ~100s 死亡（HostFreeMemMonitor 0GB 告警复现——宿主内存压力期间实验结果不可靠）

## 6. 当前格局与下一步

活表、hash、add、GetPara、GetObject、GetService、码范围、x18 解引用——全部实测通过，查询仍 not-found。剩余未验环节仅剩一个：**devsvc_manager_stub 的 GetService 应答在 sbuf 回写/上抛过程中被丢弃或改写**（107 客户端解析 48 应答失败，等价于 not-found）。

下一步（不需再 traps）：
1. 用 r2 找 0x4622("not found")/0x35a7("remoteService is null") 的真实引用函数（宽匹配 adrp+add 模式）
2. 直接审查该函数——这是"查询侧 not-found"日志的唯一产出点
3. 若为应答格式问题 → patch devmgr 应答回写格式对齐 107 期望（最后一处指令级修复）
