# 29. 桌面不出屏根因：DGLES 多副本导致 GL 上下文 TLS 分裂

日期：2026-10-20
状态：**根因已定位并修复**，GPU 上下文已建立，桌面渲染树已带真实像素；剩余缺口收敛到 vsync 不走。

---

## 1. 本轮起点的表象

窗口一直显示宿主占位的「HarmonyOS + 转圈」。guest 侧日志：

```
Bufferqueue: <buffer_queue.cpp:594-CheckBufferQueueCacheLocked>: seq: 61079556, invalid state 2, uniqueId: 4002909519874.
Bufferqueue: <native_window.cpp:261-NativeWindowFlushBuffer>: FlushBuffer failed, ret:41207000
Bufferqueue: <native_window.cpp:220-NativeWindowRequestBuffer>: RequestBuffer ret:40601000
DGLES: d_eglSwapBuffers_special: SwapBuffer NativeWindow err flush:41207000 request:40601000
```

---

## 2. 缓冲队列状态机（逆向 `libsurface.z.so`）

`OHOS::BufferQueue::CheckBufferQueueCacheLocked(unsigned int)` @ vaddr `0x45fb4`：

- 在 `this+0xb0` 的 BST 缓存里按 `node+0x20`（seq）查找；
- 找到后检查 `node+0x30` 的 state，**只有 1 或 4 合法**，否则打 `invalid state` 并返回错误。

SDK 头文件 `native_window/graphic_error_code.h` 给出错误码（**日志里是十进制**）：

| 日志值 | 枚举 | 含义 |
|---|---|---|
| `40601000` | `NATIVE_ERROR_NO_BUFFER` | 无空闲缓冲 |
| `41207000` | `NATIVE_ERROR_BUFFER_STATE_INVALID` | 缓冲状态不符预期 |
| `41210000` | `NATIVE_ERROR_BUFFER_NOT_IN_CACHE` | 缓冲不在缓存中 |

`RequestBufferDebugInfoLocked` 直接给出状态命名：

```
all buffer are using, uniqueId: 104715597643777, Released: 0 Requested: 0 Flushed: 4 Acquired: 0
```

⇒ **state 2 = Flushed（已投递），消费者 Acquired 从头到尾是 0**。
`uniqueId`/`seq` 里嵌了 pid（`932`→`0x3a4`、`24381`→`0x5f3d`），确认这是 render_service 自己的**屏幕 surface**（`(pid<<32)|1`）。

---

## 3. 完整因果链（本轮的最大成果）

```
Drawing::GPUContext::BuildFromGL() 返回 false
  ↑ 因为 Skia 的 GrGLCaps 初始化要读 glGetString(GL_VERSION/GL_EXTENSIONS)
  ↑ glGetString 返回 NULL
  ↑ DGLES 的 emutls「current context」槽是 0
  ↑ 因为 /system/lib64/ 下 libEGL_impl.so / libGLESv1_impl.so / libGLESv2_impl.so / libGLESv3_impl.so
    是 4 份**独立副本**（inode 4589 / 5361 / 9556 / 9557，内容 md5 完全相同）
    eglMakeCurrent 跑在 A 副本 → 写 A 的 emutls
    glGetString  跑在 B 副本 → 读 B 的 emutls → 永远是 0
⇒ RenderContext::SetUpGpuContext 打印 "SetUpGrContext drGPUContext is null"（librender_service_base.z.so:0x39689c）
⇒ AcquireSurface: "GrContext is not ready!!!"
⇒ RSScreenRenderNodeDrawable::OnDraw DrawingSurface is null
⇒ RenderFrame: canvas is nullptr!!!  →  RS 一帧都不画、从不 Present
⇒ 消费者永不 Acquire → 4 个缓冲全部卡在 Flushed → RequestBuffer(NO_BUFFER)
```

### 佐证

- 绕过 wrapper、**直接**调 `libEGL_impl.so` 的 `eglMakeCurrent` + `glGetString`：返回
  `OpenGL ES 3.0 (4.6.0 NVIDIA 595.71.05)` / `Mali-G77` —— DGLES 本身完全正常。
- 走 wrapper 路径（`libGLESv3.so` 分发 → `libGLESv3_impl.so`）则返回 NULL。
- 官方 6.0.0 镜像 `phone_all_arm/system.img` 里这 4 个 `*_impl.so` 是指向 `libdgles.z.so`
  的**符号链接**（debugfs dump 出 0 字节 / short read），只有一个模块，TLS 天然共享。
  6.0.1 的 GL 包把它们做成了 4 份真实文件，才引入这个 bug。

---

## 4. 修复

`/` 是 `/dev/block/vda` 挂 ro，但 `mount -o remount,rw /` **可用**（无需改镜像）：

```sh
hdc shell 'mount -o remount,rw /'
hdc shell 'cd /system/lib64
  for f in libEGL_impl.so libGLESv1_impl.so libGLESv2_impl.so libGLESv3_impl.so; do
    cp -f $f /data/local/tmp/implbak/$f
    rm -f $f
    ln -s libdgles.z.so $f
  done'
hdc shell 'kill $(pidof render_service)'   # init 会拉起
```

musl 动态链接器按 `dev+ino` 去重，符号链接后只加载一个模块，emutls 共享。

