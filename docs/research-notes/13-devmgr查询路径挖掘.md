# 13 - devmgr 查询路径挖掘：节点确认在环链中，剩余嫌疑锁定查询后检查

日期：2026-10-18（夜场）
工具链新增：ptrace_findhex（4字节值内存搜索）、ptrace_read（定址读取）、ptrace_chain（链表遍历）。hash 算法已从 107 版 libhdf_utils 反出：**h=0; h=h*131+c; h&=0x7fffffff**。

## 1. devmgr 查询机制（DevSvcManagerGetObject @0xb44c 反编译）

- 服务表 = **hash 环链表**，头在 mgr+0x68，节点 {next@0, prev@8, hash@0x10, extraKey@0x18, service@0x20, ...}
- 查询：HdfStringMakeHashKey(name) → 遍历环比对 hash@0x10 → 命中后 `cbz extraKey` 直通 found；extraKey 非 0 时比对 node+0x18，**不匹配则解锁+报错返回（不走完环）**

## 2. live 链表取证（ptrace_chain 实走 45 步）

- **23 节点完整闭环环链，无断链**。composer 节点在环中：hash=0x0babe50f（与手算 h131("display_composer_service") 完全一致）、extraKey/service 指针非空、+0x37=0x0b=hostId 11 ✓
- user_auth 与 composer 同处一个环（prev/next 互相跨越两个堆簇）→ **只有一个服务表，composer 确实在里面**
- 字段基线：+0x30 各节点取值 {1, 0x100, 0x20, 0x40}（user_auth=0x100，composer=1）——语义未明，但 GetObject 遍历时**不读这个字段**，排除嫌疑
- 链表头疑似 0x7fa9866aa8（mgr+0x68 内嵌头，hash/x18 为 0 的伪节点）

## 3. SELinux 排查（排除）

`(allow render_service hdf_display_composer_service (hdf_devmgr_class (get)))` 在 cil 第 123908 行，multimodalinput 等客户端也有。查询权限无缺口。

## 4. 剩余嫌疑（查询 walk 之后的检查，本轮未及反编译）

devmgr 字符串表暴露三个关键检查点，引用函数待定位：
- `"StubGetService %{public}s remoteService is null"`（0x35a7）——**节点命中后 remoteService 为 null 即拒绝**
- `"StubGetService service %{public}s is invalid"`（0x4774）
- `GetServicePermCheck` / `HdfGetServiceCheck`（导入自 107 版 libhdf_ipc_adapter——该库客户端路径走 **samgr ServiceRegistry**，手机架构里 HDI 服务可能双注册：devmgr 本地表 + samgr SA；若 composer 只进其一即出现"表里有、查不到"）
- 0xb4d4 extraKey 不匹配即中止返回的分支（需确认客户端 extraKey 是否非 0）

## 5. 下一步（按序）

1. 定位并反编译引用 0x35a7/0x4622/0x4774 的函数（stub get 处理器全貌），看清 walk 之后的过滤链
2. 核实客户端查询路径：手机版 libhdf_ipc_adapter 的 HdfRemoteAdapterGetService 走 samgr，确认 multimodalinput/RS 实际命中哪个查询端点，composer 的注册是否漏了 samgr 侧
3. 若 remoteService-null 检查是最后一道闸：ptrace 读 composer 节点 +0x20 指向的 service 对象的 vtable/引用，对比 user_auth 的，找出为何被判 null/invalid
4. 修复方向候选：devmgr 侧放宽检查 / host 侧重发注册 / samgr 侧补注册

## 6. 当前状态

镜像 = 基线（全部陷阱已还原，系统稳定）。工具资产：ptrace_bt / ptrace_grep / ptrace_findhex / ptrace_read / ptrace_chain 五个 guest 内工具（tmp/*.c，ohos clang 静态编译）。
