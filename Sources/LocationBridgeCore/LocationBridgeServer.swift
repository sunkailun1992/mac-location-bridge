// CONNECT/CFStream processing informed by WLoc v1.2 (MIT).
// See ThirdParty/WLoc/PROVENANCE.md for the original source and local changes.
import CFNetwork
import Darwin
import Foundation
import Security

public struct BridgeServerConfiguration {
    public let identityP12URL: URL
    let password: String
    public let target: TargetCoordinate
    public let port: UInt16
    public let maxConcurrentClients: Int
    public let requestTimeout: TimeInterval
    public let maximumHeaderBytes: Int
    public let maximumBodyBytes: Int

    public init(identityP12URL: URL, password: String, target: TargetCoordinate,
                port: UInt16 = 19443, maxConcurrentClients: Int = 8,
                requestTimeout: TimeInterval = 10, maximumHeaderBytes: Int = 32_768,
                maximumBodyBytes: Int = 1_048_576) throws {
        guard identityP12URL.isFileURL, port >= 1024, (1...64).contains(maxConcurrentClients),
              requestTimeout.isFinite, (1...30).contains(requestTimeout),
              (1024...65_536).contains(maximumHeaderBytes),
              (1...1_048_576).contains(maximumBodyBytes) else { throw BridgeError.invalidConfiguration }
        self.identityP12URL = identityP12URL
        self.password = password
        self.target = target
        self.port = port
        self.maxConcurrentClients = maxConcurrentClients
        self.requestTimeout = requestTimeout
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }
}

public struct BridgeServerSnapshot: Codable, Sendable {
    public let listening: Bool
    public let acceptedConnections: UInt64
    public let activeConnections: Int
    public let rejectedConnections: UInt64
    public let tlsFailures: UInt64
    public let requestFailures: UInt64
    public let parsedRequests: UInt64
    public let syntheticResponses: UInt64
}