**持久化**：`/` 挂在 `/dev/block/vda`（`tmp/deployed_p60pv2/HarmonyOS_P60P_v2/*.qcow2` 覆盖层）。
上面的改动落在覆盖层里，只要不删 qcow2 就一直有效；**一旦删 qcow2 重来，必须重跑这段
remount + ln -s**。备份在 guest 的 `/data/local/tmp/implbak/`。

---

## 5. 修复后验证

`/data/local/tmp/glprobe`（wrapper 路径）：

```
GL_VERSION   = OpenGL ES 3.0 (4.6.0 NVIDIA 595.71.05)
GL_RENDERER  = Mali-G77
GL_VENDOR    = ARM
GLSL_VERSION = OpenGL ES GLSL ES 3.0
GL_EXTENSIONS len=1868
  ext GL_EXT_color_buffer_half_float  YES
  ext GL_EXT_color_buffer_float       YES
  ext GL_OES_vertex_array_object      YES
```

`hidumper -s RenderService -a "-a gles"`（RS 内部）：

```
GL_VENDOR: ARM / GL_RENDERER: Mali-G77 / GL_VERSION: OpenGL ES 3.0 (4.6.0 NVIDIA 595.71.05)
```

日志里 **`drGPUContext is null` / `DrawingSurface is null` / `canvas is nullptr` /
`invalid state` / `all buffer are using` 全部消失**。

缓冲队列恢复健康（不再全卡 Flushed）：

```
usedBufferListLen = 4, freeBufferListLen = 2
bufferQueueCache: state = 3 / 1 / 0 / 0
```

屏幕：`powerStatus=POWER_STATUS_ON, 1320x2232, name=express_display`。

渲染树内容完整且**含真实像素**：

```
SURFACE_NODE[95876554948618] Name[SCBWallpaper4]  Visible:1 VisibleRegion[0,0,1320,2232]
SURFACE_NODE[95876554948627] Name[SCBDesktop5]    Visible:1
  EFFECT_NODE BackgroundFilter[RSMaterialFilterBlur, radius: 46 sigma]
CANVAS_NODE[100454990086152] PIXELMAP_WITH_PARM_OPITEM
  RSImage src_(1512x1008) ARGB-0xFF3282C9 ARGB-0xFF2C6DAD ...   ← 壁纸实际像素
```

---

## 6. 当前唯一剩余缺口：vsync 不走

```
-- current timeStamp: 5480783616480
-- vsyncId: 211          ← 连续多次采样纹丝不动
```

`RS transactionFlags: [22323,29]`（sceneboard 的事务待处理）、`isNodeDirty: 1`，
但 RS 主线程停在 `ep_poll`，**没有 vsync 就不进渲染循环，也就从不 Present**。

相关线索：

```
hdi_servmgr_client: get hdi service chipset_vsync_service failed, -1
chipset_vsync_host_proxy: Get:get remote object failed!
-- VSyncGenerator --  period:15788640  hardwareVSyncStatus: 0
```

⇒ 下一步：打通 `chipset_vsync_service`（vendor HDI）或让 RS 的 VSyncGenerator 在硬件
vsync 缺失时走软件/定时器 vsync。

---

## 7. 顺带澄清的红鲱鱼（不要再追）

`OpenGLWrapper: Failed to find system config path` → `LoadLayers failed.` →
`EglWrapperLayer Init Failed.`：**与桌面无关**。

- 官方 6.0.0 镜像 `phone_all_arm/system.img` 里**没有** `/system/etc/graphics_game/`，
  `600_boot_early.txt` 里同样出现这三条，桌面照常。
- 600 上的原话是 `Failed to dlopen /system/lib64/libiGraphicsCore.z.so ... No such file`，
  即 layer 库缺失导致 LoadLayers 失败，本来就可选。
- 配置文件名确实是 `etc/graphics_game/config/graphics_game.json`，顶层 section 是
  `HOOK_LAYER`（逆向 `GetJsonConfig` @ `0x322d4`，10 字符 SSO）。
  **可写挂载点 `/sys_prod`** 在配置策略搜索列表里，必要时可放
  `/sys_prod/etc/graphics_game/config/graphics_game.json`（本轮已试，不影响结果）。

另外 `begetctl stop_service render_service` 会让整个模拟器退出，重启 RS 用
`kill $(pidof render_service)`。

---

## 8. 复现/自检工具

均在 `tmp/`，用 `sdk/sdk/default/openharmony/native/llvm/bin/aarch64-unknown-linux-ohos-clang` 编译，
`hdc file send` 推到 `/data/local/tmp/` 后 `chmod 755` 运行：

| 文件 | 用途 |
|---|---|
| `glprobe.c` | 完整 EGL+GL 能力探测（版本/扩展/78 个 eglGetProcAddress） |
| `glprobe4.c` | dump wrapper TLS 分发表 + DGLES 内部 global + emutls 当前上下文槽 |
| `glprobe5.c` | 绕过 wrapper 直连 `libEGL_impl.so`，隔离 wrapper / impl |
| `cfgprobe.c` | 调 `GetOneCfgFile` 验证配置策略解析路径 |

RS 侧自检：`hidumper -s RenderService -a "-a gles" / "-a screen" / "-a surface" / "-a RSTree"`。
