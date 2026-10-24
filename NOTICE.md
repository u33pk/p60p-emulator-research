# 第三方与发布边界

- 本项目不是华为、OpenHarmony 或 DevEco Studio 的官方项目，与上述主体无隶属或背书关系。Huawei、HarmonyOS 等名称和商标归各自权利人所有。
- 仓库不包含 ROM、分区镜像、升级包、模拟器镜像、SDK、Emulator、HAP、修改后的华为共享库或设备证书。补丁清单和配置片段不构成这些专有文件的替代品。
- `configs/hdcd.root.cfg` 来源为 OpenHarmony `developtools_hdc` 的 root 服务配置，原项目采用 Apache License 2.0；`secon` 按本研究环境改为 `u:r:hdcd:s0`。许可证全文见 `LICENSE-Apache-2.0`。
- `configs/selinux-additions.cil` 中 `emu_param` 域来自对官方 6.0.1 OpenHarmony 模拟器策略的适配。OpenHarmony 相关组件通常采用 Apache License 2.0；各上游文件的具体版权仍归原作者。
- root 方法早期参考 CSDN 作者 moli51234 的文章：<https://blog.csdn.net/moli51234/article/details/146159992>。原文标注 CC BY-SA 4.0；本仓库记录独立实验过程并保留来源链接。
- 历史笔记中的逆向地址和补丁只适用于列出的构建。使用者需自行确认其拥有修改和运行相应文件的合法权限。
