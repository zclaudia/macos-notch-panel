import Foundation

public enum IslandSchema {
    public static let version = 1
    public static let maxTextLength = 120
    public static let maxTrailingLength = 40
    public static let maxBodyLength = 280
    public static let maxActions = 3
    public static let maxSymbolLength = 64
    public static let maxFrameBytes = 64 * 1024
    public static let minPresentDuration: TimeInterval = 0.4
    public static let maxPresentDuration: TimeInterval = 30
}

public enum IslandProtocolError: Error, Equatable {
    case unsupportedSchema
    case invalidPayload
    case frameTooLarge
    case notFound
    case notAllowed
    case rateLimited
    case unsupportedMethod
    case unavailable
}

public enum IslandPriority: String, Codable, Equatable {
    case low
    case normal
    case high

    public var rank: Int {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .high: return 2
        }
    }
}

public struct IslandCompactContent: Codable, Equatable {
    public var symbolName: String?
    public var title: String
    public var trailingText: String?
    public var progress: Double?

    public init(symbolName: String? = nil, title: String, trailingText: String? = nil, progress: Double? = nil) {
        self.symbolName = symbolName
        self.title = title
        self.trailingText = trailingText
        self.progress = progress
    }
}

public struct IslandExpandedContent: Codable, Equatable {
    public var title: String
    public var body: String?
    public var progress: Double?

    public init(title: String, body: String? = nil, progress: Double? = nil) {
        self.title = title
        self.body = body
        self.progress = progress
    }
}

public struct IslandAction: Codable, Equatable {
    public enum Kind: String, Codable {
        case openURL
        case dismiss
        case callback
    }

    public var name: String
    public var title: String
    public var kind: Kind
    public var url: String?
    public var callbackName: String?

    public init(name: String, title: String, kind: Kind, url: String? = nil, callbackName: String? = nil) {
        self.name = name
        self.title = title
        self.kind = kind
        self.url = url
        self.callbackName = callbackName
    }
}

public struct IslandActivity: Codable, Equatable, Identifiable {
    public var id: String
    public var priority: IslandPriority
    public var compact: IslandCompactContent
    public var expanded: IslandExpandedContent?
    public var expiresAt: Date?
    public var actions: [IslandAction]

    public init(
        id: String,
        priority: IslandPriority = .normal,
        compact: IslandCompactContent,
        expanded: IslandExpandedContent? = nil,
        expiresAt: Date? = nil,
        actions: [IslandAction] = []
    ) {
        self.id = id
        self.priority = priority
        self.compact = compact
        self.expanded = expanded
        self.expiresAt = expiresAt
        self.actions = actions
    }
}

public struct IslandRequest: Codable, Equatable {
    public var schemaVersion: Int
    public var requestId: String
    public var method: String
    public var activity: IslandActivity?
    public var activityId: String?
    public var duration: Double?

    public init(
        schemaVersion: Int = IslandSchema.version,
        requestId: String,
        method: String,
        activity: IslandActivity? = nil,
        activityId: String? = nil,
        duration: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.method = method
        self.activity = activity
        self.activityId = activityId
        self.duration = duration
    }
}

public struct IslandMessage: Codable, Equatable {
    public var schemaVersion: Int
    public var kind: String
    public var requestId: String?
    public var ok: Bool?
    public var error: String?
    public var activityId: String?
    public var event: String?
    public var actionName: String?

    public init(
        schemaVersion: Int = IslandSchema.version,
        kind: String,
        requestId: String? = nil,
        ok: Bool? = nil,
        error: String? = nil,
        activityId: String? = nil,
        event: String? = nil,
        actionName: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.requestId = requestId
        self.ok = ok
        self.error = error
        self.activityId = activityId
        self.event = event
        self.actionName = actionName
    }

    public static func response(requestId: String, ok: Bool, error: IslandProtocolError? = nil, activityId: String? = nil) -> IslandMessage {
        IslandMessage(
            kind: "response",
            requestId: requestId,
            ok: ok,
            error: error.map(IslandCodec.errorCode),
            activityId: activityId
        )
    }

    public static func event(name: String, activityId: String, actionName: String? = nil) -> IslandMessage {
        IslandMessage(kind: "event", activityId: activityId, event: name, actionName: actionName)
    }
}

public struct IslandServerEvent: Equatable {
    public var name: String
    public var activityId: String
    public var actionName: String?

    public init(name: String, activityId: String, actionName: String? = nil) {
        self.name = name
        self.activityId = activityId
        self.actionName = actionName
    }
}

public enum IslandCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func errorCode(_ error: IslandProtocolError) -> String {
        switch error {
        case .unsupportedSchema: return "unsupported_schema"
        case .invalidPayload: return "invalid_payload"
        case .frameTooLarge: return "frame_too_large"
        case .notFound: return "not_found"
        case .notAllowed: return "not_allowed"
        case .rateLimited: return "rate_limited"
        case .unsupportedMethod: return "unsupported_method"
        case .unavailable: return "unavailable"
        }
    }
}

