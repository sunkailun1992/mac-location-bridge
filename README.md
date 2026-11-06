# LocationBridge

<img src="Resources/AppIcon.png" width="112" height="112" alt="LocationBridge 定位针与桥梁图标">

独立维护的 macOS 定位协议实验工具，包含原生 App、CLI、兼容诊断和可恢复的受限证书实验。使用本机独立证书，不捆绑共享私钥。

**当前版本：0.1.0，实验版。** 已在维护者的一台 macOS 27.2（26B123）上验证新鲜 Core Location 跟随不同目标；完整兼容范围见[兼容矩阵](docs/compatibility.md)。系统升级后必须重新预检和实机验证，不能据此保证所有 Mac 或后续版本可用。

## 构建

准备 Xcode 或 Command Line Tools；App 可在 macOS 13+ 构建，P12 服务启动需要 macOS 15+，以使用内存导入，避免隐式写入用户钥匙串。

```bash
swift test
bash scripts/test-app-construction.sh
python3 scripts/test-cli.py
python3 scripts/test-tls.py
python3 scripts/test-surge-integration.py
python3 scripts/check-public-tree.py --self-test
python3 scripts/check-public-tree.py
bash scripts/build-app.sh
python3 scripts/test-trust-helper.py
```

输出为 `dist/LocationBridge.app`，含 App、CLI 和信任实验 helper，使用 ad hoc 签名。当前没有 Developer ID 公证或自动更新承诺。

## 使用

1. 打开 App，输入目标的 WGS84 纬度、经度。程序不把目标写入源码或公开仓库。
2. 显式生成本机独立身份；文件保存在仓库外，私钥和密码不会共享。
3. 如需系统实验，阅读界面的信任说明后安装受限实验信任。它仅针对这一叶证书、`locationd` 和两个精确 Apple 定位主机；使用未公开保证的 allowed-error 行为，属于安全敏感的兼容实验。
4. 运行预检，再启动本地服务。预检或信任设置存在只说明准备阶段，不代表实际系统位置已改变。
5. 配置定位请求的受限网络接入。当前附带 [Surge 集成](docs/surge.md)，其他网络环境尚未适配。
6. 读取新的系统位置，并在 Apple 地图的“我的位置”交叉核对。缓存位置、手动搜索地图和界面目标均不能代替验收。

系统可能缓存 Wi-Fi 定位结果。更新目标后若没有产生新请求，可由维护者手动刷新定位服务；macOS 可能提示对“查找我的 Mac”的影响，应按系统提示操作并恢复开启。程序不自动切换系统定位开关。

## 范围和恢复

服务仅监听 loopback，只接受两个 Apple 定位主机的 443 CONNECT，TLS 后仅处理定位协议路径。没有任意上游转发、遥测、云后端或浏览器模拟兜底。它不修改公网 IP、账号国家或系统地区。

停止服务与移除信任是不同动作。退出 App 会停止它启动的 CLI；认证或信任命令进行中会阻止普通退出，应先在系统窗口完成或取消。强制退出不能保证取消操作，恢复使用保留的私有会话。已安装的实验信任和外部网络集成需要按各自会话恢复。App 的“移除实验信任”只删除精确匹配本次快照的记录；Surge 用同一私有 state 目录执行 restore。见[信任说明](docs/trust-experiment.md)。

## 开源协作

外部贡献者可提交 issue 和 fork PR；由维护者或其授权 AI 审核，CI 通过后 squash 合并。维护者本人及使用同一管理账号的本机 AI 可以直接更新 `main`，不额外要求 PR 审批。规范入口为 [AGENTS.md](AGENTS.md)、[AI 编码规范](docs/ai-coding/README.md)、[贡献指南](CONTRIBUTING.md)和[维护者约定](MAINTAINERS.md)。

## 来源与许可证

本项目按 MIT 开源。协议实现参考并改编自 MIT 项目 [OpenHRTT/wloc](https://github.com/OpenHRTT/wloc)，保留[许可证和来源映射](ThirdParty/WLoc/PROVENANCE.md)。SwiftProtobuf 固定为 1.38.1，遵循 Apache-2.0。另比较过 [TimBitBox/mac-location-spoofer](https://github.com/TimBitBox/mac-location-spoofer) 的私有偏好机制与 [SpoofGeo](https://github.com/vluncasu/spoof-geo-macos) 的进程级模拟；这些路线没有被当作系统定位成功的替代证据。
