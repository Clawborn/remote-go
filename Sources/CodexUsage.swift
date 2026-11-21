import AppKit
import Darwin

enum CodexUsage {
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: TimeInterval?

        var description: String {
            let period: String
            switch windowDurationMins {
            case 300: period = "5 小时"
            case 10_080: period = "每周"
            case let minutes? where minutes > 0: period = "\(minutes) 分钟"
            default: period = "当前周期"
            }
            let remaining = Int(min(max(100 - usedPercent, 0), 100).rounded())
            guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return "\(period)剩余 \(remaining)%" }
            let reset = Date(timeIntervalSince1970: resetsAt).formatted(date: .abbreviated, time: .shortened)
            return "\(period)剩余 \(remaining)% · \(reset) 重置"
        }
    }

    private struct Snapshot: Decodable {
        let primary: Window?
        let secondary: Window?
    }

    private struct UsageResult: Decodable {
        let rateLimits: Snapshot
        let rateLimitsByLimitId: [String: Snapshot]?
    }

    private enum QueryError: Error { case unavailable }

    static func windows(from data: Data) throws -> [Window] {
        let result = try JSONDecoder().decode(UsageResult.self, from: data)
        let snapshot = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }.filter { $0.usedPercent.isFinite }
        guard !windows.isEmpty else { throw QueryError.unavailable }
        return windows
    }

    static func fetch(_ completion: @escaping ([Window]?) -> Void) {
        let executable = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChatTarget.codex.rawValue)?
            .appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = try? query(executable)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func query(_ executable: URL) throws -> [Window] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
        }

        func send(_ message: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: message)
            line.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: line)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        try send(["id": 0, "method": "initialize", "params": ["clientInfo":
            ["name": "remote_go", "title": "Remote Go", "version": version]]])
        let deadline = ProcessInfo.processInfo.systemUptime + 7
        var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var buffer = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = max(deadline - ProcessInfo.processInfo.systemUptime, 0)
            let ready = poll(&fd, 1, Int32(remaining * 1000))
            if ready == -1 && errno == EINTR { continue }
            guard ready > 0, fd.revents & Int16(POLLIN) != 0 else { break }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            guard buffer.count < 262_144 else { break }
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                guard let result = message["result"] else { throw QueryError.unavailable }
                switch id {
                case 0:
                    try send(["method": "initialized"])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                case 1:
                    return try windows(from: JSONSerialization.data(withJSONObject: result))
                default: continue
                }
            }
        }
        throw QueryError.unavailable
    }
}
