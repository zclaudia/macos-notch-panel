import AppKit
import Defaults
import Foundation
import IslandKit
import SwiftUI

enum IslandBuiltinKind: Equatable {
    case hud(SneakContentType, CGFloat, String)
    case battery
}

struct IslandItem: Equatable, Identifiable {
    var activity: IslandActivity
    var clientId: String
    var builtin: IslandBuiltinKind?
    var sequence: UInt64

    var id: String { "\(clientId)/\(activity.id)" }

    func matches(_ other: IslandItem) -> Bool {
        clientId == other.clientId && activity.id == other.activity.id
    }
}

enum IslandMainActor {
    static func run<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }
}

@MainActor
final class IslandCenter: ObservableObject {
    static let shared = IslandCenter()
    static let builtinClientID = "builtin.boringnotch"

    @Published private(set) var visible: IslandItem?
    var onServerEvent: ((String, IslandServerEvent) -> Void)?

    private var queue: [IslandItem] = []
    private var sequence: UInt64 = 0
    private var expiryTask: Task<Void, Never>?
    private var activitiesByClient: [String: Set<String>] = [:]
    private var expandedKeys: Set<String> = []
    private var icons: [String: NSImage] = [:]
    private let maxPerClient = 8
    private let maxQueued = 32

    private init() {}

    func setIcon(_ image: NSImage?, for clientId: String) {
        icons[clientId] = image
    }

    func icon(for clientId: String) -> NSImage? {
        icons[clientId]
    }

    func clearUnusedIcon(for clientId: String) {
        if activitiesByClient[clientId] == nil {
            icons[clientId] = nil
        }
    }

    @discardableResult
    func present(
        activity: IslandActivity,
        duration: TimeInterval,
        clientId: String,
        builtin: IslandBuiltinKind? = nil
    ) -> IslandProtocolError? {
        guard let duration = IslandActivityValidation.clampedPresentDuration(duration) else {
            return .invalidPayload
        }
        var timed = activity
        timed.expiresAt = Date().addingTimeInterval(duration)
        return upsert(timed, clientId: clientId, builtin: builtin, keepExistingExpiry: false)
    }

    @discardableResult
    func start(activity: IslandActivity, clientId: String) -> IslandProtocolError? {
        upsert(activity, clientId: clientId, builtin: nil, keepExistingExpiry: false)
    }

    @discardableResult
    func update(activity: IslandActivity, clientId: String) -> IslandProtocolError? {
        let exists = (visible?.clientId == clientId && visible?.activity.id == activity.id)
            || queue.contains { $0.clientId == clientId && $0.activity.id == activity.id }
        guard exists else { return .notFound }
        let builtin = builtinKind(clientId: clientId, activityId: activity.id)
        return upsert(activity, clientId: clientId, builtin: builtin, keepExistingExpiry: activity.expiresAt == nil)
    }

    func end(id: String, clientId: String, event: String = "dismiss") {
        if let current = visible, current.activity.id == id, current.clientId == clientId {
            expiryTask?.cancel()
            expiryTask = nil
            withAnimation(.smooth) { visible = nil }
            forget(current)
            expandedKeys.remove(current.id)
            emit(current, event: event)
            promote()
            return
        }
        guard let index = queue.firstIndex(where: { $0.activity.id == id && $0.clientId == clientId }) else { return }
        let item = queue.remove(at: index)
        forget(item)
        expandedKeys.remove(item.id)
        emit(item, event: event)
    }

    func endAll(clientId: String) {
        let ids = activitiesByClient[clientId] ?? []
        for id in ids {
            end(id: id, clientId: clientId)
        }
        icons[clientId] = nil
    }

    func endBuiltinHUD() {
        let ids = (activitiesByClient[Self.builtinClientID] ?? []).filter { $0.hasPrefix("builtin.hud.") }
        for id in ids {
            end(id: id, clientId: Self.builtinClientID)
        }
    }

    func noteExpanded(_ item: IslandItem) {
        guard expandedKeys.insert(item.id).inserted else { return }
        emit(item, event: "expand")
    }

    func perform(_ action: IslandAction, on item: IslandItem) {
        switch action.kind {
        case .dismiss:
            end(id: item.activity.id, clientId: item.clientId)
        case .openURL:
            guard let raw = action.url, Self.acceptsURL(raw), let url = URL(string: raw) else { return }
            NSWorkspace.shared.open(url)
        case .callback:
            emit(item, event: "action", actionName: action.callbackName)
        }
    }

