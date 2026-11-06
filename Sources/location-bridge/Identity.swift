import Foundation
import Security
import Darwin

struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

func trustHelperURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("locationbridge-trust")
}

func preparePrivateStateParent(_ state: URL) throws {
    let fm = FileManager.default
    var ancestor = state.deletingLastPathComponent()
    while ancestor.path != "/" {
        let attributes = try? fm.attributesOfItem(atPath: ancestor.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw CommandError("Trust state cannot use symlink ancestors")
        }
        if fm.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
            throw CommandError("Trust state must stay outside every Git checkout")
        }
        ancestor.deleteLastPathComponent()
    }
    let parent = state.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let attributes = try fm.attributesOfItem(atPath: parent.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    guard attributes[.type] as? FileAttributeType == .typeDirectory, permissions & 0o077 == 0 else {
        throw CommandError("Trust session parent must be a private directory (0700)")
    }
}

@discardableResult
func command(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CommandError("Command failed (\(URL(fileURLWithPath: executable).lastPathComponent), exit \(process.terminationStatus))")
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

enum LocalIdentity {
    static let names = ["identity.p12", "password.txt", "leaf.pem", "root.pem"]

    static func present(_ directory: URL) -> Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func generate(in destination: URL) throws {
        let fm = FileManager.default
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else {
            throw CommandError("Identity destination already exists; choose a new directory. Existing identities are never overwritten.")
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".locationbridge-identity-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let oldMask = umask(0o077)
        defer { umask(oldMask) }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw CommandError("Cannot generate a private identity password")
        }
        let password = Data(random).base64EncodedString()
        let config = """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = LocationBridge Local Device
        [root]
        basicConstraints = critical,CA:TRUE,pathlen:0
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        [leaf]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:gs-loc.apple.com,DNS:gs-loc-cn.apple.com
        authorityKeyIdentifier = keyid,issuer
        subjectKeyIdentifier = hash
        """
        let configURL = temporary.appendingPathComponent("openssl.cnf")
        try Data(config.utf8).write(to: configURL, options: .withoutOverwriting)
        func path(_ name: String) -> String { temporary.appendingPathComponent(name).path }
        try command("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "365", "-config", configURL.path, "-extensions", "root", "-keyout", path("root.key"), "-out", path("root.pem")])
        try command("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-config", configURL.path, "-subj", "/CN=gs-loc.apple.com", "-keyout", path("leaf.key"), "-out", path("leaf.csr")])
        try command("/usr/bin/openssl", ["x509", "-req", "-in", path("leaf.csr"), "-CA", path("root.pem"), "-CAkey", path("root.key"), "-CAcreateserial", "-sha256", "-days", "90", "-extfile", configURL.path, "-extensions", "leaf", "-out", path("leaf.pem")])
        var environment = ProcessInfo.processInfo.environment
        environment["LOCATION_BRIDGE_EXPORT_PASSWORD"] = password
        try command("/usr/bin/openssl", ["pkcs12", "-export", "-out", path("identity.p12"), "-inkey", path("leaf.key"), "-in", path("leaf.pem"), "-certfile", path("root.pem"), "-name", "LocationBridge Device Identity", "-passout", "env:LOCATION_BRIDGE_EXPORT_PASSWORD"], environment: environment)
        try Data(password.utf8).write(to: temporary.appendingPathComponent("password.txt"), options: .withoutOverwriting)
        for file in try fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
            if names.contains(file.lastPathComponent) {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } else {
                try fm.removeItem(at: file)
            }
        }
        // The move fails on a concurrent creator; it never replaces an existing destination.
        try fm.moveItem(at: temporary, to: destination)
    }

    static func certificate(_ url: URL) throws -> SecCertificate {
        let pem = try String(contentsOf: url, encoding: .utf8)
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: base64), let cert = SecCertificateCreateWithData(nil, data as CFData) else {
            throw CommandError("Invalid local certificate")
        }
        return cert
    }

    static func preflight(_ directory: URL) throws -> [String: Any] {
        let available = present(directory)
        var scopedTrust = false
        var assessments = [[String: Any]]()
        if available {
            let helper = trustHelperURL()
            if FileManager.default.isExecutableFile(atPath: helper.path),
               let text = try? command(helper.path, ["inspect", directory.appendingPathComponent("leaf.pem").path, directory.appendingPathComponent("root.pem").path]),
               let data = text.data(using: .utf8),
               let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                scopedTrust = receipt["locationdScopedTrustPresent"] as? Bool == true
            }
            let leaf = try certificate(directory.appendingPathComponent("leaf.pem"))
            let root = try certificate(directory.appendingPathComponent("root.pem"))
            for hostname in ["gs-loc.apple.com", "gs-loc-cn.apple.com"] {
                var trust: SecTrust?
                let status = SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateSSL(true, hostname as CFString), &trust)
                guard status == errSecSuccess, let trust else { throw CommandError("Cannot create TLS assessment") }
                SecTrustSetAnchorCertificates(trust, [root] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                SecTrustSetNetworkFetchAllowed(trust, false)
                var error: CFError?
                let accepted = SecTrustEvaluateWithError(trust, &error)
                let result = SecTrustCopyResult(trust) as? [String: Any] ?? [:]
                let details = result["TrustResultDetails"] as? [[String: Any]] ?? []
                let keys = Array(Set(details.flatMap { $0.keys })).sorted()
                assessments.append(["hostname": hostname, "accepted": accepted, "errorCode": error.map { CFErrorGetCode($0) } ?? 0, "failureKeys": keys])
            }
        }
        return ["osVersion": try command("/usr/bin/sw_vers", ["-productVersion"]), "buildVersion": try command("/usr/bin/sw_vers", ["-buildVersion"]), "identityPresent": available, "locationdScopedTrustPresent": scopedTrust, "pinningAssessmentWithExplicitAnchor": assessments, "systemLocationVerified": false, "assessmentScope": "caller-owned SecTrust and optional exact locationd trust-settings match; does not establish live locationd acceptance or modify trust settings"]
    }
}
