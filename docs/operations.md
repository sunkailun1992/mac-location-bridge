# 定位修改操作手册

本手册对应 `0.1.0` 当前实现，功能规则见[定位修改功能规范](location-modification-spec.md)。示例只使用变量；真实地址、目标坐标、身份、profile 和会话路径保存在本机私有目录。

## 1. 准备和记录

1. 确认要修改的是这台 Mac 的系统位置，并核实目标楼宇的 WGS84 坐标。单元号与经纬度是不同数据。
2. 记录 `sw_vers`、Xcode 版本、程序版本和源码提交；查[兼容矩阵](compatibility.md)。未列出的组合按未验证处理。
3. 准备仓库外的身份目录、信任快照目录和网络会话目录。它们分别保存不同对象，不可互相替代。
4. 确认 Surge 当前 profile 的实际路径，操作期间避免其他编辑者同时写这个文件。
5. 保留恢复路径。管理员密码只在 macOS 的认证窗口或本机终端输入，不发聊天，不写脚本。

源码构建见 [README](../README.md)。工具链需满足固定依赖的 Swift 6.1/6.2 manifest 和 SDK 要求，不能仅看本项目 tools-version 5.9 就认定 Swift 5.9 可构建。App 和 CLI 应来自同一次构建，`locationbridge-trust` 必须与 CLI 位于同一个 `Contents/MacOS` 目录。

## 2. App 标准操作

1. 打开 App，输入经纬度。初次打开没有默认坐标或自动操作。
2. 生成新身份，或者选择已有的本机身份目录。已有目录不覆盖；选择新身份会使预检失效。
3. 尚未配置本身份信任时，点击“安装受限实验信任”，阅读明确的范围说明并确认。程序先保存快照和恢复句柄，再请求系统授权。
4. 已有恢复句柄时，先读取并处理旧会话；不要通过清空偏好设置绕过保护后叠加另一身份。
5. 运行 TLS 预检。显示“受限实验信任已配置”只说明精确设置存在；实际兼容仍待验证。
6. 点击启动本地服务，等界面显示收到 `127.0.0.1:19443` 的 ready 回执。
7. 单独完成本手册第 4 节的网络接入；App 当前不会替你修改 Surge。
8. 点击“读取新的系统位置”，确认读取时间、实际精度和距目标距离。
9. 在 Apple 地图使用“我的位置”交叉确认。仅搜索目标地址不能完成这一步。

当前 App 运行服务时禁止编辑坐标。需要换目标时先停止服务，再编辑、重新启动并重新读取；身份和信任未变时可复用已有有效预检。停止至重新启动之间，旧网络规则可能仍将请求导向关闭的端口，须将此视为操作间隙；长时间停止前先恢复网络。

## 3. CLI 契约

把变量指向本机真实路径，不将赋值后的私人内容提交到仓库。`CLI` 指 App 包内 `location-bridge`，`IDENTITY_PATH` 是身份目录，`TRUST_STATE_PATH` 是本会话信任目录。

| 命令 | 参数与结果 |
|---|---|
| `help` | 显示 `0.1.0` 命令；没有单独的 `--version` 或 `--help` 选项 |
| `init-identity` | 可选 `--directory PATH`；默认目录见功能规范；拒绝覆盖 |
| `preflight` | 可选 `--directory PATH`；输出只读 JSON；`0` 表示可继续实验，`2` 表示预检未达到门槛 |
| `serve` | 必需 `--latitude LAT --longitude LON`；可选 `--directory PATH --port PORT --accuracy METERS`；默认 `19443`、`10` |
| `probe` | 必需 `--latitude LAT --longitude LON`；可选 `--timeout SECONDS`，默认 `30`、范围 `1–120` |
| `prepare-trust` | 可选 `--directory PATH`，必需 `--state NEW_PATH`；只准备私有快照，最终会话目录必须不存在 |
| `apply-trust` | 必需 `--state PATH`；显式写入受限实验配置，可触发系统认证 |
| `trust-status` | 必需 `--state PATH`；只读核对本会话约束 |
| `restore-trust` | 必需 `--state PATH`；仅删除精确所属的叶记录，保留其他配置 |

