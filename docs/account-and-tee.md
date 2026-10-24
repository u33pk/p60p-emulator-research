# 华为账号、设备证明与 TEE

## 当前故障链

应用市场提示“华为账号登录异常”时，日志显示华为账号授权阶段已经成功：

```text
AccountManager.manualLogin auth success
```

随后应用市场申请 OUCS 安全凭证失败：

```text
generate attestKey success
generate unwrapKey success
get anon attestation failed: 12000005, Failed to get message from IPC
```

其他尝试还出现：

```text
generate tempKeys failed: 12000012,
Device environment or input parameter abnormal.
```

请求成功到达华为服务器，但缺少 TSMS 校验参数，服务器返回：

```json
{"rtnDesc":"TSMS verify parameters blank.","rtnCode":630102}
```

所以当前断点不是账号密码错误，也不是主登录请求的 DNS/TLS 不通，而是应用市场后续的设备证明与安全凭证链。

## 与 Android Keybox 的关系

它们都涉及设备预置秘密、安全硬件和服务端验证，但不能直接等同。Android Keybox 通常指 Widevine DRM 的设备密钥箱；这里更像 Android Key Attestation 加设备完整性判定。

仅让接口返回“成功”通常不够。服务器还可能验证华为信任链、设备证书和完整性结果。修改 model、硬件属性、关闭本地提示或自签名密钥都不能替代真实设备证明。

## 当前未做的事

项目不伪造设备证书，不绕过服务器风控，也没有证明所有 TEE 功能完全缺失。日志只确定匿名设备证明或其 IPC 对端失败。继续研究应先定位具体服务、设备节点和 IPC 调用，再区分策略问题、服务缺失与硬件/预置密钥缺失。
