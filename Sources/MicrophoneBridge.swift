import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio

enum MicrophoneDevices {
    static var loopback: AudioDeviceID? { device(uid: "BlackHole2ch_UID") }
    static var computer: AudioDeviceID? { device(uid: "BuiltInMicrophoneDevice") }
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func processIsReadingBlackHole(_ pid: pid_t) -> Bool {
        guard let loopback else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size),
                                         &qualifier, &size, &process) == noErr,
              process != kAudioObjectUnknown else { return false }
        address.mSelector = kAudioProcessPropertyIsRunningInput
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr, running != 0
        else { return false }
        address.mSelector = kAudioProcessPropertyDevices
        address.mScope = kAudioObjectPropertyScopeInput
        guard AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioDeviceID>.stride
        else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let result = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return result == noErr && ids.contains(loopback)
    }

    private static func device(uid identifier: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid = Unmanaged.passUnretained(identifier as CFString)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(system, &address,
            UInt32(MemoryLayout.size(ofValue: uid)), &uid, &size, &device)
        return result == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func setDevice(_ id: AudioDeviceID, for node: AVAudioIONode) -> Bool {
        guard let unit = node.audioUnit else { return false }
        var device = id
        let size = UInt32(MemoryLayout.size(ofValue: device))
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                    0, &device, size) == noErr && isUsing(id, node: node)
    }

    static func isUsing(_ id: AudioDeviceID, node: AVAudioIONode) -> Bool {
        guard let unit = node.audioUnit else { return false }
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                    0, &device, &size) == noErr && device == id
    }
}

final class WeTypeAudioMonitor {
    private var timer: Timer?
    private var application: NSRunningApplication?
    private var wasReading = false

    func start(onChange: @escaping (Bool) -> Void) {
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.application?.isTerminated != false {
                self.application = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.tencent.inputmethod.wetype").first
            }
            let reading = self.application.map { MicrophoneDevices.processIsReadingBlackHole($0.processIdentifier) } ?? false
            guard reading != self.wasReading else { return }
            self.wasReading = reading
            onChange(reading)
        }
        self.timer = timer
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        application = nil
        wasReading = false
    }
}

final class MicrophoneBridge {
    enum BridgeError: Error { case driverMissing, outputUnavailable }
    enum Source { case remote, computer }

    var status: ((InterfaceMessage) -> Void)?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var output: AVAudioEngine?
    private var input: AVAudioEngine?
    private var outputDevice: AudioDeviceID?
    private var player: AVAudioPlayerNode?
    private var reportedSource: Source?
    private var generation = UUID()
    private var queuedFrames = 0

    var isRunning: Bool { output?.isRunning == true }
    var isCapturingComputer: Bool { input != nil }

    func start() throws {
        stop()
        guard let device = MicrophoneDevices.loopback else { throw BridgeError.driverMissing }
        let engine = AVAudioEngine()
        let node = engine.outputNode
        guard MicrophoneDevices.setDevice(device, for: node) else { throw BridgeError.outputUnavailable }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        guard MicrophoneDevices.isUsing(device, node: node) else {
            engine.stop()
            throw BridgeError.outputUnavailable
        }
        outputDevice = device
        output = engine
        self.player = player
        player.play()
        status?("等待收音 · 输出到 BlackHole 2ch")
    }

    private func stopComputerInput() {
        guard let input else { return }
        input.inputNode.removeTap(onBus: 0)
        input.stop()
        self.input = nil
    }

    func stop() {
        generation = UUID()
        stopComputerInput()
        player?.stop()
        output?.stop()
        player = nil
        output = nil
        outputDevice = nil
        reportedSource = nil
        queuedFrames = 0
    }

    func receive(_ samples: [Float], source: Source = .remote) {
        guard (source == .computer) == isCapturingComputer, !samples.isEmpty,
              let player, let output, let outputDevice, output.isRunning,
              MicrophoneDevices.isUsing(outputDevice, node: output.outputNode), queuedFrames < 5600,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let address = source.baseAddress { channel.update(from: address, count: source.count) }
        }
        let frames = samples.count
        queuedFrames += frames
        let token = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
                if self.reportedSource != source {
                    self.reportedSource = source
                    self.status?(source == .remote
                        ? "已将遥控器音频送入 BlackHole 2ch"
                        : "已将电脑麦克风音频送入 BlackHole 2ch")
                }
            }
        }
    }

    func startComputerAudio() throws {
        guard input == nil else { return }
        guard let device = MicrophoneDevices.computer else { throw BridgeError.outputUnavailable }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        guard MicrophoneDevices.setDevice(device, for: node) else { throw BridgeError.outputUnavailable }
        let inputFormat = node.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: format)
        else { throw BridgeError.outputUnavailable }
        let target = format
        let token = generation
        node.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate)) + 32
            guard let pcm = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            let outcome = converter.convert(to: pcm, error: nil) { _, state in
                if consumed {
                    state.pointee = .noDataNow
                    return nil
                }
                consumed = true
                state.pointee = .haveData
                return buffer
            }
            guard outcome != .error, let channel = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.receive(samples, source: .computer)
            }
        }
        do {
            try engine.start()
            guard MicrophoneDevices.isUsing(device, node: node) else {
                engine.stop()
                throw BridgeError.outputUnavailable
            }
            input = engine
        } catch {
            node.removeTap(onBus: 0)
            throw error
        }
    }
}