    static func hudActivityID(_ type: SneakContentType) -> String? {
        switch type {
        case .volume: return "builtin.hud.volume"
        case .brightness: return "builtin.hud.brightness"
        case .backlight: return "builtin.hud.backlight"
        case .mic: return "builtin.hud.mic"
        default: return nil
        }
    }

    func presentBuiltinHUD(type: SneakContentType, value: CGFloat, icon: String, duration: TimeInterval) {
        guard type == .volume || type == .brightness || type == .backlight || type == .mic else { return }
        guard Defaults[.hudReplacement] else { return }
        let clamped = min(1, max(0, value))
        let title: String
        let trailing: String?
        let progress: Double?
        switch type {
        case .volume:
            title = "Volume"
            trailing = clamped == 0 ? "muted" : "\(Int((clamped * 100).rounded()))%"
            progress = Double(clamped)
        case .brightness:
            title = "Brightness"
            trailing = "\(Int((clamped * 100).rounded()))%"
            progress = Double(clamped)
        case .backlight:
            title = "Backlight"
            trailing = "\(Int((clamped * 100).rounded()))%"
            progress = Double(clamped)
        case .mic:
            title = "Mic"
            trailing = clamped > 0 ? "unmuted" : "muted"
            progress = nil
        default:
            return
        }
        guard let activityID = Self.hudActivityID(type) else { return }
        let activity = IslandActivity(
            id: activityID,
            priority: .high,
            compact: IslandCompactContent(
                symbolName: hudSymbol(type: type, value: clamped, icon: icon),
                title: title,
                trailingText: trailing,
                progress: progress
            )
        )
        _ = present(
            activity: activity,
            duration: duration,
            clientId: Self.builtinClientID,
            builtin: .hud(type, clamped, icon)
        )
    }

    func ingest(_ request: IslandRequest, clientId: String) -> IslandMessage {
        let requestId = IslandActivityValidation.isIdentifier(request.requestId, maxLength: 64) ? request.requestId : "rejected"
        guard request.schemaVersion == IslandSchema.version else {
            return .response(requestId: requestId, ok: false, error: .unsupportedSchema)
        }
        guard requestId != "rejected" else {
            return .response(requestId: requestId, ok: false, error: .invalidPayload)
        }
        switch request.method {
        case "present":
            guard let activity = request.activity, let duration = request.duration else {
                return .response(requestId: requestId, ok: false, error: .invalidPayload)
            }
            if let error = present(activity: activity, duration: duration, clientId: clientId) {
                return .response(requestId: requestId, ok: false, error: error)
            }
            return .response(requestId: requestId, ok: true, activityId: activity.id)
        case "start":
            guard let activity = request.activity else {
                return .response(requestId: requestId, ok: false, error: .invalidPayload)
            }
            if let error = start(activity: activity, clientId: clientId) {
                return .response(requestId: requestId, ok: false, error: error)
            }
            return .response(requestId: requestId, ok: true, activityId: activity.id)
        case "update":
            guard let activity = request.activity else {
                return .response(requestId: requestId, ok: false, error: .invalidPayload)
            }
            let activityId = request.activityId ?? activity.id
            guard activityId == activity.id else {
                return .response(requestId: requestId, ok: false, error: .invalidPayload)
            }
            if let error = update(activity: activity, clientId: clientId) {
                return .response(requestId: requestId, ok: false, error: error)
            }
            return .response(requestId: requestId, ok: true, activityId: activity.id)
        case "end":
            guard let activityId = request.activityId else {
                return .response(requestId: requestId, ok: false, error: .invalidPayload)
            }
            let known = (visible?.clientId == clientId && visible?.activity.id == activityId)
                || queue.contains { $0.clientId == clientId && $0.activity.id == activityId }
            guard known else {
                return .response(requestId: requestId, ok: false, error: .notFound)
            }
            end(id: activityId, clientId: clientId)
            return .response(requestId: requestId, ok: true, activityId: activityId)
        default:
            return .response(requestId: requestId, ok: false, error: .unsupportedMethod)
        }
    }

