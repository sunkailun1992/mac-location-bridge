# 测试规范

单元测试用合成 ARPC、Wi-Fi 标识和坐标，覆盖截断长度、非法数值、未知主机/端口、重复 Content-Length、Transfer-Encoding 与超限输入。测试断言外部行为，不能只重复实现公式。

集成测试使用临时本机证书和真实 socket，验证 CONNECT/TLS、错误路径关闭与并发上限；不写系统信任，不请求真实 Wi-Fi 数据。身份 CLI 测试验证文件权限、双 SAN、拒绝覆盖与符号链接。

维护者实机验收分阶段记录：系统/构建版本、证书校验、locationd TLS、实际请求解析、合成响应、新鲜 Core Location、地图交叉验证。新鲜读数需有效精度、接近本次探测时间；缓存位置和手动搜索地图不算成功。

`bash scripts/test-app-construction.sh` 实际构造隐藏控制器和完整 AppKit 视图树并执行布局，用于捕捉运行期约束异常。它不展示窗口、不请求权限或调用 CLI；仍需维护者安装后验收可见界面。

运行 `swift test`、`python3 scripts/test-cli.py`、`python3 scripts/check-public-tree.py --self-test` 与隐私扫描；打包运行 `bash scripts/build-app.sh`。未测试的兼容版本写未知，不借 CI runner 的系统版本宣称实机定位通过。
