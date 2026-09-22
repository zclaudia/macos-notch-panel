import AppKit
import Darwin
import Foundation
import IslandKit
import Security

struct IslandPeerIdentity {
    var approvalKey: String
    var displayName: String
    var executablePath: String

    // Stable across CLI invocations, but distinct for different executable paths.
    var clientId: String { "\(approvalKey)|\(executablePath)" }
}

enum IslandApprovalStore {
    private static let allowKey = "island.approvedClients"
    private static let denyKey = "island.deniedClients"
    private static let maxEntries = 200

    static func isAllowed(_ key: String) -> Bool? {
        if allowed().contains(key) { return true }
        if denied().contains(key) { return false }
        return nil
    }

    static func allow(_ key: String) {
        var allowList = allowed()
        var denyList = denied()
        denyList.removeAll { $0 == key }
        if !allowList.contains(key) { allowList.append(key) }
        if allowList.count > maxEntries { allowList.removeFirst(allowList.count - maxEntries) }
        UserDefaults.standard.set(allowList, forKey: allowKey)
        UserDefaults.standard.set(denyList, forKey: denyKey)
    }

    static func deny(_ key: String) {
        var allowList = allowed()
        var denyList = denied()
        allowList.removeAll { $0 == key }
        if !denyList.contains(key) { denyList.append(key) }
        if denyList.count > maxEntries { denyList.removeFirst(denyList.count - maxEntries) }
        UserDefaults.standard.set(allowList, forKey: allowKey)
        UserDefaults.standard.set(denyList, forKey: denyKey)
    }

    private static func allowed() -> [String] {
        UserDefaults.standard.stringArray(forKey: allowKey) ?? []
    }

    private static func denied() -> [String] {
        UserDefaults.standard.stringArray(forKey: denyKey) ?? []
    }
}