public final class LocationBridgeServer: @unchecked Sendable {
    private let configuration: BridgeServerConfiguration
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "location-bridge.accept")
    private let workers = DispatchQueue(label: "location-bridge.clients", qos: .utility, attributes: .concurrent)
    private var source: DispatchSourceRead?
    private var sourceCancelled: DispatchSemaphore?
    private var listening = false
    private var target: TargetCoordinate
    private var clients: [UUID: SocketHandle] = [:]
    private var accepted: UInt64 = 0
    private var rejected: UInt64 = 0
    private var tlsFailures: UInt64 = 0
    private var requestFailures: UInt64 = 0
    private var requests: UInt64 = 0
    private var responses: UInt64 = 0

    public init(configuration: BridgeServerConfiguration) {
        self.configuration = configuration
        target = configuration.target
    }

    public func setTarget(_ target: TargetCoordinate) {
        stateLock.lock(); defer { stateLock.unlock() }
        self.target = target
    }

    public func snapshot() -> BridgeServerSnapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        return BridgeServerSnapshot(listening: listening, acceptedConnections: accepted,
                                    activeConnections: clients.count, rejectedConnections: rejected,
                                    tlsFailures: tlsFailures, requestFailures: requestFailures,
                                    parsedRequests: requests, syntheticResponses: responses)
    }

    public func start() throws {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard source == nil else { throw BridgeError.alreadyRunning }
        let certificates = try TLSIdentityLoader.load(configuration)
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw BridgeError.socketFailure }
        let listener = SocketHandle(descriptor)
        var transferred = false
        defer { if !transferred { listener.close() } }
        var yes: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            throw BridgeError.socketFailure
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(descriptor, Int32(configuration.maxConcurrentClients)) == 0 else {
            throw BridgeError.socketFailure
        }
        let cancelled = DispatchSemaphore(value: 0)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in self?.acceptClients(descriptor, certificates: certificates) }
        readSource.setCancelHandler { listener.close(); cancelled.signal() }
        stateLock.lock(); listening = true; stateLock.unlock()
        source = readSource
        sourceCancelled = cancelled
        transferred = true
        readSource.resume()
    }

    public func stop() {
        lifecycleLock.lock()
        let oldSource = source
        let cancelled = sourceCancelled
        source = nil
        sourceCancelled = nil
        stateLock.lock()
        listening = false
        let active = Array(clients.values)
        stateLock.unlock()
        oldSource?.cancel()
        // Interrupt reads without closing a descriptor borrowed by CF streams.
        active.forEach { $0.shutdown() }
        if oldSource != nil { _ = cancelled?.wait(timeout: .now() + 2) }
        lifecycleLock.unlock()
    }

    private func acceptClients(_ listener: Int32, certificates: [Any]) {
        // Bound each dispatch-source turn so a connection flood cannot starve stop.
        for _ in 0..<64 {
            let fd = accept(listener, nil, nil)
            if fd < 0 { return }
            let socket = SocketHandle(fd)
            let id = UUID()
            stateLock.lock()
            accepted += 1
            let allowed = listening && clients.count < configuration.maxConcurrentClients
            if allowed { clients[id] = socket } else { rejected += 1 }
            stateLock.unlock()
            guard allowed else { socket.close(); continue }
            workers.async { [self] in
                handle(socket, certificates: certificates)
                stateLock.lock(); clients.removeValue(forKey: id); stateLock.unlock()
            }
        }
    }

    private func handle(_ socket: SocketHandle, certificates: [Any]) {
        defer { socket.close() }
        let fd = socket.descriptor
        var enteredTLS = false
        var receivedHTTPHeader = false
        do {
            try configure(fd)
            let deadline = Date().addingTimeInterval(configuration.requestTimeout)
            let header = try readConnectHeader(fd, deadline: deadline)
            let connect = try ConnectTarget.parse(header, headerLimit: configuration.maximumHeaderBytes)
            try writeRaw(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), fd: fd)
            enteredTLS = true
            try handleTLS(fd, host: connect.host, certificates: certificates, deadline: deadline, receivedHTTPHeader: &receivedHTTPHeader)
        } catch {
            stateLock.lock()
            if receivedHTTPHeader { requestFailures += 1 }
            else if enteredTLS { tlsFailures += 1 }
            else { rejected += 1 }
            stateLock.unlock()
        }
    }

    private func configure(_ fd: Int32) throws {
        var yes: Int32 = 1
        var timeout = timeval(tv_sec: Int(configuration.requestTimeout), tv_usec: 0)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw BridgeError.socketFailure
        }
    }

    private func readConnectHeader(_ fd: Int32, deadline: Date) throws -> Data {
        // One-byte reads deliberately avoid consuming a pipelined TLS ClientHello.
        var data = Data()
        while !data.hasSuffixBytes([13, 10, 13, 10]) {
            guard Date() < deadline else { throw BridgeError.malformedRequest }
            guard data.count < configuration.maximumHeaderBytes else { throw BridgeError.requestTooLarge }
            var byte: UInt8 = 0
            let count = recv(fd, &byte, 1, 0)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw BridgeError.malformedRequest }
            data.append(byte)
        }
        return data
    }

    private func handleTLS(_ fd: Int32, host: String, certificates: [Any], deadline: Date, receivedHTTPHeader: inout Bool) throws {
        var readRef: Unmanaged<CFReadStream>?
        var writeRef: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &readRef, &writeRef)
        guard let input = readRef?.takeRetainedValue(), let output = writeRef?.takeRetainedValue() else {
            throw BridgeError.socketFailure
        }
        defer { CFReadStreamClose(input); CFWriteStreamClose(output) }
        let closeKey = CFStreamPropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket)
        let sslKey = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings)
        let ssl = [kCFStreamSSLIsServer as String: true, kCFStreamSSLCertificates as String: certificates] as CFDictionary
        guard CFReadStreamSetProperty(input, closeKey, kCFBooleanFalse),
              CFWriteStreamSetProperty(output, closeKey, kCFBooleanFalse),
              CFReadStreamSetProperty(input, sslKey, ssl), CFWriteStreamSetProperty(output, sslKey, ssl),
              CFReadStreamOpen(input), CFWriteStreamOpen(output) else { throw BridgeError.socketFailure }
        let stream = input as InputStream
        var data = Data()
        let delimiter = Data([13, 10, 13, 10])
        var range: Range<Data.Index>?
        while range == nil {
            guard Date() < deadline else { throw BridgeError.malformedRequest }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { throw BridgeError.malformedRequest }
            data.append(contentsOf: buffer.prefix(count))
            range = data.range(of: delimiter)
            guard (range?.upperBound ?? data.count) <= configuration.maximumHeaderBytes else { throw BridgeError.requestTooLarge }
        }
        let boundary = range!.upperBound
        receivedHTTPHeader = true
        let head = try LocationRequestHeader.parse(Data(data[..<boundary]), connectHost: host,
                                                  bodyLimit: configuration.maximumBodyBytes,
                                                  headerLimit: configuration.maximumHeaderBytes)
        var body = Data(data[boundary...])
        guard body.count <= head.contentLength else { throw BridgeError.malformedRequest }
        while body.count < head.contentLength {
            guard Date() < deadline else { throw BridgeError.malformedRequest }
            var buffer = [UInt8](repeating: 0, count: min(8192, head.contentLength - body.count))
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { throw BridgeError.malformedRequest }
            body.append(contentsOf: buffer.prefix(count))
        }
        stateLock.lock(); requests += 1; let requestTarget = target; stateLock.unlock()
        let response = try WLocResponseBuilder.build(requestBody: body, target: requestTarget)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(response.count)\r\nConnection: close\r\n\r\n"
        let out = output as OutputStream
        try writeStream(Data(header.utf8), stream: out, deadline: deadline)
        try writeStream(response, stream: out, deadline: deadline)
        stateLock.lock(); responses += 1; stateLock.unlock()
    }

    private func writeRaw(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = send(fd, pointer.advanced(by: offset), raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeError.socketFailure }
                offset += count
            }
        }
    }

    private func writeStream(_ data: Data, stream: OutputStream, deadline: Date) throws {
        try data.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < raw.count {
                guard Date() < deadline else { throw BridgeError.socketFailure }
                let count = stream.write(pointer.advanced(by: offset), maxLength: raw.count - offset)
                guard count > 0 else { throw BridgeError.socketFailure }
                offset += count
            }
        }
    }

    deinit { stop() }
}

