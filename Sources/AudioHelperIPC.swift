import Darwin
import Foundation
import Security

struct AudioHelperState: Codable, Equatable {
    var deviceUID: String
    var remoteAudioActive: Bool
    var heldShortcut: DictationShortcut?
    var toggleShortcut: DictationShortcut?
    var closeToggle: Bool
}

struct AudioHelperStatus: Codable, Equatable {
    var deviceUID: String
    var deviceAvailable: Bool
    var reading: Bool
    var source: String?
    var status: String?
    var remoteLeaseExpired: Bool = false
}

enum AudioHelperMessage {
    case state(AudioHelperState, sentAt: TimeInterval)
    case samples([Float])
    case shutdown
}

private struct TimedAudioHelperState: Codable {
    let state: AudioHelperState
    let sentAt: TimeInterval
}

private enum AudioHelperDatagram {
    enum Kind: UInt8 { case state = 1, samples, status, shutdown }

    // Keep each message within the default UNIX datagram size.
    private static let limit = 2048
    static let framesPerPacket = 480

    static func send(_ kind: Kind, payload: Data = Data(), to socket: Int32) {
        guard payload.count < limit else { return }
        var packet = Data([kind.rawValue])
        packet.append(payload)
        _ = packet.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, MSG_DONTWAIT) }
    }

    static func receive(from socket: Int32) -> (Kind, Data)? {
        var buffer = [UInt8](repeating: 0, count: limit + 1)
        let count = buffer.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress, $0.count, MSG_DONTWAIT) }
        guard (1...limit).contains(count), let kind = Kind(rawValue: buffer[0]) else { return nil }
        return (kind, Data(buffer[1..<count]))
    }

    static func encode<Value: Encodable>(_ value: Value, kind: Kind, to socket: Int32) {
        guard let payload = try? JSONEncoder().encode(value) else { return }
        send(kind, payload: payload, to: socket)
    }
}

final class AudioHelperChannel {
    static let argument = "--audio-helper"
    let fileDescriptor = STDIN_FILENO
    private let parentPID: pid_t

    init?(arguments: [String]) {
        guard arguments.count == 3, arguments[1] == Self.argument,
              let parentPID = pid_t(arguments[2]), parentPID > 1, getppid() == parentPID else { return nil }

        var type: Int32 = 0
        var size = socklen_t(MemoryLayout.size(ofValue: type))
        guard getsockopt(fileDescriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0, type == SOCK_DGRAM else {
            return nil
        }
        var peer = sockaddr()
        size = socklen_t(MemoryLayout.size(ofValue: peer))
        guard getpeername(fileDescriptor, &peer, &size) == 0, Int32(peer.sa_family) == AF_UNIX,
              Self.isSameExecutable(parentPID), getppid() == parentPID else {
            return nil
        }
        self.parentPID = parentPID
    }

    private static func isSameExecutable(_ parentPID: pid_t) -> Bool {
        guard let ownPath = executablePath(getpid()), executablePath(parentPID) == ownPath else { return false }
        var ownCode: SecCode?
        var ownExecutable: SecStaticCode?
        var requirement: SecRequirement?
        var parentCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: parentPID)] as CFDictionary
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownExecutable) == errSecSuccess, let ownExecutable,
              SecCodeCopyDesignatedRequirement(ownExecutable, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &parentCode) == errSecSuccess, let parentCode else {
            return false
        }
        return SecCodeCheckValidity(parentCode, [], requirement) == errSecSuccess
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        return length > 0 ? String(cString: path) : nil
    }

    var isParentAlive: Bool { getppid() == parentPID }

    func receive() -> AudioHelperMessage? {
        guard let (kind, payload) = AudioHelperDatagram.receive(from: fileDescriptor) else { return nil }
        switch kind {
        case .state:
            guard let frame = try? JSONDecoder().decode(TimedAudioHelperState.self, from: payload) else { return nil }
            return .state(frame.state, sentAt: frame.sentAt)
        case .samples:
            let stride = MemoryLayout<Float>.stride
            guard !payload.isEmpty, payload.count.isMultiple(of: stride) else { return nil }
            var samples = [Float](repeating: 0, count: payload.count / stride)
            _ = samples.withUnsafeMutableBytes { payload.copyBytes(to: $0) }
            return .samples(samples)
        case .shutdown:
            return payload.isEmpty ? .shutdown : nil
        case .status:
            return nil
        }
    }

    func sendStatus(_ status: AudioHelperStatus) {
        AudioHelperDatagram.encode(status, kind: .status, to: fileDescriptor)
    }
}

