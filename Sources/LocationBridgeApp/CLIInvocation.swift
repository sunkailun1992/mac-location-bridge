import Foundation

/// Owns one child process and its pipe. No shell, privilege prompt, or trust/network write.
final class CLIInvocation {
    let process = Process()
    private let pipe = Pipe()

    init(arguments: [String], onLine: @escaping (String) -> Void,
         onExit: @escaping (Int32, String) -> Void) throws {
        guard let executable = Bundle.main.executableURL else {
            throw InvocationError.missingCLI
        }
        let cli = executable.deletingLastPathComponent().appendingPathComponent("location-bridge")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw InvocationError.missingCLI
        }
        process.executableURL = cli
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        DispatchQueue.global(qos: .utility).async { [self] in
            var captured = Data()
            var pending = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if captured.count < 131_072 {
                    captured.append(chunk.prefix(131_072 - captured.count))
                }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    DispatchQueue.main.async { onLine(line) }
                }
                // A malformed child output must not create an unbounded UI buffer.
                if pending.count > 16_384 { pending.removeAll(keepingCapacity: true) }
            }
            if !pending.isEmpty {
                let line = String(decoding: pending, as: UTF8.self)
                DispatchQueue.main.async { onLine(line) }
            }
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
            let status = process.terminationStatus
            let text = String(decoding: captured, as: UTF8.self)
            DispatchQueue.main.async { onExit(status, text) }
        }
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    enum InvocationError: LocalizedError {
        case missingCLI

        var errorDescription: String? {
            "未找到同目录的 location-bridge。请使用 scripts/build-app.sh 构建完整 App。"
        }
    }
}