每个选项必须使用 `--key value`，重复或未知选项拒绝；没有 `--key=value`、裸布尔开关或通用参数透传。`--directory` 展开 `~`，其他值按所属命令验证。

典型顺序：

```bash
"$CLI" init-identity --directory "$IDENTITY_PATH"
"$CLI" prepare-trust --directory "$IDENTITY_PATH" --state "$TRUST_STATE_PATH"
"$CLI" apply-trust --state "$TRUST_STATE_PATH"
"$CLI" trust-status --state "$TRUST_STATE_PATH"
"$CLI" preflight --directory "$IDENTITY_PATH"
"$CLI" serve --directory "$IDENTITY_PATH" --latitude "$TARGET_LATITUDE" --longitude "$TARGET_LONGITUDE"
```

`serve` 是持续运行的前台进程。它不自动运行预检、安装信任、修改网络或请求定位权限。出现 `ready` 仅代表监听成功；SIGINT/SIGTERM 停止服务并正常退出。

退出码：`1` 表示通用参数、文件、helper 或运行错误；`2` 用于预检不通过；`probe` 的 `3` 表示没有完成新鲜读数，`4` 表示未得到距目标 100 米以内的接受结果。当前权限拒绝也会以非匹配结果退出，不能只凭 `4` 断言读到了一个其他位置，应同时看 JSON 事件。raw helper 的错误细节与 CLI 的错误包装不完全相同。

## 4. Surge 接入

`PROFILE_PATH` 必须是当前 profile，`NETWORK_STATE_PATH` 必须是仓库外的新目录；默认服务端口为 `19443`。

```bash
python3 scripts/surge-integration.py plan --profile "$PROFILE_PATH" --state "$NETWORK_STATE_PATH"
python3 scripts/surge-integration.py apply --profile "$PROFILE_PATH" --state "$NETWORK_STATE_PATH"
```

如果 `serve` 使用非默认端口，plan、apply、restore 必须全部传相同的 `--port "$SERVICE_PORT"`；App 当前固定端口，不提供端口选择。不能用默认端口恢复一个以其他端口创建的会话。

plan 仅展示将增加三个所属配置条目，不证明 TLS 或定位可用。apply 要求端口可连接，但这一 TCP 检查不验证对端一定是预期程序，仍应核对 ready 与进程所有权。

脚本保存私有 before-state、候选和 `state.json`，校验通过后才写 profile。候选或 before-state 可能含使用者的完整私有配置，不能复制到 Git、聊天、issue 或 CI。

若 apply 失败，先根据报错判断是否已写 profile。不能删除现场后盲目重试同名 state；未完成会话使用新目录，已写入的会话先按原元数据恢复。详细边界见 [Surge 说明](surge.md)。

## 5. 实机验收

按顺序收集独立证据，任一项失败就留在对应阶段：

1. **身份和范围：** 身份文件有效；受限设置匹配或预检满足相应条件。
2. **服务：** 正确程序监听指定 loopback 端口；没有未知程序占用。
3. **网络：** 正确 profile 生效，只增加两个精确域名的 locationd 规则，其他条目保留。
4. **协议：** 实际 locationd 请求进入 TLS/HTTP，服务有解析和完整响应证据；合成测试客户端的成功单独记录。
5. **系统：** 点击之后取得有效新鲜 Core Location；记录读取时间、实际水平精度、距目标距离。
6. **地图：** “我的位置”的坐标/楼宇与目标一致；不要将搜索结果或手动图钉当作当前位置。
7. **持续性：** 重启、休眠唤醒、网络切换、退出后重开和系统升级必须分别再验，未做即写未验。

App 当前要求时间不早于本次点击、且不超过当前时间未来 `2` 秒，没有另外的最大年龄过滤；CLI `probe` 还要求与当前时间绝对差小于 `5` 秒。App 的 `30` 秒 Timer 不是硬实时截止，可能受模态窗口或事件调度影响。人工验收还应核对显示的读取时间，必要时重新读取，不把两种实现混写成完全相同。

距离显示为 0 米是到目标的舍入结果，实际精度要读取单独的水平精度值。App 不自动确认地图，也不自动建立“全流程验收通过”状态。

## 6. 系统缓存与权限

