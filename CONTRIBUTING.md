# 贡献指南

先读 [AGENTS.md](AGENTS.md) 和 [AI 编码规范](docs/ai-coding/README.md)。外部贡献者 fork 后提 PR，说明触发场景、变更行为、测试、兼容风险和恢复方法。请勿上传真实请求、Wi-Fi 标识、机器路径、证书或个人坐标。

本机准备 Xcode/Command Line Tools，运行 `swift test`、`python3 scripts/test-cli.py` 和公开树检查。不要用 CI 成功代替实机定位证据。证书、信任和代理的本机操作必须得到维护者明确授权。

提交使用英文 Conventional Commits；AI 协作只署名实际工具。外部 PR 由维护者或其明确授权的 AI 审核；管理账号本人及其本机 AI 直接更新 main 不额外要求审批。测试和版本门禁失败应修复，不使用跳过检查、强推或扩大信任作为捷径。
