import Darwin
import Foundation

public final class IslandClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let stateLock = NSLock()
    private var pending: [String: (IslandMessage) -> Void] = [:]
    private var requestCounter = 0
    private var closed = false
    private let onEventLock = NSLock()
    private let eventQueue = DispatchQueue(label: "island.client.events")
    private var eventHandler: (@Sendable (IslandServerEvent) -> Void)?

    /// Delivered in order on a separate queue. Handlers may call the synchronous client APIs.
    public var onEvent: (@Sendable (IslandServerEvent) -> Void)? {
        get {
            onEventLock.lock()
            defer { onEventLock.unlock() }
            return eventHandler
        }
        set {
            onEventLock.lock()
            eventHandler = newValue
            onEventLock.unlock()
        }
    }

    public static func connect(socketPath: URL) throws -> IslandClient {
        try IslandClient(fd: IslandFraming.connect(path: socketPath.path))
    }

    public static func connect() throws -> IslandClient {
        var lastError: Error = IslandProtocolError.unavailable
        for url in IslandSocketPath.clientCandidates() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                return try IslandClient(fd: IslandFraming.connect(path: url.path))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private init(fd: Int32) {
        self.fd = fd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readLoop()
        }
    }

    public func present(_ activity: IslandActivity, duration: TimeInterval = 3) throws -> String {
        let response = try send(IslandRequest(
            requestId: nextRequestId(),
            method: "present",
            activity: activity,
            duration: duration
        ))
        return try activityId(from: response)
    }

    public func start(_ activity: IslandActivity) throws -> String {
        let response = try send(IslandRequest(
            requestId: nextRequestId(),
            method: "start",
            activity: activity
        ))
        return try activityId(from: response)
    }

    public func update(_ activity: IslandActivity) throws {
        _ = try send(IslandRequest(
            requestId: nextRequestId(),
            method: "update",
            activity: activity,
            activityId: activity.id
        ))
    }

    public func end(id: String) throws {
        _ = try send(IslandRequest(
            requestId: nextRequestId(),
            method: "end",
            activityId: id
        ))
    }

    public func close() {
        lock.lock()
        if !closed {
            closed = true
            // Wake the reader; it owns the final close so the descriptor cannot be reused mid-read.
            shutdown(fd, SHUT_RDWR)
        }
        lock.unlock()
        failPending()
    }

    private func nextRequestId() -> String {
        lock.lock()
        requestCounter += 1
        let value = requestCounter
        lock.unlock()
        return "r\(value)"
    }

    private func send(_ request: IslandRequest) throws -> IslandMessage {
        let semaphore = DispatchSemaphore(value: 0)
        var received: IslandMessage?
        stateLock.lock()
        pending[request.requestId] = { message in
            received = message
            semaphore.signal()
        }
        stateLock.unlock()

        do {
            try write(request)
        } catch {
            _ = takePending(request.requestId)
            throw error
        }

        let wait = semaphore.wait(timeout: .now() + 30)
        guard wait == .success, let received else {
            _ = takePending(request.requestId)
            throw IslandProtocolError.unavailable
        }
        guard received.ok == true else {
            throw error(from: received.error)
        }
        return received
    }

    private func activityId(from message: IslandMessage) throws -> String {
        guard let activityId = message.activityId else { throw IslandProtocolError.unavailable }
        return activityId
    }

    private func error(from code: String?) -> IslandProtocolError {
        switch code {
        case "unsupported_schema": return .unsupportedSchema
        case "invalid_payload": return .invalidPayload
        case "frame_too_large": return .frameTooLarge
        case "not_found": return .notFound
        case "not_allowed": return .notAllowed
        case "rate_limited": return .rateLimited
        case "unsupported_method": return .unsupportedMethod
        default: return .unavailable
        }
    }

    private func write(_ request: IslandRequest) throws {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw IslandProtocolError.unavailable }
        try IslandFraming.writeFrame(fd, request)
    }

    private func readLoop() {
        defer { Darwin.close(fd) }
        while true {
            do {
                guard let frame = try IslandFraming.readFrame(fd) else {
                    close()
                    return
                }
                let message = try IslandFraming.decodeMessage(frame)
                if message.kind == "response", let requestId = message.requestId, let handler = takePending(requestId) {
                    handler(message)
                    continue
                }
                if message.kind == "event", let name = message.event, let activityId = message.activityId {
                    let event = IslandServerEvent(name: name, activityId: activityId, actionName: message.actionName)
                    onEventLock.lock()
                    let handler = eventHandler
                    onEventLock.unlock()
                    if let handler {
                        eventQueue.async { handler(event) }
                    }
                }
            } catch {
                close()
                return
            }
        }
    }

    private func takePending(_ requestId: String) -> ((IslandMessage) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending.removeValue(forKey: requestId)
    }

    private func failPending() {
        stateLock.lock()
        let handlers = pending
        pending.removeAll()
        stateLock.unlock()
        let failure = IslandMessage.response(requestId: "", ok: false, error: .unavailable)
        for handler in handlers.values {
            handler(failure)
        }
    }
}