- 先确认 App 在定位权限列表中允许读取；重新构建/签名后的权限需要独立检查，不以旧构建授权推定新构建已允许。
- 没有新请求或读数仍旧时，先区分系统缓存、网络规则、服务和权限，不叠加多种猜测性更改。
- 程序没有自动刷新定位服务、清理 Wi-Fi 数据库或重启 locationd 的功能。
- 如需手动关开系统定位服务，先查看系统对“查找我的 Mac”的提示并取得本次操作授权。关开后核对定位服务、App 权限和相应系统服务恢复开启。
- 不输入或收集使用者密码；无法取得认证时保留已确认状态，不伪称刷新完成。

## 7. 完整恢复的操作顺序

正常结束前，先用同一网络会话撤销接入：

```bash
python3 scripts/surge-integration.py restore --profile "$PROFILE_PATH" --state "$NETWORK_STATE_PATH"
```

确认所属规则已撤、Surge reload 成功后，在 App 停止服务，或者向**已经核对属于本服务**的 CLI 进程发送 SIGINT/SIGTERM。不能按模糊名称批量结束进程，也不能停止占用同端口的其他程序。

停止后移除本会话实验信任并核对：

```bash
"$CLI" restore-trust --state "$TRUST_STATE_PATH"
"$CLI" trust-status --state "$TRUST_STATE_PATH"
```

回读应为 `baseline_absent`；随后重新读取实际位置，必要时由使用者手动刷新缓存。网络/信任/服务恢复不等于已经得到新鲜真实坐标。不能因为回读成功就删除所有快照、历史材料或使用者的其他配置。

本机可能另外准备独立恢复脚本；那是特定会话的私有操作文件，不是项目自动发现、通用一键恢复或已经执行成功的证据。

## 8. 故障分诊与禁止的捷径

| 现象 | 优先检查 | 处理规则 |
|---|---|---|
| 窗口不出现但进程存活 | 原生 App 构造/布局异常 | 运行真实隐藏构造回归，不能以进程存在或编译通过结案 |
| 预检返回 2 | 身份、有效期、链、scoped 回读、系统 build | 按具体失败排查；不扩大为全局信任 |
| 无 ready 或端口失败 | 端口占用、P12 导入、macOS 版本 | 识别端口所有者，不批量 kill；13/14 不降回持久导入 |
| 没有连接 | 当前 profile、规则匹配、系统缓存 | 不能仅因计数 0 断言证书有问题 |
| TLS 阶段失败 | 客户端接受、链、主机、连接中断 | `tlsFailures` 不是特定 pinning 错误码，需补证据 |
| HTTP/响应阶段失败 | framing、请求大小、ARPC/protobuf、Wi-Fi 条目 | 拒绝未知格式；不增加任意透传或返回虚假成功 |
| 系统读数未变 | 真实请求/响应、Core Location 权限与新鲜性 | 服务响应成功不代替系统采纳 |
| 地图不同 | 是否“我的位置”、App 缓存/权限与独立 provider | 不用搜索图钉覆盖当前位置冒充通过 |
| 恢复被拒绝 | 旧 state、端口、外部编辑、签名/范围漂移 | 保留现场并人工复核，不用整库/整 profile 覆盖 |
| 已写 profile 但 reload 失败 | 私有 before-state 与当前文件 | 作为部分完成处理，用同一会话恢复 |

首次修复失败就更新假设并收集新证据。连续失败应形成最小复现、明确已排除项，重新评估适配路线；禁止反复重试同一假设或改 SIP、系统文件、绑定数据库作为默认方案。

## 9. 更换身份与升级

1. 保存源码、系统/build、旧会话和已验收边界。
2. 按第 7 节恢复网络、停止服务、移除旧叶记录，核对旧会话状态。
3. 新身份使用新目录；不得覆盖旧 P12 或删除旧快照来绕过保护。
4. 重新准备快照、配置受限信任、预检、启动和接入，再做系统/地图验收。
5. 更新兼容矩阵和变更记录。只有文档更新不提高程序版本；行为或依赖变化按版本规范处理。

没有证据时，不宣布整个系统大版本受支持，也不把单机成功解释为开机自启、长期持续或其他设备可用。
