import AppKit
import CoreLocation

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class MainWindowController: NSWindowController, CLLocationManagerDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let latitudeField = NSTextField(string: "")
    private let longitudeField = NSTextField(string: "")
    private let directoryField = NSTextField(labelWithString: "")
    private let compatibilityLabel = NSTextField(wrappingLabelWithString: "未预检。显式锚点 TLS 预检与系统定位验收是不同阶段。")
    private let serviceLabel = NSTextField(wrappingLabelWithString: "本地服务未启动。")
    private let trustLabel = NSTextField(wrappingLabelWithString: "尚未读取受限实验信任状态。只在显式点击安装后才请求系统更改。")
    private let actualLabel = NSTextField(wrappingLabelWithString: "尚未读取系统位置。输入目标不会改变这里的结果。")
    private let logView = NSTextView()
    private let chooseButton = NSButton(title: "选择已有身份目录…", target: nil, action: nil)
    private let identityButton = NSButton(title: "生成新身份", target: nil, action: nil)
    private let preflightButton = NSButton(title: "运行 TLS 预检", target: nil, action: nil)
    private let installTrustButton = NSButton(title: "安装受限实验信任…", target: nil, action: nil)
    private let removeTrustButton = NSButton(title: "移除受限实验信任", target: nil, action: nil)
    private let trustStatusButton = NSButton(title: "读取信任状态", target: nil, action: nil)
    private let startButton = NSButton(title: "启动本地服务", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止服务", target: nil, action: nil)
    private let probeButton = NSButton(title: "读取新的系统位置", target: nil, action: nil)
    private let locationManager = CLLocationManager()
    private var command: CLIInvocation?
    private var service: CLIInvocation?
    private var commandBusy = false
    private var serviceActive = false
    private var preflightPassed = false
    private var probeStartedAt: Date?
    private var probeTimer: Timer?
    private var rejectedCachedReadings = 0
    private var trustStatePath: String? {
        get { UserDefaults.standard.string(forKey: "activeTrustSessionPath") }
        set { UserDefaults.standard.set(newValue, forKey: "activeTrustSessionPath") }
    }

    private var identityURL: URL {
        URL(fileURLWithPath: directoryField.stringValue, isDirectory: true)
    }

    init() {
        let availableHeight = NSScreen.main?.visibleFrame.height ?? 950
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: min(940, availableHeight - 60)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "LocationBridge"
        window.minSize = NSSize(width: 760, height: 650)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        directoryField.stringValue = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocationBridge/Identity", isDirectory: true).path
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        buildInterface()
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let pageScroll = NSScrollView()
        pageScroll.translatesAutoresizingMaskIntoConstraints = false
        pageScroll.hasVerticalScroller = true
        pageScroll.autohidesScrollers = true
        pageScroll.drawsBackground = false
        content.addSubview(pageScroll)
        NSLayoutConstraint.activate([
            pageScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageScroll.topAnchor.constraint(equalTo: content.topAnchor),
            pageScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        pageScroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: pageScroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: pageScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: pageScroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: pageScroll.contentView.heightAnchor)
        ])
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])

        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let title = NSTextField(labelWithString: "LocationBridge")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        add(title)
        add(note("本机定位实验与独立验证。打开 App 不会修改证书信任、代理或系统定位设置。"))

        latitudeField.placeholderString = "纬度，-90～90"
        longitudeField.placeholderString = "经度，-180～180"
        for field in [latitudeField, longitudeField] {
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.delegate = self
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        }
        let targetRow = row([NSTextField(labelWithString: "纬度"), latitudeField,
                             NSTextField(labelWithString: "经度"), longitudeField])
        // Cross-view constraints require the shared hierarchy to exist first.
        latitudeField.widthAnchor.constraint(equalTo: longitudeField.widthAnchor).isActive = true
        add(section("目标坐标 · 仅用于服务配置", [targetRow,
            note("坐标仅保留在本次 App 会话中；保存或启动服务不代表系统位置已改变。")]))

        directoryField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        directoryField.lineBreakMode = .byTruncatingMiddle
        directoryField.isSelectable = true
        configure(chooseButton, action: #selector(chooseDirectory))
        configure(identityButton, action: #selector(generateIdentity))
        add(section("本机独立 TLS 身份", [directoryField, row([chooseButton, identityButton]),
            note("默认位于仓库外的 Application Support。生成身份不会安装证书或扩大系统信任。")]))

        configure(preflightButton, action: #selector(runPreflight))
        add(section("兼容状态", [row([preflightButton, compatibilityLabel]),
            note("服务需要 macOS 15 或更新版本。预检只检查指定显式锚点的 TLS 策略；系统信任和网络接入仍需另行配置与验证。")]))

        configure(installTrustButton, action: #selector(installExperimentalTrust))
        configure(removeTrustButton, action: #selector(removeExperimentalTrust))
        configure(trustStatusButton, action: #selector(readTrustStatus))
        add(section("受限实验信任", [row([installTrustButton, removeTrustButton, trustStatusButton]), trustLabel,
            note("仅限当前叶证书、两个精确定位域名及 locationd 签名。实验零错误例外未经文档保证，不增加根证书信任；实际 TLS 与系统定位另验。")]))

        configure(startButton, action: #selector(startService))
        configure(stopButton, action: #selector(stopService))
        add(section("本地服务", [row([startButton, stopButton]), serviceLabel]))

        configure(probeButton, action: #selector(readFreshLocation))
        actualLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        add(section("系统位置 · 直接读取 Core Location", [probeButton, actualLabel,
            note("仅接受点击读取后产生的新读数，等待最多 30 秒。接近输入目标仍需独立地图交叉验证。")]))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.isHorizontallyResizable = false
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        scroll.documentView = logView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        add(section("本次诊断 · 不记录定位请求正文", [scroll]))
        appendLog("尚未运行命令；没有自动开始定位或网络接入。")
    }

    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    private func refreshControls() {
        chooseButton.isEnabled = !commandBusy && !serviceActive
        identityButton.isEnabled = !commandBusy && !serviceActive
        preflightButton.isEnabled = !commandBusy && !serviceActive
        installTrustButton.isEnabled = !commandBusy && !serviceActive
        removeTrustButton.isEnabled = !commandBusy && !serviceActive && trustStatePath != nil
        trustStatusButton.isEnabled = !commandBusy && !serviceActive && trustStatePath != nil
        startButton.isEnabled = !commandBusy && !serviceActive && preflightPassed
        stopButton.isEnabled = serviceActive
        latitudeField.isEnabled = !serviceActive
        longitudeField.isEnabled = !serviceActive
        probeButton.isEnabled = probeStartedAt == nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard probeStartedAt == nil else { return }
        actualLabel.stringValue = "目标已编辑；系统位置不会由此改变。请点击读取新的系统位置，重新核对结果。"
    }

    private func invalidatePreflight(_ message: String = "身份目录已改变，请重新运行 TLS 预检。") {
        preflightPassed = false
        compatibilityLabel.stringValue = message
        compatibilityLabel.textColor = .labelColor
        refreshControls()
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择已有的本机身份目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard isOutsideGitCheckout(url) else {
            showError("请把私有身份保存在 Git 仓库外，不要选择源码目录。")
            return
        }
        directoryField.stringValue = url.path
        invalidatePreflight()
    }

    private func isOutsideGitCheckout(_ url: URL) -> Bool {
        var cursor = url.standardizedFileURL.resolvingSymlinksInPath()
        while true {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) { return false }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return true }
            cursor = parent
        }
    }

    @objc private func generateIdentity() {
        var destination = identityURL
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/LocationBridge", isDirectory: true)
                .appendingPathComponent("Identity-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        }
        guard isOutsideGitCheckout(destination) else {
            showError("身份目录必须在 Git 仓库外。")
            return
        }
        directoryField.stringValue = destination.path
        invalidatePreflight()
        runCommand(["init-identity", "--directory", destination.path], label: "生成本机身份") { [weak self] status, _ in
            guard let self else { return }
            self.compatibilityLabel.stringValue = status == 0
                ? "本机身份已生成；尚未运行 TLS 预检。未安装系统信任。"
                : "身份生成失败，请查看诊断；现有目录与证书未覆盖。"
        }
    }

    @objc private func runPreflight() {
        preflightPassed = false
        compatibilityLabel.stringValue = "正在运行只读 TLS 预检…"
        runCommand(["preflight", "--directory", identityURL.path], label: "TLS 预检") { [weak self] status, output in
            guard let self else { return }
            let report = self.jsonObject(in: output)
            let identityPresent = report?["identityPresent"] as? Bool == true
            let assessments = report?["pinningAssessmentWithExplicitAnchor"] as? [[String: Any]] ?? []
            let hosts = Set(assessments.compactMap { $0["hostname"] as? String })
            let expected: Set<String> = ["gs-loc.apple.com", "gs-loc-cn.apple.com"]
            let anchored = hosts == expected
                && assessments.count == expected.count
                && assessments.allSatisfy { $0["accepted"] as? Bool == true }
            let scoped = report?["locationdScopedTrustPresent"] as? Bool == true
            self.preflightPassed = status == 0 && identityPresent && (scoped || anchored)
            if self.preflightPassed && scoped {
                self.compatibilityLabel.stringValue = "受限实验信任已配置，实际兼容待验证。"
            } else if self.preflightPassed {
                self.compatibilityLabel.stringValue = "显式锚点预检通过；系统信任、网络接入和实际定位仍待验证。"
            } else {
                self.compatibilityLabel.stringValue = "实验／不兼容：预检未通过或回执不完整；系统定位未验证。"
            }
            self.compatibilityLabel.textColor = self.preflightPassed ? .labelColor : .systemOrange
            self.refreshControls()
        }
    }

    @objc private func installExperimentalTrust() {
        guard !commandBusy && !serviceActive, isOutsideGitCheckout(identityURL) else { return }
        guard trustStatePath == nil else {
            showError("已有保留的信任会话。请先读取状态并移除该会话，再安装另一身份，避免丢失旧会话的恢复句柄。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "安装受限的实验信任？"
        alert.informativeText = "将先保存当前状态，再在管理员信任域中只为当前叶证书添加两个精确 SSL 域名与 locationd 代码签名约束。TrustAsRoot=2、allowedError=0 的组合属于实验行为，0 值未经文档保证。不会增加根证书信任或修改代理；配置成功也不代表 TLS 或定位成功。macOS 可能要求管理员认证。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存快照并安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let stateURL = identityURL.deletingLastPathComponent()
            .appendingPathComponent("TrustSessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard isOutsideGitCheckout(stateURL) else {
            showError("信任会话快照必须保存在 Git 仓库外。")
            return
        }
        preflightPassed = false
        trustLabel.stringValue = "正在保存只读快照；尚未安装实验信任…"
        runCommand(["prepare-trust", "--directory", identityURL.path, "--state", stateURL.path], label: "保存实验信任快照") { [weak self] status, _ in
            guard let self else { return }
            guard status == 0 else {
                self.trustLabel.stringValue = "快照未完成，没有继续安装；现有信任不会被覆盖。"
                return
            }
            // Persist the restoration handle before any trust write can occur.
            self.trustStatePath = stateURL.path
            self.trustLabel.stringValue = "快照已保存，正在请求安装受限实验信任…"
            self.runCommand(["apply-trust", "--state", stateURL.path], label: "安装受限实验信任") { [weak self] applyStatus, output in
                guard let self else { return }
                let present = self.jsonObject(in: output)?["state"] as? String == "experimental_constraints_present"
                self.trustLabel.stringValue = applyStatus == 0 && present
                    ? "受限实验信任已配置；请重新运行预检，实际 TLS 与系统定位仍待验证。"
                    : "安装未确认成功。恢复会话已保留，请先读取状态，再按需移除本会话设置。"
                self.invalidatePreflight("信任操作已结束，请重新运行预检；实际兼容仍待验证。")
            }
        }
    }

    @objc private func readTrustStatus() {
        guard let state = trustStatePath else { return }
        runCommand(["trust-status", "--state", state], label: "读取受限实验信任状态") { [weak self] status, output in
            guard let self else { return }
            let state = self.jsonObject(in: output)?["state"] as? String
            if status == 0 && state == "experimental_constraints_present" {
                self.trustLabel.stringValue = "本会话精确约束仍在；实际兼容与系统定位未由此验证。"
            } else if status == 0 && state == "baseline_absent" {
                self.trustLabel.stringValue = "本会话叶证书设置处于原始缺省状态。"
            } else {
                self.trustLabel.stringValue = "无法确认本会话所有权，可能存在外部更改；不会自动覆盖或清除。"
            }
        }
    }

    @objc private func removeExperimentalTrust() {
        guard let state = trustStatePath, !serviceActive else { return }
        preflightPassed = false
        runCommand(["restore-trust", "--state", state], label: "移除本会话实验信任") { [weak self] status, output in
            guard let self else { return }
            if status == 0 && self.jsonObject(in: output)?["state"] as? String == "baseline_absent" {
                self.trustLabel.stringValue = "本会话叶证书实验设置已移除；其他信任与网络配置保持独立。"
                self.trustStatePath = nil
            } else {
                self.trustLabel.stringValue = "未确认移除完成；会话路径保留，外部更改不会被覆盖。"
            }
            self.invalidatePreflight("信任状态可能已改变，请重新运行预检。")
        }
    }

    private func runCommand(_ arguments: [String], label: String,
                            completion: @escaping (Int32, String) -> Void) {
        guard !commandBusy else { return }
        commandBusy = true
        refreshControls()
        appendLog(label + "开始。")
        do {
            command = try CLIInvocation(arguments: arguments, onLine: { [weak self] line in
                self?.appendLog(line)
            }, onExit: { [weak self] status, output in
                guard let self else { return }
                self.command = nil
                self.commandBusy = false
                self.appendLog(label + "结束，退出码 \(status)。")
                completion(status, output)
                self.refreshControls()
            })
        } catch {
            commandBusy = false
            appendLog(error.localizedDescription)
            completion(-1, "")
            refreshControls()
        }
    }

    @objc private func startService() {
        guard preflightPassed, !serviceActive else { return }
        do {
            let target = try CoordinateInput.parse(latitude: latitudeField.stringValue, longitude: longitudeField.stringValue)
            serviceActive = true
            serviceLabel.stringValue = "进程正在启动，等待本地监听就绪回执…"
            refreshControls()
            service = try CLIInvocation(arguments: ["serve", "--directory", identityURL.path,
                "--latitude", String(target.latitude), "--longitude", String(target.longitude), "--port", "19443"],
                onLine: { [weak self] line in
                    guard let self else { return }
                    self.appendLog(line)
                    if let event = self.jsonObject(in: line), event["event"] as? String == "ready",
                       event["address"] as? String == "127.0.0.1", event["port"] as? Int == 19443,
                       event["systemLocationVerified"] as? Bool == false {
                        self.serviceLabel.stringValue = "本地服务已监听 127.0.0.1:19443。网络接入及系统定位尚未验证。"
                    }
                }, onExit: { [weak self] status, _ in
                    guard let self else { return }
                    self.service = nil
                    self.serviceActive = false
                    self.serviceLabel.stringValue = "本地服务已停止，退出码 \(status)。这不代表已还原外部网络配置。"
                    self.appendLog("本地服务退出，退出码 \(status)。")
                    self.refreshControls()
                })
        } catch {
            serviceActive = false
            serviceLabel.stringValue = "服务没有启动。"
            showError(error.localizedDescription)
            refreshControls()
        }
    }

    @objc private func stopService() {
        serviceLabel.stringValue = "正在停止本地服务…"
        service?.stop()
    }

    @objc private func readFreshLocation() {
        probeStartedAt = Date()
        rejectedCachedReadings = 0
        actualLabel.stringValue = "等待新的 Core Location 读数；旧缓存不会用于验收…"
        refreshControls()
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.finishProbe(message: "30 秒内未取得有效的新位置。已忽略 \(self?.rejectedCachedReadings ?? 0) 个缓存或无效读数；系统定位未验证。")
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            finishProbe(message: "定位权限未允许。请在系统设置中为 LocationBridge 开启定位权限后重试。")
        @unknown default:
            finishProbe(message: "系统返回未知定位权限状态，无法进行独立验证。")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard probeStartedAt != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation()
        case .denied, .restricted: finishProbe(message: "系统定位权限未允许，尚未取得新的位置。")
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let startedAt = probeStartedAt else { return }
        guard let location = locations.reversed().first(where: {
            FreshLocationFilter.accepts(timestamp: $0.timestamp, horizontalAccuracy: $0.horizontalAccuracy, requestedAt: startedAt)
                && CLLocationCoordinate2DIsValid($0.coordinate)
        }) else {
            rejectedCachedReadings += locations.count
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        var message = String(format: "系统新鲜读数：纬度 %.6f，经度 %.6f\n精度 ±%.0f 米；读取时间 %@。",
            location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy,
            formatter.string(from: location.timestamp))
        if let target = try? CoordinateInput.parse(latitude: latitudeField.stringValue, longitude: longitudeField.stringValue) {
            let distance = location.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
            message += String(format: "\n距当前输入目标约 %.0f 米；独立地图验证尚未完成。", distance)
        }
        finishProbe(message: message)
        appendLog("已取得本次请求后的系统定位读数；坐标仅在结果区显示，不写入诊断。")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard probeStartedAt != nil else { return }
        if (error as? CLError)?.code == .locationUnknown { return }
        finishProbe(message: "系统读取失败：\(error.localizedDescription)。系统定位未验证。")
    }

    private func finishProbe(message: String) {
        locationManager.stopUpdatingLocation()
        probeTimer?.invalidate()
        probeTimer = nil
        probeStartedAt = nil
        actualLabel.stringValue = message
        refreshControls()
    }

    private func jsonObject(in text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return result }
        for line in text.split(separator: "\n").reversed() {
            if let data = String(line).data(using: .utf8),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return result }
        }
        return nil
    }

    private func appendLog(_ text: String) {
        let line = String(text.prefix(16_384))
        let updated = logView.string + line + "\n"
        logView.string = String(updated.suffix(32_768))
        logView.scrollToEndOfDocument(nil)
    }

    private func showError(_ text: String) {
        appendLog(text)
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    func stopOwnedActivity() {
        command?.stop()
        service?.stop()
        locationManager.stopUpdatingLocation()
        probeTimer?.invalidate()
    }

    func permitsApplicationTermination() -> Bool {
        guard !commandBusy else {
            let alert = NSAlert()
            alert.messageText = "操作仍在进行，请完成或取消后再退出"
            alert.informativeText = "请先等待当前命令结束。如果系统认证窗口已打开，请在该窗口完成或取消认证，然后再退出。强制退出不能保证中止已开始的信任操作；恢复快照会保留在仓库外。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "继续等待")
            alert.runModal()
            return false
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        permitsApplicationTermination()
    }
}
