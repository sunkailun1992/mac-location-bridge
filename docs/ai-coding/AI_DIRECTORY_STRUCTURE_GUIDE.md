# 目录规范

- `Sources/LocationBridgeCore/`：协议和服务，无系统配置副作用。
- `Sources/location-bridge/`：CLI、本地身份与只读兼容检查。
- `Sources/LocationBridgeApp/`：AppKit、Core Location、CLI 生命周期。
- `Tests/`：合成测试，不含真实环境夹具。
- `scripts/`：可复现打包、公开树门禁与 CLI 集成验证。
- `ThirdParty/`：许可证、来源版本与修改说明，不含私钥或二进制应用。
- `docs/`：设计、规范、契约与兼容矩阵。

运行数据、生成身份、证书导出、信任快照和个人配置放在仓库外。`dist/` 与 `.build/` 是忽略的生成物，不手工修改生成源码来绕过依赖版本约束。
