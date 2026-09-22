import Darwin
import Foundation

/// Bounded, ordered output for a socket connection. Enqueue and close never wait for socket writes.
public final class IslandMessageWriter: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "island.socket.writer")
    private let lock = NSLock()
    private let maxPendingMessages: Int
    private var pending = 0
    private var closed = false

    /// Duplicates the descriptor. The caller continues to own its original descriptor.
    public init(fd: Int32, maxPendingMessages: Int = 64) throws {
        guard maxPendingMessages > 0 else { throw IslandProtocolError.invalidPayload }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw IslandProtocolError.unavailable }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var enabled: Int32 = 1
        guard setsockopt(duplicate, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(duplicate, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0
        else {
            Darwin.close(duplicate)
            throw IslandProtocolError.unavailable
        }
        self.fd = duplicate
        self.maxPendingMessages = maxPendingMessages
    }

    deinit { Darwin.close(fd) }

    /// Disconnects a slow peer when the queue fills or a write fails.
    @discardableResult
    public func enqueue(_ message: IslandMessage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        guard pending < maxPendingMessages else {
            closed = true
            shutdown(fd, SHUT_RDWR)
            return false
        }
        pending += 1
        queue.async {
            defer {
                self.lock.lock()
                self.pending -= 1
                self.lock.unlock()
            }
            self.lock.lock()
            let shouldWrite = !self.closed
            self.lock.unlock()
            guard shouldWrite else { return }
            do {
                try IslandFraming.writeFrame(self.fd, message)
            } catch {
                self.close()
            }
        }
        return true
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        // Also wakes the connection's reader. The duplicate stays alive until queued work finishes.
        shutdown(fd, SHUT_RDWR)
    }
}