final class IslandSocketServer {
    static let shared = IslandSocketServer()

    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "island.socket.accept")
    private var listenFD: Int32 = -1
    private var socketPath: String?
    private var stopped = false
    private var activeConnections = 0
    private var connections: [String: (clientId: String, writer: IslandMessageWriter)] = [:]
    private var rateWindows: [String: [TimeInterval]] = [:]
    private let maxConnections = 8

    private init() {}

    func start() {
        IslandMainActor.run {
            IslandCenter.shared.onServerEvent = { clientId, event in
                IslandSocketServer.shared.send(clientId: clientId, event: event)
            }
        }
        acceptQueue.async { [weak self] in
            self?.listenLoop()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        let path = socketPath
        let open = connections
        connections.removeAll()
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        if let path { unlink(path) }
        for connection in open.values { connection.writer.close() }
    }

    func send(clientId: String, event: IslandServerEvent) {
        lock.lock()
        let writers = connections.values.filter { $0.clientId == clientId }.map { $0.writer }
        lock.unlock()
        let message = IslandMessage.event(name: event.name, activityId: event.activityId, actionName: event.actionName)
        for writer in writers { writer.enqueue(message) }
    }

    private func listenLoop() {
        let path = IslandSocketPath.preferredServerSocket().path
        do {
            let fd = try IslandFraming.bindListeningSocket(path: path)
            lock.lock()
            if stopped {
                lock.unlock()
                Darwin.close(fd)
                unlink(path)
                return
            }
            listenFD = fd
            socketPath = path
            lock.unlock()
            Logger.log("Island socket listening", category: .lifecycle)
        } catch {
            Logger.log("Island socket did not start", category: .error)
            return
        }

        while true {
            lock.lock()
            let fd = listenFD
            let shouldStop = stopped
            lock.unlock()
            if shouldStop || fd < 0 { break }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            lock.lock()
            let overloaded = activeConnections >= maxConnections || stopped
            if !overloaded { activeConnections += 1 }
            lock.unlock()
            if overloaded {
                Darwin.close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client)
                self?.lock.lock()
                self?.activeConnections -= 1
                self?.lock.unlock()
            }
        }
    }

    private func handle(_ fd: Int32) {
        defer { Darwin.close(fd) }
        guard let connection = try? IslandMessageWriter(fd: fd) else { return }
        defer { connection.close() }
        guard let pid = IslandFraming.peerPID(fd), let identity = Self.identity(for: pid) else { return }
        let allowed = IslandMainActor.run { Self.resolveApproval(identity) }
        guard allowed else { return }

        let clientId = identity.clientId
        let connectionId = UUID().uuidString.lowercased()
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        connections[connectionId] = (clientId, connection)
        lock.unlock()
        defer {
            lock.lock()
            connections[connectionId] = nil
            lock.unlock()
            IslandMainActor.run {
                // Activities belong to the program, not this transport connection.
                IslandCenter.shared.clearUnusedIcon(for: clientId)
            }
        }

        let icon = NSWorkspace.shared.icon(forFile: identity.executablePath)
        icon.size = NSSize(width: 32, height: 32)
        IslandMainActor.run {
            IslandCenter.shared.setIcon(icon, for: clientId)
        }
        Logger.log("Island client connected", category: .lifecycle)

        while true {
            let frame: Data?
            do {
                frame = try IslandFraming.readFrame(fd)
            } catch {
                return
            }
            guard let frame else { return }
            guard allowRate(clientId) else {
                if let request = try? IslandFraming.decodeRequest(frame) {
                    let requestId = IslandActivityValidation.isIdentifier(request.requestId, maxLength: 64) ? request.requestId : "rejected"
                    guard connection.enqueue(IslandMessage.response(requestId: requestId, ok: false, error: .rateLimited)) else { return }
                }
                continue
            }
            guard let request = try? IslandFraming.decodeRequest(frame) else {
                guard connection.enqueue(IslandMessage.response(requestId: "rejected", ok: false, error: .invalidPayload)) else { return }
                continue
            }
            let response = IslandMainActor.run {
                IslandCenter.shared.ingest(request, clientId: clientId)
            }
            guard connection.enqueue(response) else { return }
        }
    }

    private func allowRate(_ clientId: String) -> Bool {
        let now = Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        // Preserve limits across reconnects while discarding inactive client entries.
        rateWindows = rateWindows.filter { _, stamps in
            stamps.contains { now - $0 < 1 }
        }
        var stamps = rateWindows[clientId] ?? []
        stamps.removeAll { now - $0 >= 1 }
        guard stamps.count < 8 else {
            rateWindows[clientId] = stamps
            return false
        }
        stamps.append(now)
        rateWindows[clientId] = stamps
        return true
    }

    private static func resolveApproval(_ identity: IslandPeerIdentity) -> Bool {
        if let existing = IslandApprovalStore.isAllowed(identity.approvalKey) { return existing }
        let alert = NSAlert()
        alert.messageText = "Allow \(identity.displayName) to show notch notifications?"
        alert.informativeText = identity.executablePath
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate(ignoringOtherApps: true)
        let allowed = alert.runModal() == .alertFirstButtonReturn
        if allowed {
            IslandApprovalStore.allow(identity.approvalKey)
        } else {
            IslandApprovalStore.deny(identity.approvalKey)
        }
        return allowed
    }

    private static func identity(for pid: pid_t) -> IslandPeerIdentity? {
        let length = 4 * 1024
        var buffer = [CChar](repeating: 0, count: length)
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let rawPath = String(cString: buffer)
        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        guard resolved.hasPrefix("/"), !resolved.contains("\0"), resolved.count <= 1024 else { return nil }
        let bundleId = bundleIdentifier(pid: pid)
        if let bundleId, isBundleIdentifier(bundleId) {
            let name = FileManager.default.displayName(atPath: resolved)
            return IslandPeerIdentity(approvalKey: "bundle:\(bundleId)", displayName: name, executablePath: resolved)
        }
        let name = URL(fileURLWithPath: resolved).lastPathComponent
        guard !name.isEmpty, name.count <= 255 else { return nil }
        return IslandPeerIdentity(approvalKey: "path:\(resolved)", displayName: name, executablePath: resolved)
    }

    private static func bundleIdentifier(pid: pid_t) -> String? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &guest) == errSecSuccess,
              let guest
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoIdentifier as String] as? String
    }

    private static func isBundleIdentifier(_ value: String) -> Bool {
        guard (1...220).contains(value.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
