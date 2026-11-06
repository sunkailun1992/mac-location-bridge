import Darwin
import Foundation

// Sole owner of a native descriptor. CF streams must only borrow this socket.
final class SocketHandle {
    private let lock = NSLock()
    private var value: Int32
    init(_ descriptor: Int32) { value = descriptor }
    var descriptor: Int32 { lock.lock(); defer { lock.unlock() }; return value }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard value >= 0 else { return }
        Darwin.close(value)
        value = -1
    }
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if value >= 0 { Darwin.shutdown(value, SHUT_RDWR) }
    }
    deinit { close() }
}