private enum TLSIdentityLoader {
    static func load(_ configuration: BridgeServerConfiguration) throws -> [Any] {
        // Never silently import a caller's private key into the user's keychain.
        guard #available(macOS 15.0, *) else { throw BridgeError.identityUnavailable }
        let attributes = try FileManager.default.attributesOfItem(atPath: configuration.identityP12URL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 4_194_304 else {
            throw BridgeError.identityUnavailable
        }
        let data = try Data(contentsOf: configuration.identityP12URL)
        let options = [kSecImportExportPassphrase as String: configuration.password,
                       kSecImportToMemoryOnly as String: true] as CFDictionary
        var imported: CFArray?
        guard SecPKCS12Import(data as CFData, options, &imported) == errSecSuccess,
              let items = imported as? [[String: Any]], items.count == 1,
              let rawIdentity = items.first?[kSecImportItemIdentity as String] else { throw BridgeError.identityUnavailable }
        let identity = rawIdentity as! SecIdentity
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else { throw BridgeError.identityUnavailable }
        var result: [Any] = [identity]
        for certificate in items[0][kSecImportItemCertChain as String] as? [SecCertificate] ?? [] {
            if !CFEqual(certificate, leaf) { result.append(certificate) }
        }
        return result
    }
}

private extension Data {
    func hasSuffixBytes(_ bytes: [UInt8]) -> Bool { suffix(bytes.count).elementsEqual(bytes) }
}
