import Darwin
import Foundation
import XCTest
@testable import IslandKit

final class IslandTransportTests: XCTestCase {
    func testEventHandlerCanUpdateAndEndActivity() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".island-test-\(UUID().uuidString.prefix(8))")
        let path = directory.appendingPathComponent("test.sock").path
        let listener = try IslandFraming.bindListeningSocket(path: path)
        defer {
            shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directory)
        }
        let served = expectation(description: "server received update and end")
        DispatchQueue.global().async {
            defer { served.fulfill() }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return XCTFail("accept failed") }
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            do {
                for method in ["start", "update", "end"] {
                    let frame = try XCTUnwrap(IslandFraming.readFrame(fd))
                    let request = try IslandFraming.decodeRequest(frame)
                    XCTAssertEqual(request.method, method)
                    try IslandFraming.writeFrame(fd, IslandMessage.response(
                        requestId: request.requestId, ok: true, activityId: "callback.test"
                    ))
                    if method == "start" {
                        try IslandFraming.writeFrame(fd, IslandMessage.event(
                            name: "action", activityId: "callback.test", actionName: "update"
                        ))
                    }
                }
            } catch {
                XCTFail("server: \(error)")
            }
        }
        let client = try IslandClient.connect(socketPath: URL(fileURLWithPath: path))
        defer { client.close() }
        let handled = expectation(description: "callback completed synchronous requests")
        client.onEvent = { [weak client] event in
            guard let client else { return }
            do {
                try client.update(IslandActivity(
                    id: event.activityId, compact: IslandCompactContent(title: "Updated")
                ))
                try client.end(id: event.activityId)
            } catch {
                XCTFail("callback: \(error)")
            }
            handled.fulfill()
        }
        _ = try client.start(IslandActivity(
            id: "callback.test", compact: IslandCompactContent(title: "Started")
        ))
        wait(for: [handled, served], timeout: 6)
    }

    func testWriterPreservesFrameOrder() throws {
        let pair = try socketPair()
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        let writer = try IslandMessageWriter(fd: pair[0])
        defer { writer.close() }
        for index in 0..<20 {
            XCTAssertTrue(writer.enqueue(.response(requestId: "r\(index)", ok: true)))
        }
        for index in 0..<20 {
            let frame = try XCTUnwrap(IslandFraming.readFrame(pair[1]))
            XCTAssertEqual(try IslandFraming.decodeMessage(frame).requestId, "r\(index)")
        }
    }

    func testSlowPeerDoesNotBlockEnqueueOrClose() throws {
        let pair = try socketPair()
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        var bufferSize: Int32 = 1024
        setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout.size(ofValue: bufferSize)))
        let writer = try IslandMessageWriter(fd: pair[0], maxPendingMessages: 2)
        let message = IslandMessage(kind: "event", event: String(repeating: "x", count: 60_000))
        let began = ProcessInfo.processInfo.systemUptime
        var rejected = false
        for _ in 0..<100 {
            if !writer.enqueue(message) {
                rejected = true
                break
            }
        }
        writer.close()
        XCTAssertTrue(rejected, "slow peers must have bounded output")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertFalse(writer.enqueue(message))
    }

    func testSlowPeerWriteTimesOut() throws {
        let pair = try socketPair()
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        var bufferSize: Int32 = 1024
        setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout.size(ofValue: bufferSize)))
        let writer = try IslandMessageWriter(fd: pair[0])
        defer { writer.close() }
        XCTAssertTrue(writer.enqueue(IslandMessage(
            kind: "event", event: String(repeating: "x", count: 60_000)
        )))
        // The peer never reads. Writer failure must shut down the socket and wake its reader.
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(pair[0], &byte, 1), 0)
        XCTAssertFalse(writer.enqueue(.response(requestId: "late", ok: true)))
    }

    private func socketPair() throws -> [Int32] {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw IslandProtocolError.unavailable
        }
        var timeout = timeval(tv_sec: 6, tv_usec: 0)
        for fd in pair {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        }
        return pair
    }
}
