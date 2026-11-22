import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio

enum RemoteGoMicSetup {
    static let downloads = URL(string: "https://github.com/Clawborn/remote-go/releases/latest")!
    private static let filename = "Remote-Go-Mic-0.1.0.pkg"

    // Release archives keep the installer beside the app; local builds use dist/driver.
    static func package() async -> URL? {
        await Task.detached(priority: .utility) { findPackage() }.value
    }

    private static func findPackage() -> URL? {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let folders = [Bundle.main.resourceURL, parent.appendingPathComponent("driver"), parent].compactMap { $0 }
        for folder in folders {
            let package = folder.appendingPathComponent(filename)
            // Checking a known path avoids enumerating a protected Documents folder.
            if FileManager.default.fileExists(atPath: package.path) { return package }
        }
        return nil
    }
}

enum MicrophoneDevices {
    static let blackHoleUID = "BlackHole2ch_UID"
    static let remoteGoMicUID = "RemoteGoMic_UID"
    static var loopback: AudioDeviceID? { device(uid: blackHoleUID) }
    static var computer: AudioDeviceID? { device(uid: "BuiltInMicrophoneDevice") }
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    struct Loopback: Identifiable, Equatable {
        let id: String
        let name: String
    }

    static func loopbacks() -> [Loopback] {
        objectIDs(system, selector: kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName),
                  !objectIDs(id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty,
                  !objectIDs(id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty else {
                return nil
            }
            let known = uid == remoteGoMicUID || ["BlackHole", "vRemoteDr", "SayAll", "MiRemoteV"]
                .contains { name.hasPrefix($0) }
            guard known || uint32Property(id, selector: kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual
            else { return nil }
            return Loopback(id: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func externalProcessIsReading(device: AudioDeviceID) -> Bool {
        objectIDs(system, selector: kAudioHardwarePropertyProcessObjectList).contains { process in
            guard let pid = uint32Property(process, selector: kAudioProcessPropertyPID),
                  pid != UInt32(ProcessInfo.processInfo.processIdentifier) else { return false }
            return audioProcessIsReading(process, device: device)
        }
    }

    private static func audioProcessIsReading(_ process: AudioObjectID, device: AudioDeviceID) -> Bool {
        (uint32Property(process, selector: kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            && objectIDs(process, selector: kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
                .contains(device)
    }

    private static func objectIDs(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioObjectID>.stride else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        let result = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return result == noErr ? ids : []
    }

    private static func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint32Property(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return result == noErr ? value : nil
    }

    static func device(uid identifier: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let identifierString = identifier as CFString
        var uid = Unmanaged.passUnretained(identifierString)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = withExtendedLifetime(identifierString) {
            AudioObjectGetPropertyData(system, &address,
                UInt32(MemoryLayout.size(ofValue: uid)), &uid, &size, &device)
        }
        return result == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func loopbackOutputRate(_ device: AudioDeviceID) -> Double? {
        let outputs = objectIDs(device, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard outputs.count == 1, let stream = outputs.first else { return nil }
        var property = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &property, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (8000...384000).contains(format.mSampleRate) else { return nil }
        return format.mSampleRate
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

final class DictationAudioMonitor {
    private var timer: Timer?
    private var wasReading = false
    private var wasAvailable: Bool?

    func start(deviceUID: String, onAvailabilityChange: @escaping (Bool) -> Void,
               onChange: @escaping (Bool) -> Void) {
        stop()
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            guard let self else { return }
            let loopback = MicrophoneDevices.device(uid: deviceUID)
            let available = loopback != nil
            if self.wasAvailable != available {
                self.wasAvailable = available
                onAvailabilityChange(available)
            }
            let reading = loopback.map(MicrophoneDevices.externalProcessIsReading(device:)) ?? false
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
        wasReading = false
        wasAvailable = nil
    }
}

final class MicrophoneBridge {
    enum BridgeError: Error { case driverMissing, outputUnavailable }
    enum Source { case remote, computer }

    var status: ((InterfaceMessage) -> Void)?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var output: LoopbackOutput?
    private var input: AVAudioEngine?
    private var generation = UUID()

    var isRunning: Bool { output != nil }
    var isCapturingComputer: Bool { input != nil }

    func start(deviceUID: String = MicrophoneDevices.blackHoleUID) throws {
        stop()
        guard let device = MicrophoneDevices.device(uid: deviceUID) else { throw BridgeError.driverMissing }
        guard let rate = MicrophoneDevices.loopbackOutputRate(device) else { throw BridgeError.outputUnavailable }
        let output = LoopbackOutput(device: device, sampleRate: rate)
        try output.start()
        self.output = output
        status?("等待收音")
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
        output?.stop()
        output = nil
    }

    func receive(_ samples: [Float], source: Source = .remote) {
        guard (source == .computer) == isCapturingComputer, !samples.isEmpty, let output else { return }
        let token = generation
        output.enqueue(samples) { [weak self] in
            guard let self, self.generation == token else { return }
            self.status?(source == .remote ? "收到遥控器音频" : "收到电脑音频")
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

private final class LoopbackOutput {
    private let device: AudioDeviceID
    private let sampleRate: Double
    private var stream: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var samples: [Float]
    private var head = 0
    private var count = 0
    private var onFirstRender: (() -> Void)?
    private var reported = false

    init(device: AudioDeviceID, sampleRate: Double) {
        self.device = device
        self.sampleRate = sampleRate
        samples = Array(repeating: 0, count: Int(sampleRate * 0.35))
    }

    func start() throws {
        var callback: AudioDeviceIOProcID?
        let result = AudioDeviceCreateIOProcIDWithBlock(&callback, device, nil) {
            [weak self] _, _, _, output, _ in self?.render(output)
        }
        guard result == noErr, let callback else { throw MicrophoneBridge.BridgeError.outputUnavailable }
        guard AudioDeviceStart(device, callback) == noErr else {
            AudioDeviceDestroyIOProcID(device, callback)
            throw MicrophoneBridge.BridgeError.outputUnavailable
        }
        stream = callback
    }

    func stop() {
        guard let stream else { return }
        AudioDeviceStop(device, stream)
        AudioDeviceDestroyIOProcID(device, stream)
        self.stream = nil
    }

    func enqueue(_ input: [Float], onFirstRender: @escaping () -> Void) {
        let ratio = sampleRate / 16000
        lock.lock()
        defer { lock.unlock() }
        let length = min(Int(Double(input.count) * ratio), samples.count - count)
        for frame in 0..<length {
            let position = Double(frame) / ratio
            let lower = min(Int(position), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            samples[(head + count + frame) % samples.count] =
                input[lower] + (input[upper] - input[lower]) * Float(position - Double(lower))
        }
        count += length
        if !reported && length > 0 { self.onFirstRender = onFirstRender }
    }

    private func render(_ list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard lock.try() else {
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }
        var consumed = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels)
            let available = min(frames, count)
            for frame in 0..<frames {
                let sample = frame < available ? samples[(head + frame) % samples.count] : 0
                for channel in 0..<channels { data[frame * channels + channel] = sample }
            }
            consumed = max(consumed, available)
        }
        head = (head + consumed) % samples.count
        count -= consumed
        let callback = consumed > 0 ? onFirstRender : nil
        if callback != nil {
            onFirstRender = nil
            reported = true
        }
        lock.unlock()
        if let callback { DispatchQueue.main.async(execute: callback) }
    }
}
