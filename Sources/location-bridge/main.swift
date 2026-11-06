import Foundation
import Darwin
import CoreLocation
import LocationBridgeCore

func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
        print(text)
        fflush(stdout)
    }
}

struct Arguments {
    let verb: String
    let values: [String: String]
    init(_ input: [String]) throws {
        verb = input.first ?? "help"
        let allowed: [String: Set<String>] = ["help": [], "init-identity": ["directory"], "preflight": ["directory"], "serve": ["directory", "latitude", "longitude", "port", "accuracy"], "probe": ["latitude", "longitude", "timeout"], "prepare-trust": ["directory", "state"], "apply-trust": ["state"], "restore-trust": ["state"], "trust-status": ["state"]]
        guard let keys = allowed[verb] else { throw CommandError("Unknown command: \(verb)") }
        var parsed = [String: String]()
        var index = 1
        while index < input.count {
            let flag = input[index]
            guard flag.hasPrefix("--"), index + 1 < input.count else { throw CommandError("Expected --option value") }
            let key = String(flag.dropFirst(2))
            guard keys.contains(key), parsed[key] == nil else { throw CommandError("Unknown or duplicate option: \(flag)") }
            parsed[key] = input[index + 1]
            index += 2
        }
        values = parsed
    }
    func number(_ key: String, default fallback: Double? = nil) throws -> Double {
        guard let text = values[key] else {
            if let fallback { return fallback }
            throw CommandError("Missing --\(key)")
        }
        guard let number = Double(text), number.isFinite else { throw CommandError("Invalid --\(key)") }
        return number
    }
    var directory: URL {
        if let path = values["directory"] { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true).standardizedFileURL }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocationBridge/Identity", isDirectory: true)
    }
}

final class FreshLocationProbe: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    let began = Date()
    let target: CLLocation
    var finished = false
    var matched = false
    init(latitude: Double, longitude: Double) {
        target = CLLocation(latitude: latitude, longitude: longitude)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    func start() { manager.requestWhenInUseAuthorization(); manager.startUpdatingLocation() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, CLLocationCoordinate2DIsValid(fix.coordinate),
              fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0,
              fix.timestamp >= began, abs(fix.timestamp.timeIntervalSinceNow) < 5 else { return }
        let distance = fix.distance(from: target)
        matched = distance <= 100
        emit(["event": "fresh-location", "fresh": true, "distanceToTargetMeters": distance, "horizontalAccuracyMeters": fix.horizontalAccuracy, "within100Meters": matched, "mapCrossCheckVerified": false])
        finished = true
        manager.stopUpdatingLocation()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as NSError).code == CLError.denied.rawValue {
            emit(["event": "location-error", "error": "Location permission denied; use the app's native probe and authorize it in System Settings"])
            finished = true
        }
    }
}

do {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    switch args.verb {
    case "help":
        print("""
        LocationBridge 0.1.0 — local macOS location protocol lab
        init-identity [--directory PATH]   Generate a private identity; never overwrite
        preflight [--directory PATH]       Read-only TLS assessment, not locationd proof
        serve --latitude LAT --longitude LON [--directory PATH] [--port 19443] [--accuracy 10]
        probe --latitude LAT --longitude LON [--timeout 30]
        prepare-trust --directory PATH --state NEW_PRIVATE_PATH
        apply-trust --state PATH           Explicit experimental leaf/app/host exception
        restore-trust --state PATH         Remove only this exact session's leaf exception
        trust-status --state PATH          Read-only scope/ownership check
        serve does not configure network or certificate trust. SIGINT/SIGTERM stops it.
        """)
    case "init-identity":
        try LocalIdentity.generate(in: args.directory)
        emit(["event": "identity-created", "privateKeyShared": false, "trustSettingsChanged": false])
    case "preflight":
        let report = try LocalIdentity.preflight(args.directory)
        emit(report)
        let checks = report["pinningAssessmentWithExplicitAnchor"] as? [[String: Any]] ?? []
        let scoped = report["locationdScopedTrustPresent"] as? Bool == true
        if !scoped && (checks.count != 2 || checks.contains(where: { $0["accepted"] as? Bool != true })) { exit(2) }
    case "prepare-trust", "apply-trust", "restore-trust", "trust-status":
        guard let path = args.values["state"] else { throw CommandError("Missing --state private session directory") }
        let state = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let helper = trustHelperURL()
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw CommandError("Build the app bundle first; its sibling trust helper is required") }
        var arguments: [String]
        if args.verb == "prepare-trust" {
            try preparePrivateStateParent(state)
            arguments = ["prepare", args.directory.appendingPathComponent("leaf.pem").path, args.directory.appendingPathComponent("root.pem").path, state.path]
        } else {
            let verb = ["apply-trust": "apply", "restore-trust": "restore", "trust-status": "check"][args.verb]!
            arguments = [verb, state.path]
            if verb != "check" { arguments.append("--confirm-experimental-leaf-anchor-zero") }
        }
        let text = try command(helper.path, arguments)
        guard let data = text.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CommandError("Invalid trust helper receipt") }
        emit(raw.filter { ["state", "systemTrustChanged", "realLocationVerified", "snapshotCreated", "domain", "application", "hosts", "allowedError", "trustResult", "experimentalLeafAnchor", "noBroadTrust", "addsRootTrust", "undocumentedExperimentalBehavior"].contains($0.key) })
    case "serve":
        let target = try TargetCoordinate(latitude: args.number("latitude"), longitude: args.number("longitude"), horizontalAccuracy: args.number("accuracy", default: 10))
        let number = try args.number("port", default: 19443)
        guard number.rounded() == number, number >= 1024, number <= 65535 else { throw CommandError("Port must be an integer from 1024 to 65535") }
        guard LocalIdentity.present(args.directory) else { throw CommandError("Run init-identity first") }
        let password = try String(contentsOf: args.directory.appendingPathComponent("password.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let config = try BridgeServerConfiguration(identityP12URL: args.directory.appendingPathComponent("identity.p12"), password: password, target: target, port: UInt16(number))
        let server = LocationBridgeServer(configuration: config)
        try server.start()
        emit(["event": "ready", "address": "127.0.0.1", "port": Int(number), "systemLocationVerified": false])
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        for source in [interrupt, terminate] {
            source.setEventHandler { server.stop(); exit(0) }
            source.resume()
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let counterEncoder = JSONEncoder()
        counterEncoder.outputFormatting = [.sortedKeys]
        var previousCounters: Data?
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            let snapshot = server.snapshot()
            if let data = try? counterEncoder.encode(snapshot), data != previousCounters,
               let counters = try? JSONSerialization.jsonObject(with: data) {
                previousCounters = data
                emit(["event": "counters", "counters": counters])
            }
        }
        timer.resume()
        withExtendedLifetime([server, interrupt, terminate, timer] as [Any]) { RunLoop.main.run() }
    case "probe":
        let target = try TargetCoordinate(latitude: args.number("latitude"), longitude: args.number("longitude"))
        let timeout = try args.number("timeout", default: 30)
        guard (1...120).contains(timeout) else { throw CommandError("Timeout must be from 1 to 120 seconds") }
        let probe = FreshLocationProbe(latitude: target.latitude, longitude: target.longitude)
        probe.start()
        let deadline = Date().addingTimeInterval(timeout)
        while !probe.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if !probe.finished { emit(["event": "location-timeout", "fresh": false]); exit(3) }
        if !probe.matched { exit(4) }
    default: break
    }
} catch {
    fputs("LocationBridge: \(error.localizedDescription)\n", stderr)
    exit(1)
}