public enum IslandActivityValidation {
    public static func validate(_ activity: IslandActivity) throws -> IslandActivity {
        guard isIdentifier(activity.id, maxLength: 64) else { throw IslandProtocolError.invalidPayload }
        guard activity.actions.count <= IslandSchema.maxActions else { throw IslandProtocolError.invalidPayload }

        var copy = activity
        copy.compact.title = try text(activity.compact.title, max: IslandSchema.maxTextLength, allowEmpty: false)
        copy.compact.trailingText = try optionalText(activity.compact.trailingText, max: IslandSchema.maxTrailingLength)
        copy.compact.symbolName = try symbol(activity.compact.symbolName)
        copy.compact.progress = try progress(activity.compact.progress)

        if let expanded = activity.expanded {
            copy.expanded = IslandExpandedContent(
                title: try text(expanded.title, max: IslandSchema.maxTextLength, allowEmpty: false),
                body: try optionalText(expanded.body, max: IslandSchema.maxBodyLength),
                progress: try progress(expanded.progress)
            )
        }

        if let expiresAt = activity.expiresAt {
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining.isFinite, remaining > 0, remaining <= 24 * 60 * 60 else {
                throw IslandProtocolError.invalidPayload
            }
        }

        copy.actions = try activity.actions.map(validateAction)
        return copy
    }

    public static func clampedPresentDuration(_ duration: TimeInterval) -> TimeInterval? {
        guard duration.isFinite else { return nil }
        return min(IslandSchema.maxPresentDuration, max(IslandSchema.minPresentDuration, duration))
    }

    public static func isIdentifier(_ value: String, maxLength: Int) -> Bool {
        guard (1...maxLength).contains(value.count) else { return false }
        guard let first = value.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func isSymbol(_ value: String) -> Bool {
        guard (1...IslandSchema.maxSymbolLength).contains(value.count) else { return false }
        guard let first = value.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "."))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Structural URL check. The panel additionally requires http(s) or a scheme registered on this Mac.
    public static func isStructurallyAllowedURL(_ string: String) -> Bool {
        guard string.count <= 2048, !string.contains(where: \.isWhitespace) else { return false }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        if url.user != nil || url.password != nil { return false }
        let blocked = ["file", "javascript", "data", "about", "blob", "shell"]
        if blocked.contains(scheme) { return false }
        guard scheme.range(of: #"^[a-z][a-z0-9+\-.]*$"#, options: .regularExpression) != nil else { return false }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty, host.count <= 253 else { return false }
        }
        return true
    }

    private static func validateAction(_ action: IslandAction) throws -> IslandAction {
        guard isIdentifier(action.name, maxLength: 32) else { throw IslandProtocolError.invalidPayload }
        var copy = action
        copy.title = try text(action.title, max: IslandSchema.maxTrailingLength, allowEmpty: false)
        switch action.kind {
        case .dismiss:
            copy.url = nil
            copy.callbackName = nil
        case .openURL:
            guard let url = action.url, isStructurallyAllowedURL(url) else { throw IslandProtocolError.invalidPayload }
            copy.url = url
            copy.callbackName = nil
        case .callback:
            guard let name = action.callbackName, isIdentifier(name, maxLength: 32) else {
                throw IslandProtocolError.invalidPayload
            }
            copy.callbackName = name
            copy.url = nil
        }
        return copy
    }

    private static func text(_ value: String, max: Int, allowEmpty: Bool) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !allowEmpty { throw IslandProtocolError.invalidPayload }
        if trimmed.count > max { throw IslandProtocolError.invalidPayload }
        if trimmed.unicodeScalars.contains(where: { $0.value < 32 }) { throw IslandProtocolError.invalidPayload }
        return trimmed
    }

    private static func optionalText(_ value: String?, max: Int) throws -> String? {
        guard let value else { return nil }
        let trimmed = try text(value, max: max, allowEmpty: true)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func symbol(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard isSymbol(trimmed) else { throw IslandProtocolError.invalidPayload }
        return trimmed
    }

    private static func progress(_ value: Double?) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, (0...1).contains(value) else { throw IslandProtocolError.invalidPayload }
        return value
    }
}

public enum IslandSocketPath {
    public static let fileName = "island.sock"
    public static let bundleIdentifier = "theboringteam.boringnotch"
    /// `sockaddr_un.sun_path` holds 104 bytes including the trailing NUL.
    public static let maxPathBytes = 103

    public static func applicationSupportSocket() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("boringNotch", isDirectory: true).appendingPathComponent(fileName)
    }

    public static func homeSocket() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".boringnotch", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func containerSocket() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/boringNotch", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Prefers Application Support when that path fits in a Unix socket address.
    /// Sandbox containers are usually longer than `sun_path`, so the panel falls back to `~/.boringnotch`.
    public static func preferredServerSocket() -> URL {
        let candidates = [applicationSupportSocket(), homeSocket()]
        return candidates.first { $0.path.utf8.count <= maxPathBytes } ?? homeSocket()
    }

    public static func clientCandidates() -> [URL] {
        var seen = Set<String>()
        return [preferredServerSocket(), homeSocket(), containerSocket(), applicationSupportSocket()].filter { url in
            seen.insert(url.path).inserted
        }
    }
}
