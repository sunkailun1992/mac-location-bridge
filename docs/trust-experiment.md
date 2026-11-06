# 受限叶证书信任实验

完整功能约束见[功能规范第 5 节](location-modification-spec.md#5-受限信任的安装检查与移除)，操作顺序见[操作手册](operations.md)。本页保留信任机制说明。

本实验将本机唯一叶证书设为 `TrustAsRoot=2`，每个条目同时限定 SSL 服务端策略、精确主机名与当前 locationd 的指定签名要求。只有 `gs-loc.apple.com` 和 `gs-loc-cn.apple.com` 两条约束，`AllowedError=0`。

这会在上述约束范围内放宽部分证书错误检查。0 不是 Apple 文档保证的 pinning 例外，也不只针对四个固定错误；其他未映射的可恢复校验错误也可能被覆盖。它不是全局信任根：helper 不给根证书增加信任，不改 System 域、SIP、Apple 二进制或证书绑定数据库。

快照记录叶/根公共 DER、原本叶设置缺省、OS/build 和 locationd 原指定签名要求。已有任何 user/admin 叶设置时拒绝覆盖。目录 0700，快照 0600，保存在 Git 外。

App 只在点击安装并阅读说明后调用 prepare、apply。管理员认证由 macOS 自己处理，程序不收集密码。CLI 入口使用 App 包中同目录 helper：

```bash
location-bridge prepare-trust --directory "$IDENTITY_PATH" --state "$NEW_PRIVATE_STATE_PATH"
location-bridge apply-trust --state "$NEW_PRIVATE_STATE_PATH"
location-bridge trust-status --state "$NEW_PRIVATE_STATE_PATH"
location-bridge restore-trust --state "$NEW_PRIVATE_STATE_PATH"
```

正常退出会等待正在执行的命令结束；信任认证未结束时请先在系统窗口完成或取消。强制结束进程无法保证服务端操作被取消，重启后应使用保留的私有会话快照检查状态，不把关闭窗口当成撤销。

恢复只删除与本次叶证书、应用签名、SSL 两主机、0/2 参数完全匹配的记录；外部漂移即拒绝，不导入整域信任，不使用 Set(NULL)。系统升级后仍允许按旧快照精确删除自己的条目，不要求当前系统签名继续等于旧签名。

信任设置回读成功不证明实际 locationd 已采用，也不证明目标 App 位置改变。必须继续真实 TLS/HTTP 与新鲜位置验收。当前实机结论见[兼容矩阵](compatibility.md)。
