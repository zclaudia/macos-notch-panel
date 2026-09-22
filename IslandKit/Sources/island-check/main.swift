import Darwin
import Foundation
import IslandKit

var failures: [String] = []

func check(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("PASS \(name)")
    } catch {
        failures.append("\(name): \(error)")
        print("FAIL \(name): \(error)")
    }
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError(message) }
}

struct CheckError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

check("accepts compact activity") {
    let activity = try sampleActivity()
    try expect(activity.compact.title == "Build finished", "title")
    try expect(activity.compact.progress == 0.5, "progress")
    try expect(activity.actions.count == 2, "action count")
    try expect(activity.actions[0].callbackName == nil, "open action has no callback")
    try expect(activity.actions[1].callbackName == "done", "callback name")
}

check("rejects empty title, file URL, and bad progress") {
    try expect(rejects(sampleActivity(title: "   ")), "empty title")
    try expect(rejects(sampleActivity(progress: 1.5)), "progress")
    try expect(!IslandActivityValidation.isStructurallyAllowedURL("file:///etc/passwd"), "file URL")
    try expect(!IslandActivityValidation.isStructurallyAllowedURL("javascript:alert(1)"), "javascript URL")
    try expect(
        rejects(sampleActivity(actions: [
            IslandAction(name: "open", title: "Open", kind: .openURL, url: "file:///tmp/x")
        ])),
        "file action"
    )
}

check("present round trip") {
    let socket = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".boringnotch", isDirectory: true)
        .appendingPathComponent("island-api-test.sock")
    let panel = FakePanel(path: socket.path)
    try panel.start()
    defer { panel.stop() }

    let client = try IslandClient.connect(socketPath: socket)
    defer { client.close() }
    let activity = try sampleActivity()
    let id = try client.present(activity, duration: 1.2)
    try expect(id == activity.id, "returned id")
    let request = try unwrap(panel.request)
    try expect(request.schemaVersion == IslandSchema.version, "schema")
    try expect(request.method == "present", "method")
    try expect(request.activity?.compact.title == "Build finished", "title")
    try expect(request.activity?.compact.symbolName == "checkmark.circle", "symbol")
    try expect(request.duration == 1.2, "duration")
}

check("CLI rejects a blank title and presents through the socket") {
    let binary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("island")
    try expect(FileManager.default.fileExists(atPath: binary.path), "island binary missing at \(binary.path)")

    let rejected = try run(binary, arguments: ["present", "--title", " "])
    try expect(rejected.status == 1, "status \(rejected.status) stderr \(rejected.stderr)")
    try expect(rejected.stderr == "invalid_payload\n", "stderr \(rejected.stderr)")

    let socket = IslandSocketPath.preferredServerSocket()
    if FileManager.default.fileExists(atPath: socket.path) {
        print("SKIP live CLI present; socket already exists at \(socket.path)")
        return
    }
    let panel = FakePanel(path: socket.path)
    try panel.start()
    defer { panel.stop() }

    let presented = try run(binary, arguments: [
        "present", "--id", "cli.test", "--title", "From CLI", "--symbol", "bell", "--duration", "2"
    ])
    try expect(presented.status == 0, "status \(presented.status) stderr \(presented.stderr)")
    try expect(presented.stdout == "cli.test\n", "stdout \(presented.stdout)")
    let request = try unwrap(panel.request)
    try expect(request.activity?.id == "cli.test", "cli id")
    try expect(request.activity?.compact.title == "From CLI", "cli title")
}

if CommandLine.arguments.contains("--live") {
    check("live panel preserves CLI activities across disconnects") {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("island")
        let id = "check.\(UUID().uuidString.lowercased())"
        defer { _ = try? run(binary, arguments: ["end", "--id", id]) }
        for arguments in [
            ["start", "--id", id, "--title", "Lifecycle check", "--priority", "high"],
            ["update", "--id", id, "--title", "Updated after reconnect", "--priority", "high"],
            ["end", "--id", id],
        ] {
            let result = try run(binary, arguments: arguments)
            try expect(result.status == 0, "\(arguments[0]): \(result.stderr)")
            try expect(result.stdout == id + "\n", "returned activity ID")
        }
    }

    check("live panel keeps present until its original expiration") {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("island")
        let id = "check.\(UUID().uuidString.lowercased())"
        defer { _ = try? run(binary, arguments: ["end", "--id", id]) }
        let presented = try run(binary, arguments: [
            "present", "--id", id, "--title", "Expiration check", "--duration", "2", "--priority", "high"
        ])
        try expect(presented.status == 0, "present: \(presented.stderr)")
        Thread.sleep(forTimeInterval: 0.2)
        let updated = try run(binary, arguments: [
            "update", "--id", id, "--title", "Still visible", "--priority", "high"
        ])
        try expect(updated.status == 0, "activity disappeared on disconnect: \(updated.stderr)")
        Thread.sleep(forTimeInterval: 2.2)
        let ended = try run(binary, arguments: ["end", "--id", id])
        try expect(ended.status == 1 && ended.stderr == "not_found\n", "activity did not expire: \(ended.stderr)")
    }
}

if failures.isEmpty {
    print("ALL PASSED")
    exit(0)
}
FileHandle.standardError.write(Data("\(failures.count) failed\n".utf8))
exit(1)

func rejects(_ body: @autoclosure () throws -> some Any) -> Bool {
    do {
        _ = try body()
        return false
    } catch let error as IslandProtocolError {
        return error == .invalidPayload
    } catch {
        return false
    }
}

func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckError("unexpected nil") }
    return value
}

func sampleActivity(
    title: String = "Build finished",
    progress: Double? = 0.5,
    actions: [IslandAction]? = nil
) throws -> IslandActivity {
    try IslandActivityValidation.validate(IslandActivity(
        id: "test.activity",
        priority: .high,
        compact: IslandCompactContent(
            symbolName: "checkmark.circle",
            title: title,
            trailingText: "OK",
            progress: progress
        ),
        actions: actions ?? [
            IslandAction(name: "open", title: "Open", kind: .openURL, url: "https://example.com/build"),
            IslandAction(name: "done", title: "Done", kind: .callback, callbackName: "done"),
        ]
    ))
}

func run(_ binary: URL, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, stdout, stderr)
}

private final class FakePanel {
    let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var storedRequest: IslandRequest?
    private let queue = DispatchQueue(label: "island.test.panel")

    var request: IslandRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    init(path: String) {
        self.path = path
    }

    func start() throws {
        listenFD = try IslandFraming.bindListeningSocket(path: path)
        let fd = listenFD
        queue.async { [weak self] in
            self?.serveOne(listenFD: fd)
        }
    }

    func stop() {
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private func serveOne(listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        guard let frame = try? IslandFraming.readFrame(client),
              let request = try? IslandFraming.decodeRequest(frame)
        else { return }
        lock.lock()
        storedRequest = request
        lock.unlock()
        let response = IslandMessage.response(
            requestId: request.requestId,
            ok: true,
            activityId: request.activity?.id ?? request.activityId
        )
        try? IslandFraming.writeFrame(client, response)
    }
}