// The main run loop sends the heartbeat so an unresponsive UI cannot renew a voice session.
final class AudioHelperClient {
    var onStatus: ((AudioHelperStatus?) -> Void)?

    private var state: AudioHelperState?
    private var child: Process?
    private var socket: Int32 = -1
    private var reader: DispatchSourceRead?
    private var heartbeat: Timer?
    private var nextLaunch: TimeInterval = 0
    private var reportedUnavailable = false

    var isRunning: Bool { child?.isRunning == true }

    func start(state: AudioHelperState) {
        self.state = state
        if heartbeat == nil {
            let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.pulse() }
            heartbeat = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        pulse()
    }

    func update(_ state: AudioHelperState) {
        guard self.state != state else { return }
        self.state = state
        sendState()
    }

    func sendAudio(_ samples: [Float]) {
        guard socket >= 0, state?.remoteAudioActive == true, !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let frames = AudioHelperDatagram.framesPerPacket
            // A stalled child loses audio frames instead of blocking the desktop.
            for offset in stride(from: 0, to: min(buffer.count, frames * 8), by: frames) {
                let count = min(frames, buffer.count - offset)
                let payload = Data(bytes: base.advanced(by: offset), count: count * MemoryLayout<Float>.stride)
                AudioHelperDatagram.send(.samples, payload: payload, to: socket)
            }
        }
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        state = nil
        if socket >= 0 { AudioHelperDatagram.send(.shutdown, to: socket) }
        closeConnection()
        nextLaunch = 0
        reportedUnavailable = false
    }

    deinit { stop() }

    private func pulse() {
        guard state != nil else { return }
        if child == nil, ProcessInfo.processInfo.systemUptime >= nextLaunch {
            launch()
        }
        sendState()
    }

    private func sendState() {
        guard let state, socket >= 0 else { return }
        let frame = TimedAudioHelperState(state: state, sentAt: ProcessInfo.processInfo.systemUptime)
        AudioHelperDatagram.encode(frame, kind: .state, to: socket)
    }

    private func launch() {
        nextLaunch = ProcessInfo.processInfo.systemUptime + 1
        guard let executable = Bundle.main.executableURL else { reportUnavailable(); return }
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else { reportUnavailable(); return }
        let local = pair[0]
        let remote = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        defer { try? remote.close() }

        guard Self.configureSocket(local), Self.configureSocket(remote.fileDescriptor) else {
            Darwin.close(local)
            reportUnavailable()
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [AudioHelperChannel.argument, String(getpid())]
        process.standardInput = remote
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { [weak self] in self?.childDidExit(finished) }
        }
        do {
            try process.run()
        } catch {
            Darwin.close(local)
            reportUnavailable()
            NSLog("Remote Go audio helper could not start: %@", error.localizedDescription)
            return
        }

        child = process
        socket = local
        let reader = DispatchSource.makeReadSource(fileDescriptor: local, queue: .main)
        reader.setEventHandler { [weak self, weak process] in
            guard let self, let process, self.child === process else { return }
            self.readStatus()
        }
        reader.setCancelHandler { Darwin.close(local) }
        self.reader = reader
        reader.resume()
    }

    private static func configureSocket(_ socket: Int32) -> Bool {
        var enabled: Int32 = 1
        let size = socklen_t(MemoryLayout.size(ofValue: enabled))
        return fcntl(socket, F_SETFD, FD_CLOEXEC) == 0 &&
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, size) == 0
    }

    private func readStatus() {
        for _ in 0..<32 {
            guard socket >= 0, let (kind, data) = AudioHelperDatagram.receive(from: socket) else { return }
            guard kind == .status, let status = try? JSONDecoder().decode(AudioHelperStatus.self, from: data) else {
                continue
            }
            reportedUnavailable = false
            onStatus?(status)
        }
    }

    private func childDidExit(_ finished: Process) {
        guard child === finished else { return }
        closeConnection()
        nextLaunch = ProcessInfo.processInfo.systemUptime + 1
        reportUnavailable()
    }

    private func closeConnection() {
        child = nil
        socket = -1
        reader?.cancel()
        reader = nil
    }

    private func reportUnavailable() {
        guard !reportedUnavailable else { return }
        reportedUnavailable = true
        onStatus?(nil)
    }
}
