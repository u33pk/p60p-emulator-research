# 40. 修正 39 的一处推论：glfwCreateWindow 日志受级别门控

日期：2026-10-20
状态：39 号的结论（窗口=宿主占位图）**依然成立**，但其中"guest 显示窗口从未创建"的推论
**不成立**——那是被日志级别门控误导的。承接 docs/29~39。

---

## 1. 修正

上一轮发现 qemu.log 里 `glfwCreateWindow` 计数为 0，据此推断"guest 显示窗口从未创建"。
**这是错的。**

`express_gpu_render.c` 的 `handle_child_window_event` @ 行 488：

```
0x79f068  ldr w0, [0x7b3e990]        ; 日志级别全局变量
0x79f074  cmp w0, 1
0x79f078  b.gt 0x79f0a8              ; 级别 > 1 就跳过日志
0x79f07c .. 0x79f0a4  log "start glfwCreateWindow"
0x79f0a8  ldr x0, [ctx+0x68]         ; 真正的建窗逻辑在这，不受级别影响
0x79f0ac  ldr x0, [x0]
0x79f0b0  cmp x0, 0
0x79f0b4  b.ne 0x79f0e8              ; field_0 非空 → 窗口已存在，跳过
0x79f0b8 .. 0x79f0c4  bl 0x7a0a48    ; → 0x7a06e4("Trinity", …) 实际创建
0x79f0d0  str x1, [x0]               ; ctx->field_0 = 窗口句柄
```

⇒ **`start glfwCreateWindow` 只在日志级别 ≤ 1 时才打印**，当前级别更高，
所以它"没出现"完全正常，**不能据此断定没建窗**。

同时 `glfwCreateWindow` 是 `libglfw.so.3` 的真实导入符号（`U glfwCreateWindow`），
建窗路径也确实存在。⇒ **"guest 显示窗口未创建"这条线索撤销。**

（`0x7a0a48` 里的字符串是 `Trinity` —— 窗口/线程名；日志文件是
`../hw/express-gpu/express_gpu_render.c`。）

---

## 2. 仍然成立的部分（docs/39）

guest 的 `ohos.boot.time.bootanimation.finished` 有值、`ps` 里无 bootanim 进程、
sceneboard 在跑 —— 窗口里的「HarmonyOS+转圈」**确实是宿主占位图**。
这一条不受本轮修正影响。

---

## 3. 方法论教训

**"某条日志没出现"只有在该日志没有级别门控时才能当作否定证据。**
这个二进制里几乎所有日志都套了 `cmp wN, #k; b.gt skip` 的级别检查
（k 多为 0/1/2），所以"没日志"几乎不能证明"没执行"。

可行的替代判据：

- 看**副作用**（结构体字段、调用目标、返回值），不是看日志
- 找**一定会打**的错误路径（如 `layers is null`、`display gbuffer is nullptr`）——
  这些出现过/没出现才有意义
- 把日志级别调低，或直接把 `b.gt` patch 成 `nop` 让它必打

---

## 4. 下一步

既然建窗路径正常、paint/present 都跑，缺口仍在**画完→窗口可见**。

可走的两条：

1. **把日志级别调低 / patch 掉级别门控**，重跑一次拿到完整宿主日志，
   看 present 链的每一步实际走了哪里。级别全局在 `0x7b3e990`。
2. **直接 patch `display_present` 的 `blr x2(0x8d40, …)`**，
   确认它调到的目标函数（`**(0x7b44578)` 的 ops 表首项）是什么。

---

## 5. 自检

```sh
# 39 号判据仍然有效
hdc shell 'param get | grep -i bootanim'      # finished 应有值
hdc shell 'ps -ef' | grep sceneboard | grep -v grep

# 日志级别门控的通用形态（都会 skip）
grep -c 'glfwCreateWindow' tmp/deployed_p60pv2/HarmonyOS_P60P_v2/Log/qemu.log   # 0 不代表没跑
```
