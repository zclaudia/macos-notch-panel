import Foundation
import IslandKit

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first else {
    printUsage()
    exit(2)
}

do {
    switch command {
    case "present", "start", "update":
        let activity = try activity(from: arguments)
        let client = try IslandClient.connect()
        defer { client.close() }
        switch command {
        case "present":
            let duration = doubleFlag("--duration", in: arguments) ?? 3
            let id = try client.present(activity, duration: duration)
            print(id)
        case "start":
            let id = try client.start(activity)
            print(id)
        default:
            try client.update(activity)
            print(activity.id)
        }
    case "end":
        guard let id = stringFlag("--id", in: arguments) else {
            throw IslandProtocolError.invalidPayload
        }
        let client = try IslandClient.connect()
        defer { client.close() }
        try client.end(id: id)
        print(id)
    case "help", "-h", "--help":
        printUsage()
    default:
        printUsage()
        exit(2)
    }
} catch let error as IslandProtocolError {
    FileHandle.standardError.write(Data("\(IslandCodec.errorCode(error))\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("unavailable\n".utf8))
    exit(1)
}

func activity(from arguments: [String]) throws -> IslandActivity {
    let id = stringFlag("--id", in: arguments) ?? "cli.\(UUID().uuidString.lowercased())"
    let title = stringFlag("--title", in: arguments) ?? ""
    let priority = IslandPriority(rawValue: stringFlag("--priority", in: arguments) ?? "normal") ?? .normal
    var actions: [IslandAction] = []
    if let url = stringFlag("--open-url", in: arguments) {
        actions.append(IslandAction(name: "open", title: "Open", kind: .openURL, url: url))
    }
    if let callback = stringFlag("--callback", in: arguments) {
        actions.append(IslandAction(name: callback, title: callback, kind: .callback, callbackName: callback))
    }
    if arguments.contains("--dismiss") {
        actions.append(IslandAction(name: "dismiss", title: "Dismiss", kind: .dismiss))
    }
    var expanded: IslandExpandedContent?
    if let body = stringFlag("--body", in: arguments) {
        expanded = IslandExpandedContent(title: title, body: body)
    }
    return try IslandActivityValidation.validate(IslandActivity(
        id: id,
        priority: priority,
        compact: IslandCompactContent(
            symbolName: stringFlag("--symbol", in: arguments),
            title: title,
            trailingText: stringFlag("--trailing", in: arguments),
            progress: doubleFlag("--progress", in: arguments)
        ),
        expanded: expanded,
        actions: actions
    ))
}

func stringFlag(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func doubleFlag(_ name: String, in arguments: [String]) -> Double? {
    guard let raw = stringFlag(name, in: arguments) else { return nil }
    return Double(raw)
}

func printUsage() {
    let usage = """
    island present --title TEXT [--id ID] [--symbol SFSYMBOL] [--trailing TEXT] [--progress 0-1] [--duration SECONDS] [--priority low|normal|high] [--body TEXT] [--open-url URL] [--callback NAME] [--dismiss]
    island start --title TEXT [same flags except --duration]
    island update --id ID --title TEXT [same compact flags]
    island end --id ID
    """
    FileHandle.standardError.write(Data((usage + "\n").utf8))
}
