# Emulator 二进制补丁经验

本文总结定位并修改镜像签名校验的完整过程。目标不是只记住 `0x1224374`，而是下次换 Emulator 构建时能够重新定位，也不把版本差异误当成同一套补丁。

## 1. 校验发生在哪里

镜像目录中的 `image_signature/*.hwp7s` 是各分区 PKCS#7 签名。Emulator 启动时单独线程验证分区；失败会弹出“镜像被篡改”并强制关闭。因而先找到字符串比按流程猜代码更可靠：

```text
verify signature error, code %08x.
Check Image Failed
The image file has been tampered with...
```

反汇编符号和堆栈信息还给出源码名 `emulator-ui/utils/sign/CheckSign.c` 与函数名 `CheckImage`。

## 2. 从字符串回到入口

使用 r2：

1. 加载 Emulator 副本，搜索上述 ASCII 字符串；
2. 从字符串执行交叉引用，找到打印错误的分支；
3. 顺着调用链找到唯一真正验证 PKCS#7 的函数；
4. 检查其参数、副作用和返回值语义。

本次定位到 `fcn.01224374`，地址 `0x1224374`：

- 读取 `.hwp7s`，解析 PKCS#7 并验签；
- `w0=0` 表示成功，其他值为错误码；
- 唯一调用点是 `0x1224e84`，只比较 `w0` 后选择成功或篡改分支；
- 函数没有必要的副作用参数，从入口直接返回成功风险较小。

结论是 patch **校验函数入口**，不要 patch 弹窗、线程或调用者分支。让函数自己返回成功，可以一次覆盖所有分区和调用路径。

## 3. AArch64 最小补丁

原文件 `0x1224374` 的 8 字节为标准函数序言：

```asm
stp x29, x30, [sp, -0xc0]!
mov x29, sp
```

替换为：

```asm
mov w0, #0
ret
```

字节级表示：

| 偏移 | 原字节 | 新字节 | 指令 |
|---|---|---|---|
| `0x1224374` | `fd7bb4a9` | `00008052` | `mov w0,#0` |
| `0x1224378` | `fd030091` | `c0035fd6` | `ret` |

这段顺序是固定的。不要只写 `ret`，否则 `w0` 会保留垃圾值；也不要只在调用点 `b.eq` 处补跳转，避免漏掉其他调用或破坏控制流。

该 Emulator 的 `.text` 近似恒等映射，所以**文件偏移等于反汇编 vaddr**。但 `librender_service.z.so` 不是这样，其代码段满足 `vaddr = file offset + 0x1000`。每个文件都应重新确认 LOAD 段关系，不能套用同一个规则。

## 4. 安全操作流程

```sh
# 1. 只复制到工作区，并保留原件
cp <sdk>/emulator/Emulator work/Emulator.orig
cp work/Emulator.orig work/Emulator.patched

# 2. 做文件副本可写；绝不修改 SDK 原件
chmod u+w work/Emulator.patched

# 3. 由清单检查版本、大小、SHA-256、原字节后打补丁
python3 scripts/patch_binary.py \
  patches/emulator-26.0.0.402-signature.json \
  work/Emulator.patched

# 4. 启动脚本用 P60P_EMULATOR_BIN 指向补丁副本
```

当前清单会逐项校验：

- 文件大小 130446408；
- 原始 SHA-256 `62dd21c3…ff9ab4e`；
- 两个偏移处的原字节。

任何一项不匹配都会拒绝修改。已在公开验证中确认，它能重建出现行使用的 Emulator，SHA-256 为 `a188d68b…7000083e`。

## 5. 版本和作用域

- 地址、大小、哈希只适用于 Emulator 26.0.0.402 Linux aarch64。换补丁编号或平台后重新反汇编。
- 保存至少两份基线：完全原版和已知可启动版本，避免以后无法区分“补丁回归”和“版本不匹配”。
- 修改 SDK 中 Emulator 会影响**该 SDK 下所有实例**。研究工作最好使用独立副本，通过 `P60P_EMULATOR_BIN` 隔离。
- patch 后先执行 Emulator 的 `-version`，确认没有破坏动态加载和入口点，再启动实例。
- 这只绕过 Emulator 对本地分区文件的签名校验，不伪造分区签名，也不绕过华为服务器的账号、TEE 或设备证明。

## 6. 其他二进制的通用思路

1. 记录构建版本、大小、原始 SHA-256；
2. 找稳定字符串、错误码和源码名；
3. 用字符串交叉引用到达唯一函数；
4. 先确认返回值语义、调用点数量和副作用；
5. 选择最小 AArch64 替换，列出原/新指令；
6. 用“原字节检查 + 结果哈希”脚本化；
7. 做明确 A/B：原版失败、补丁版成功；
8. 不跨版本复用偏移，也不为掩盖症状去补调用者。

`scripts/patch_binary.py` 的 `patches/` 清单就是这个流程的机器可读结果。
