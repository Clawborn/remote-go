import AVFoundation
import Darwin
import Foundation

final class AudioHelperService {
    private static let leaseDuration: TimeInterval = 1.2
    private let channel: AudioHelperChannel
    private let monitor = DictationAudioMonitor()
    private let bridge = MicrophoneBridge()
    private var readSource: DispatchSourceRead?
    private var terminationSource: DispatchSourceSignal?
    private var leaseTimer: Timer?
    private var lastStateTime: TimeInterval?
    private var remoteLeaseExpired = false
    private var deviceUID = ""
    private var deviceAvailable = false
    private var reading = false
    private var remoteAudioActive = false
    private var requestedHold: DictationShortcut?
    private var requestedToggle: DictationShortcut?
    private var postedHold: DictationShortcut?
    private var postedToggle: DictationShortcut?
    private var route: MicrophoneBridge.Source?
    private var liveSource: MicrophoneBridge.Source?
    private var audioStatus: String?
    private var shortcutStatus: String?
    private var lastStatus: AudioHelperStatus?
    private var requestingPermission = false

    private init(channel: AudioHelperChannel) { self.channel = channel }

    static func run(channel: AudioHelperChannel) -> Never {
        let service = AudioHelperService(channel: channel)
        service.start()
        withExtendedLifetime(service) { RunLoop.main.run() }
        service.shutdown()
    }

    private func start() {
        bridge.status = { [weak self] message in
            self?.audioStatus = message.key
            self?.publishStatus()
        }
        bridge.onLiveSourceChange = { [weak self] source in
            self?.liveSource = source
            self?.publishStatus()
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: channel.fileDescriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.receiveMessages() }
        readSource = source
        source.resume()

        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { [weak self] in self?.shutdown() }
        terminationSource = termination
        termination.resume()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.channel.isParentAlive { self.shutdown() }
            self.expireRemoteLease(at: ProcessInfo.processInfo.systemUptime)
        }
        leaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func receiveMessages() {
        for _ in 0..<64 {
            guard let message = channel.receive() else { return }
            switch message {
            case let .state(state, sentAt): apply(state, sentAt: sentAt)
            case .samples(let samples):
                expireRemoteLease(at: ProcessInfo.processInfo.systemUptime)
                if remoteAudioActive { bridge.receive(samples) }
            case .shutdown: shutdown()
            }
        }
    }

    private func apply(_ state: AudioHelperState, sentAt: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        guard sentAt <= now, now - sentAt < Self.leaseDuration,
              lastStateTime.map({ sentAt >= $0 }) ?? true else { return }
        expireRemoteLease(at: now)
        lastStateTime = sentAt

        let hasRemoteState = state.remoteAudioActive || state.heldShortcut != nil || state.toggleShortcut != nil
        if remoteLeaseExpired && hasRemoteState {
            publishStatus(force: true)
            return
        }
        remoteLeaseExpired = false
        if state.deviceUID != deviceUID { monitorDevice(state.deviceUID) }
        remoteAudioActive = state.remoteAudioActive
        setShortcuts(hold: state.heldShortcut, toggle: state.toggleShortcut, closeToggle: state.closeToggle)
        updateRoute()
        publishStatus(force: true)
    }

    private func expireRemoteLease(at now: TimeInterval) {
        guard let lastStateTime, now - lastStateTime >= Self.leaseDuration,
              remoteAudioActive || requestedHold != nil || requestedToggle != nil else { return }
        remoteLeaseExpired = true
        remoteAudioActive = false
        setShortcuts(hold: nil, toggle: nil, closeToggle: reading)
        updateRoute()
        publishStatus()
    }

    private func setShortcuts(hold: DictationShortcut?, toggle: DictationShortcut?, closeToggle: Bool) {
        let holdChanged = requestedHold != hold
        let toggleChanged = requestedToggle != toggle
        guard holdChanged || toggleChanged else { return }
        shortcutStatus = nil
        if holdChanged {
            if let postedHold { _ = postedHold.post(down: false) }
            postedHold = nil
            requestedHold = hold
        }
        if toggleChanged {
            if let postedToggle, closeToggle { _ = postedToggle.tap() }
            postedToggle = nil
            requestedToggle = toggle
        }
        if holdChanged, let hold {
            if hold.post(down: true) { postedHold = hold }
            else { shortcutStatus = "未发送语音快捷键 · 请检查辅助功能权限" }
        }
        if toggleChanged, let toggle {
            if toggle.tap() { postedToggle = toggle }
            else { shortcutStatus = "未发送语音快捷键 · 请检查辅助功能权限" }
        }
    }

    private func monitorDevice(_ uid: String) {
        deviceUID = uid
        deviceAvailable = false
        reading = false
        monitor.start(deviceUID: uid, onAvailabilityChange: { [weak self] available in
            guard let self else { return }
            self.deviceAvailable = available
            self.updateRoute()
            self.publishStatus()
        }, onChange: { [weak self] reading in
            guard let self else { return }
            self.reading = reading
            self.updateRoute()
            self.publishStatus()
        })
    }

    private func updateRoute() {
        let next: MicrophoneBridge.Source?
        if !deviceAvailable { next = nil }
        else if remoteAudioActive { next = .remote }
        else if reading && requestedHold == nil && requestedToggle == nil { next = .computer }
        else { next = nil }
        guard route != next else { return }

        route = next
        audioStatus = nil
        bridge.stop()
        switch next {
        case .remote: _ = startOutput()
        case .computer: startComputerAudio()
        case nil: break
        }
    }

    private func startOutput() -> Bool {
        do {
            try bridge.start(deviceUID: deviceUID)
            return true
        } catch {
            audioStatus = "无法连接所选虚拟麦克风"
            return false
        }
    }

    private func startComputerAudio() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: captureComputerAudio()
        case .notDetermined:
            audioStatus = "等待麦克风权限"
            guard !requestingPermission else { return }
            requestingPermission = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.requestingPermission = false
                    guard self.route == .computer else { return }
                    if allowed { self.captureComputerAudio() }
                    else { self.audioStatus = "请在隐私与安全性中允许使用麦克风" }
                    self.publishStatus()
                }
            }
        default: audioStatus = "请在隐私与安全性中允许使用麦克风"
        }
    }

    private func captureComputerAudio() {
        guard startOutput() else { return }
        bridge.startComputerAudio { [weak self] result in
            if case .failure(let error) = result {
                self?.audioStatus = "无法启动电脑麦克风"
                self?.publishStatus()
                NSLog("Remote Go Mac microphone failed: %@", error.localizedDescription)
            }
        }
    }

    private func publishStatus(force: Bool = false) {
        let source: String?
        switch liveSource {
        case .remote: source = "remote"
        case .computer: source = "computer"
        case nil: source = nil
        }
        let status = AudioHelperStatus(deviceUID: deviceUID, deviceAvailable: deviceAvailable,
                                       reading: reading, source: source, status: shortcutStatus ?? audioStatus,
                                       remoteLeaseExpired: remoteLeaseExpired)
        guard force || status != lastStatus else { return }
        lastStatus = status
        channel.sendStatus(status)
    }

    private func shutdown() -> Never {
        readSource?.cancel()
        leaseTimer?.invalidate()
        monitor.stop()
        setShortcuts(hold: nil, toggle: nil, closeToggle: reading)
        bridge.stop()
        exit(EXIT_SUCCESS)
    }
}
