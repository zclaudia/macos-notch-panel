import Darwin
import Foundation

public enum IslandFraming {
    public static func bindListeningSocket(path: String) throws -> Int32 {
        let socketPath = try prepareSocketFile(path: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IslandProtocolError.unavailable }
        ignoreSIGPIPE(fd)
        do {
            var address = try socketAddress(path: socketPath)
            let bindResult = withUnsafePointer(to: &address.addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, address.length)
                }
            }
            guard bindResult == 0 else { throw IslandProtocolError.unavailable }
            guard chmod(socketPath, 0o600) == 0 else {
                unlink(socketPath)
                throw IslandProtocolError.unavailable
            }
            guard listen(fd, 8) == 0 else {
                unlink(socketPath)
                throw IslandProtocolError.unavailable
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    public static func connect(path: String) throws -> Int32 {
        guard path.utf8.count <= IslandSocketPath.maxPathBytes else { throw IslandProtocolError.unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IslandProtocolError.unavailable }
        ignoreSIGPIPE(fd)
        var address = try socketAddress(path: path)
        let result = withUnsafePointer(to: &address.addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, address.length)
            }
        }
        guard result == 0 else {
            close(fd)
            throw IslandProtocolError.unavailable
        }
        return fd
    }

    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    public static func writeFrame(_ fd: Int32, _ value: some Encodable) throws {
        let payload = try IslandCodec.encoder().encode(value)
        guard payload.count <= IslandSchema.maxFrameBytes else { throw IslandProtocolError.frameTooLarge }
        var header = UInt32(payload.count).bigEndian
        let headerData = Data(bytes: &header, count: 4)
        try writeAll(fd, headerData)
        try writeAll(fd, payload)
    }

    public static func readFrame(_ fd: Int32) throws -> Data? {
        guard let header = try readExact(fd, 4) else { return nil }
        let bytes = [UInt8](header)
        guard bytes.count == 4 else { throw IslandProtocolError.frameTooLarge }
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        guard length > 0, length <= IslandSchema.maxFrameBytes else { throw IslandProtocolError.frameTooLarge }
        return try readExact(fd, Int(length))
    }

    public static func decodeRequest(_ data: Data) throws -> IslandRequest {
        do {
            return try IslandCodec.decoder().decode(IslandRequest.self, from: data)
        } catch {
            throw IslandProtocolError.invalidPayload
        }
    }

    public static func decodeMessage(_ data: Data) throws -> IslandMessage {
        let message = try IslandCodec.decoder().decode(IslandMessage.self, from: data)
        guard message.schemaVersion == IslandSchema.version else { throw IslandProtocolError.unsupportedSchema }
        return message
    }

    @discardableResult
    private static func prepareSocketFile(path: String) throws -> String {
        guard path.utf8.count <= IslandSocketPath.maxPathBytes, path.hasPrefix("/") else {
            throw IslandProtocolError.unavailable
        }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard directory.path == home || directory.path.hasPrefix(home + "/") else {
            throw IslandProtocolError.unavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let socketPath = directory.appendingPathComponent(url.lastPathComponent).path
        guard socketPath.utf8.count <= IslandSocketPath.maxPathBytes else { throw IslandProtocolError.unavailable }
        var info = stat()
        if stat(socketPath, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw IslandProtocolError.unavailable }
            unlink(socketPath)
        }
        return socketPath
    }

    private static func socketAddress(path: String) throws -> (addr: sockaddr_un, length: socklen_t) {
        guard path.utf8.count <= IslandSocketPath.maxPathBytes else { throw IslandProtocolError.unavailable }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, source, capacity - 1)
                    destination[capacity - 1] = 0
                }
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.stride))
    }

    private static func ignoreSIGPIPE(_ fd: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if wrote > 0 {
                    sent += wrote
                    continue
                }
                if wrote < 0 && errno == EINTR { continue }
                throw IslandProtocolError.unavailable
            }
        }
    }

    private static func readExact(_ fd: Int32, _ count: Int) throws -> Data? {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let readCount = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: received), count - received)
            }
            if readCount == 0 {
                if received == 0 { return nil }
                throw IslandProtocolError.unavailable
            }
            if readCount > 0 {
                received += readCount
                continue
            }
            if errno == EINTR { continue }
            throw IslandProtocolError.unavailable
        }
        return data
    }
}