    static func acceptsURL(_ string: String) -> Bool {
        guard IslandActivityValidation.isStructurallyAllowedURL(string),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased()
        else { return false }
        if scheme == "http" || scheme == "https" { return true }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    private func upsert(
        _ raw: IslandActivity,
        clientId: String,
        builtin: IslandBuiltinKind?,
        keepExistingExpiry: Bool
    ) -> IslandProtocolError? {
        let activity: IslandActivity
        do {
            activity = try IslandActivityValidation.validate(raw)
        } catch let error as IslandProtocolError {
            return error
        } catch {
            return .invalidPayload
        }
        for action in activity.actions where action.kind == .openURL {
            guard let url = action.url, Self.acceptsURL(url) else { return .invalidPayload }
        }

        sequence += 1
        var item = IslandItem(activity: activity, clientId: clientId, builtin: builtin, sequence: sequence)
        if keepExistingExpiry, let existing = existingItem(matching: item) {
            item.activity.expiresAt = existing.activity.expiresAt
            item.sequence = existing.sequence
        }

        if let current = visible, current.matches(item) {
            show(item)
            return nil
        }
        if let index = queue.firstIndex(where: { $0.matches(item) }) {
            queue.remove(at: index)
            return place(item)
        }
        guard (activitiesByClient[clientId]?.count ?? 0) < maxPerClient else { return .rateLimited }
        remember(item)
        return place(item)
    }

    private func place(_ item: IslandItem) -> IslandProtocolError? {
        if visible == nil {
            show(item)
            return nil
        }
        if item.activity.priority == .high {
            parkVisible()
            show(item)
            return nil
        }
        guard queue.count < maxQueued else {
            forget(item)
            return .rateLimited
        }
        queue.append(item)
        return nil
    }

    private func parkVisible() {
        guard let current = visible else { return }
        expiryTask?.cancel()
        expiryTask = nil
        visible = nil
        if let expires = current.activity.expiresAt, expires <= Date() {
            forget(current)
            emit(current, event: "dismiss")
            return
        }
        queue.insert(current, at: 0)
    }

    private func show(_ item: IslandItem) {
        withAnimation(.smooth) {
            visible = item
        }
        scheduleExpiry(for: item)
    }

    private func scheduleExpiry(for item: IslandItem) {
        expiryTask?.cancel()
        guard let expires = item.activity.expiresAt else {
            expiryTask = nil
            return
        }
        let delay = expires.timeIntervalSinceNow
        if delay <= 0 {
            end(id: item.activity.id, clientId: item.clientId)
            return
        }
        let token = item.id
        let shownSequence = item.sequence
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard let visible = self.visible, visible.id == token, visible.sequence == shownSequence else { return }
            self.end(id: visible.activity.id, clientId: visible.clientId)
        }
    }

    private func promote() {
        let now = Date()
        queue.removeAll { item in
            guard let expires = item.activity.expiresAt, expires <= now else { return false }
            forget(item)
            emit(item, event: "dismiss")
            return true
        }
        guard visible == nil, !queue.isEmpty else { return }
        queue.sort { lhs, rhs in
            if lhs.activity.priority.rank != rhs.activity.priority.rank {
                return lhs.activity.priority.rank > rhs.activity.priority.rank
            }
            return lhs.sequence < rhs.sequence
        }
        show(queue.removeFirst())
    }

    private func existingItem(matching item: IslandItem) -> IslandItem? {
        if let visible, visible.matches(item) { return visible }
        return queue.first { $0.matches(item) }
    }

    private func builtinKind(clientId: String, activityId: String) -> IslandBuiltinKind? {
        if let visible, visible.clientId == clientId, visible.activity.id == activityId { return visible.builtin }
        return queue.first { $0.clientId == clientId && $0.activity.id == activityId }?.builtin
    }

    private func remember(_ item: IslandItem) {
        var ids = activitiesByClient[item.clientId] ?? []
        ids.insert(item.activity.id)
        activitiesByClient[item.clientId] = ids
    }

    private func forget(_ item: IslandItem) {
        var ids = activitiesByClient[item.clientId] ?? []
        ids.remove(item.activity.id)
        if ids.isEmpty {
            activitiesByClient[item.clientId] = nil
            icons[item.clientId] = nil
        } else {
            activitiesByClient[item.clientId] = ids
        }
    }

    private func emit(_ item: IslandItem, event: String, actionName: String? = nil) {
        guard item.clientId != Self.builtinClientID else { return }
        onServerEvent?(item.clientId, IslandServerEvent(name: event, activityId: item.activity.id, actionName: actionName))
    }

    private func hudSymbol(type: SneakContentType, value: CGFloat, icon: String) -> String? {
        if IslandActivityValidation.isSymbol(icon) { return icon }
        switch type {
        case .volume:
            if value == 0 { return "speaker.slash" }
            if value < 0.3 { return "speaker.wave.1" }
            if value < 0.8 { return "speaker.wave.2" }
            return "speaker.wave.3"
        case .brightness:
            return value < 0.6 ? "sun.min" : "sun.max"
        case .backlight:
            return value > 0.5 ? "light.max" : "light.min"
        case .mic:
            return "mic"
        default:
            return nil
        }
    }
}
