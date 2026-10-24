# 71. 突破：呈现门控确认为 boot-complete，并已打通呈现路径

日期：2026-10-21

## 一、决定性对照：GL 拦截层（LD_PRELOAD）对比

写了 `tmp/glshim.c`（拦截 `eglGetProcAddress` / `glfwGetProcAddress` /
`glfwSwapBuffers`，记录 GL 调用并 dump 纹理/帧缓冲）。
同宿主、同 vendor、同一份插桩 Emulator，只换 system：

| | 6.0.1 官方（出屏 206KB） | 手机 ROM（黑屏 33KB） |
|---|---|---|
| Commit（图层） | 开机 77 次，之后每分钟 1 次 | 开机 169 次，之后每分钟 1 次 |
| 图层字段 | `num 1320 calc 79204 layers_size 64` | **完全相同** |
| 纹理创建 | 4×1320x2232 + 2×1320x2232(PBO) + 2×63x63 + 1×940x1588 | 几乎相同（多 2×192x192） |
| UI 绘制 `glDrawArrays(0x5,N,4)` | 1477 次 | 1282 次（**两边都在画 UI**） |
| 图层绘制 `glDrawArrays(0x4,0,6)` | 162 次 | 356 次 |
| **整帧读回** `glMapBufferRange(GL_PIXEL_PACK_BUFFER,…)` | **11 次** | **0 次** |
| swap 后帧缓冲 | 940x1588 **完整锁屏**（时钟/状态栏/壁纸） | **1x1 黑** |

⇒ **问题不在渲染，在「呈现」**：手机轮画完从不读回整帧、从不 swap。

## 二、根因：guest 从不发 `boot-complete`（docs/55 的猜想，已实证）

宿主日志 `BootComplete.cpp(BootCompletePipeClientRecv)` 的
`guest os boot completed.`：

- 手机 ROM **当前各轮一次都没有**（历史 04:10 那次是旧实验）
- 6.0.1 对照组开机后约 2 分钟收到

**时间决定性证据**（对照组 GL dump 文件 mtime）：

```
21:10:58  fb_000_swap0_1x1        ← boot-complete 之前：1x1
21:11:08  fb_012_swap1_940x1588   ← 与 boot-complete 同一秒！首次整帧呈现
21:11:59  fb_013_swap2_940x1588   ← 之后每分钟一次（与 Commit 同频）
```

⇒ **呈现严格被 `boot-complete` 门控**。guest 不发，宿主永远停在开机占位图态。

`QemuParams`（6.0.0/6.0.1 的 `/system/bin`、`/vendor/bin` 里都有，
全系统**只有它**含 `boot-complete` 与 `/dev/express_pipe`）是唯一发送者。
它由 **init** 拉起（sepolicy：`typetransition init emu_param_exec process emu_param`），
但**没有任何 init cfg 引用它**，官方镜像的启动方式仍未查明。
我们的镜像里 QemuParams 启动后没有正确发信（docs/56）。

## 三、宿主侧强制打通（方案 C，已生效）

调用链（已完整逆向）：

```
BootCompletePipeClientRecv("boot-complete")        0x12f33ec~
  ├ *( *(0x7b2ef60) ) = 1                          0x12f35f4  ← boot-complete 标志
  ├ 0x1059a14  OnBootCompleted                     0x12f3604
  │    └ 0x10f84fc → StopBootAnimation             0x10f85bc
  │         ├ QWidget::hide() 占位图
  │         ├ *(0x7b30b70)=0 ; this[0x121]=0 ; this[0x38]不改
  │         └ 0x1101288 后续状态
  ├ EmitGuestOSBootComplete: obj->vtable[4](obj,str) 0x12f366c  (obj=0x1052268())
  └ 回包 "ok"                                       0x12f3688
```

`ShowBootAnimation` = 0x1101050，`StopBootAnimation` = 0x110115c。

**只做 StopBootAnimation（隐藏占位图）无效**（同 docs/57：黑屏）。
**只做 0x1059a14 也无效**。必须连标志 + OnBootCompleted + Emit 一起做。

**补丁**（`sdk/emulator/Emulator`，`QemuBootParamsAdd` @0x12f1150 的函数体
被改写成 stub，因为它的入口本来就被我们改跳；guest 发参数时走这里，
与正常 boot-complete 同一线程上下文，安全）：

```asm
; 0x12f1150
stp x29,x30,[sp,#-0x10]!
mov x29,sp
adrp x0, 0x7b2e000 ; ldr x0,[x0,#0xf60]
mov w1,#1 ; strb w1,[x0]      ; 设 boot-complete 标志
bl 0x1059a14                   ; OnBootCompleted（含 StopBootAnimation）
bl 0x1052268                   ; obj getter
mov x3,x0 ; ldr x0,[x3] ; ldr x2,[x0,#0x20]
adrp x1, 0x7b37000 ; ldr x1,[x1,#0x330]
mov x0,x3 ; blr x2             ; EmitGuestOSBootComplete
ldp x29,x30,[sp],#0x10 ; ret
```

