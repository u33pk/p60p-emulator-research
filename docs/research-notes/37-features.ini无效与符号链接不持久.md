# 37. features.ini 补齐无效；发现符号链接修复不随模拟器重启保留

日期：2026-10-20
状态：`texture.bgra.enable=on` 等三行补齐后窗口仍是占位图。
但发现一个**关键操作性问题**：docs/29 的符号链接修复**重启模拟器后会丢失**。承接 docs/29~36。

---

## 1. 重要操作性发现：符号链接修复不持久

重启模拟器后检查：

```
4589 -rw-r--r-- libEGL_impl.so      1572904   ← 恢复成普通文件了
5361 -rw-r--r-- libGLESv1_impl.so   1572904
9556 -rw-r--r-- libGLESv2_impl.so   1572904
9557 -rw-r--r-- libGLESv3_impl.so   1572904
4586 -rw-r--r-- libdgles.z.so       1572904
```

inode 回到了 docs/29 之前的值（4589/5361/9556/9557 各自独立）。
即 `mount -o remount,rw /` + `ln -s` 的改动**在模拟器重启后被回滚**了
（`system.img.qcow2` 可能被重置，或 `/` 的改动没落到覆盖层）。

**后果**：本次启动 `hidumper -s RenderService -a "-a gles"` 直接是
`GL_VENDOR: Unknown / GL_RENDERER: Unknown` —— GPU context 又没了，
桌面链路回到 docs/29 之前的状态。**在此之前截图的一切结果都无效。**

**重新打补丁后恢复正常**：

```
9565 lrwxrwxrwx libEGL_impl.so  -> libdgles.z.so
9568 lrwxrwxrwx libGLESv3_impl.so -> libdgles.z.so
GL_VENDOR: ARM / GL_RENDERER: Mali-G77
GL_VERSION: OpenGL ES 3.0 (4.6.0 NVIDIA 595.71.05)
```

⇒ **每次重启模拟器都必须重跑 docs/29 第 4 节的那段**：

```sh
hdc shell 'mount -o remount,rw / && cd /system/lib64 && \
  for f in libEGL_impl.so libGLESv1_impl.so libGLESv2_impl.so libGLESv3_impl.so; do
    rm -f $f && ln -s libdgles.z.so $f; done'
hdc shell 'kill $(pidof render_service)'
```

启动脚本里必须包含这一步。**更持久的做法**是直接改镜像
（debugfs 改 `tmp/rooted_image/p60p_system.img`，见 docs/29 之前的镜像修改流程），
那样就不用每次重打。

---

## 2. features.ini 差异（已试，无效）

实例用的 `features.ini` 是符号链接：
`tmp/image_root_p60pv2/system-image/HarmonyOS-6.0.0/phone_all_arm/features.ini`
→ `<WORKSPACE>/system_6.0.1/features.ini`

对比 600 官方 `phone_all_arm/features.ini`，我们的**少了三行**：

```
sensor.configuration.enable=on
snapshot.boot.enable=on
texture.bgra.enable=on          ← 纹理格式开关，当时判断最可疑
```

已补齐（备份在 `system_6.0.1/features.ini.bak`），重启模拟器验证：
**窗口仍是占位图，无改善。**

⇒ `texture.bgra.enable=on` 不是原因。

---

## 3. 附带：模拟器重启注意事项

`pkill -x Emulator` 后立刻重启可能触发

```
[SingleInstanceClient.cpp(SendMessage:48)]Waited too long for the reply
```

导致第二次启动失败。需要先等几秒，或 `pkill -f emulator-crash-service` 清掉残留。
用 `setsid nohup ... < /dev/null &` 启动更稳。

---

## 4. 当前状态

| 项 | 状态 |
|---|---|
| 符号链接修复 | 已重新应用，GPU context 正常 |
| features.ini | 已补齐 3 行，无效果 |
| guest 渲染/提交链 | 正常（docs/33） |
| 宿主 paint / present | 都跑、输入都合法（docs/36） |
| 窗口 | 仍是宿主占位图 |

---

## 5. 剩余方向（同 docs/36）

1. `display_present` 里 `blr x2(0x8d40, …)` 那一步 —— 真正送像素的地方
2. child window 上屏（`MAIN_CREATE_CHILD_WINDOW` 只建了内部 GL 子表面）

另可考虑：**把符号链接修复直接写进 `tmp/rooted_image/p60p_system.img`**
（debugfs，改前 `pkill -x Emulator`，改后删 qcow2），一劳永逸。
