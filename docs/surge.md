# Surge 定位接入

完整网络约束见[功能规范](location-modification-spec.md#8-surge-接入和恢复)，标准启动、换点和结束流程见[操作手册](operations.md)。

仅适用于已经运行的 Surge for Mac。脚本只增加一个本地 HTTP 代理与两条 `locationd + 精确域名` 规则，不替换全局出口、DNS、订阅或其他规则。

先启动 LocationBridge 服务，再选择**当前生效的** profile 路径。state 必须是仓库外的新私有目录，每次实验单独建立。

```bash
python3 scripts/surge-integration.py plan --profile "$PROFILE_PATH" --state "$SESSION_PATH"
python3 scripts/surge-integration.py apply --profile "$PROFILE_PATH" --state "$SESSION_PATH"
```

恢复时使用同一 state 与端口：

```bash
python3 scripts/surge-integration.py restore --profile "$PROFILE_PATH" --state "$SESSION_PATH"
```

恢复从当前 profile 中移除精确所属条目，因此保留会话期间其他编辑。遇到重复条目、意外端口或未知策略引用即拒绝。脚本写入前再次比较内容，仍无法对不合作的外部 writer 提供文件级原子 CAS；操作时避免同时编辑 profile。

失败候选与 before-state 留在私有 state 目录，不打印 profile 内容。apply 校验失败后保留现场并改用新 state 重试；restore 候选使用独立文件名，可重新检查。若提示 profile 已写但 reload 失败，需用同一 state 恢复，不能理解成完全没有修改。

如果直接退出 App，服务端口会关闭而外部 Surge 规则仍可能存在。结束实验时先恢复 Surge 接入，再停止服务；不要把停止服务当成恢复全部网络设置。