**效果（已验证）**：
- `StopBootAnimation` 正常触发，占位图/转圈消失
- **整帧读回打通**：`glReadPixels(0,0 940x1588)` + PBO map 每帧一次（176 次）
- swap 帧缓冲 940x1588（不再是 1x1）

## 四、新的缺口：呈现出来了，但内容是黑的

打通呈现后，每帧读回的 940x1588 帧缓冲
**149 万像素里只有 1086 个非黑**，位于底部中央 40×40 的小方框
（锁屏底部的 home 指示点）。壁纸/时钟/状态栏全无。

每帧结构（`glDrawArrays` 与 FBO 绑定，已实测）：

```
draw #0  tex=7  1320x2232 图层(壁纸)  → fbo=2 (gbuffer 1320x2232, scissor 全幅)
draw #1  tex=1  63x63     相机图标    → fbo=2
draw #2  tex=4  1320x2232 guest 缓冲  → fbo=1 (窗口 940x1588)   ← 呈现内容
        glReadPixels + PBO map + swap
```

- fbo=2/3 乒乓（写/读 gbuffer），viewport/scissor 都是全幅 1320x2232
- **tex=4（guest 缓冲）本身就是近乎全黑**（2066/2946240 非黑，avg 0x380）
- 所以：**画进 gbuffer 的内容没有生效**（fbo=2 的读回 err=0x502，看不到它本身）

即：图层绘制（壁纸）虽然执行了，但落到 gbuffer 上没有可见结果。
可能在：绘制几何（顶点四边形）、混合状态、transform、或 gbuffer 纹理与
所呈现纹理不是同一块（乒乓错位）。

## 五、重要教训：强制 boot-complete 的两个坑（已回退）

打通呈现后又做了对照组回归，发现**补丁会破坏正常出屏**，两个原因：

1. **消息路由被打乱**：把 `BootCompletePipeClientRecv` 的匹配分支 nop 掉后，
   guest 的**所有**管道消息都走 boot-complete 路径，参数消息
   （`ohos.qemu.dpi` / `windowOptions` / `layout.config` …）不再被处理，
   显示配置丢失。
2. **过早触发**：guest 在开机早期就发参数消息，stub 在那时就置 boot-complete，
   而真正时机是 guest 起来之后（对照组实测：开机约 2 分钟）。
   过早切换到 live 态 → 黑屏。
3. 重复触发也有害（每次参数消息跑一遍 OnBootCompleted）。

**对照组同样验证**：早期帧也是 1086 非黑（与手机组一模一样），
**完整锁屏是在 boot-complete 之后才逐帧长出来的**
（1086 → 4115 → 4252 → …），说明「内容出现」同样依赖 boot-complete 时序。

⇒ **已把所有 boot-complete 补丁回退**，二进制恢复到纯插桩态
（md5 `c2a33d7a`，= `tmp/Emulator.before_instr` + 字段 dump 插桩）。

## 六、下一步（正确的做法）

**不要在宿主里抢跑 boot-complete**。改为：

1. **LD_PRELOAD shim 延迟触发**（推荐，可控时机）：
   在 shim 里起线程，等 guest 就绪（约 150s）后，按 docs/71 第三节的调用链
   （设标志 → `0x1059a14` → `EmitGuestOSBootComplete`）手动跑一遍。
   参数消息照常被处理，时序也对。
2. **guest 侧正规修复**：查清官方镜像里 `QemuParams` 的启动方式
   （init 无 cfg 引用，但 sepolicy 显示由 init 拉起），
   或写最小助手往 `/dev/express_pipe` 的 `boot-params` 管道写 `boot-complete`。

## 状态

- `sdk/emulator/Emulator`：**已回退**到纯插桩态（md5 `c2a33d7a`）：
  字段 dump 插桩 + `0x11065a8` setParent nop。
  所有 boot-complete 相关补丁已撤销。
  原版备份 `tmp/Emulator.before_instr`（md5 ace99264）；**归档前必须还原**
- `tmp/glshim.c` / `tmp/glshim.so`：GL 拦截 + 纹理/帧缓冲 dump（LD_PRELOAD）
- 启动脚本：`tmp/run_emu_plain.sh`（无 shim）、`tmp/run_emu_gl.sh`（带 shim）
- 抓取产物：`tmp/gltrace_phone*/`、`tmp/gltrace_ctrl*/`
- 逆向常量（下一步要用）：
  - `OnBootCompleted` = `0x1059a14`，obj getter = `0x1052268`
  - boot-complete 标志：`*( *(0x7b2ef60) ) = 1`（字节）
  - Emit：`obj->vtable[4](obj, *(0x7b37330))`
  - `ShowBootAnimation` = `0x1101050`，`StopBootAnimation` = `0x110115c`
  - `QemuBootParamsAdd` = `0x12f1150`，`BootCompletePipeClientRecv` ≈ `0x12f33ec`
