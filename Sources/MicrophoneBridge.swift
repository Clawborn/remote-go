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
        guard let format = streamFormat(device, scope: kAudioObjectPropertyScopeOutput),
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (8000...384000).contains(format.mSampleRate) else { return nil }
        return format.mSampleRate
    }

    static func inputFormat(_ device: AudioDeviceID) -> AVAudioFormat? {
        guard var format = streamFormat(device, scope: kAudioObjectPropertyScopeInput),
              format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame > 0,
              format.mBytesPerFrame > 0, (8000...384000).contains(format.mSampleRate) else { return nil }
        return AVAudioFormat(streamDescription: &format)
    }

    private static func streamFormat(_ device: AudioDeviceID, scope: AudioObjectPropertyScope)
        -> AudioStreamBasicDescription? {
        let streams = objectIDs(device, selector: kAudioDevicePropertyStreams, scope: scope)
        guard streams.count == 1, let stream = streams.first else { return nil }
        var property = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let result = AudioObjectGetPropertyData(stream, &property, 0, nil, &size, &format)
        return result == noErr ? format : nil
    }
}

final class DictationAudioMonitor {
    private let pollingQueue = DispatchQueue(label: "me.tianrun.remotedesk.audio-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation = UUID()

    func start(deviceUID: String, onAvailabilityChange: @escaping (Bool) -> Void,
               onChange: @escaping (Bool) -> Void) {
        stop()
        let generation = self.generation
        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        var wasAvailable: Bool?
        var wasReading = false
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in
            let loopback = MicrophoneDevices.device(uid: deviceUID)
            let available = loopback != nil
            let reading = loopback.map(MicrophoneDevices.externalProcessIsReading(device:)) ?? false
            let availabilityChanged = wasAvailable != available
            let readingChanged = wasReading != reading
            guard availabilityChanged || readingChanged else { return }
            wasAvailable = available
            wasReading = reading
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                if availabilityChanged { onAvailabilityChange(available) }
                if readingChanged, self.generation == generation { onChange(reading) }
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        generation = UUID()
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }
}

final class MicrophoneBridge {
    enum BridgeError: LocalizedError {
        case driverMissing, outputUnavailable, computerInputUnavailable
        case computerInputFailed(operation: String, status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .computerInputUnavailable:
                return "The built-in microphone or its audio format is unavailable"
            case let .computerInputFailed(operation, status):
                return "\(operation) failed for the built-in microphone (CoreAudio status \(status))"
            default:
                return nil
            }
        }
    }
    enum Source { case remote, computer }
    var onLiveSourceChange: ((Source?) -> Void)?
    private var liveSource: Source? {
        didSet {
            if oldValue != liveSource { onLiveSourceChange?(liveSource) }
        }
    }

    var status: ((InterfaceMessage) -> Void)?
    private let computerCapture = ComputerMicrophoneCapture()
    private var output: LoopbackOutput?
    private var computerCaptureID: UUID?
    private var computerCaptureReady = false
    private var generation = UUID()

    var isRunning: Bool { output != nil }
    var isCapturingComputer: Bool { computerCaptureID != nil }

    func start(deviceUID: String = MicrophoneDevices.blackHoleUID) throws {
        stop()
        guard let device = MicrophoneDevices.device(uid: deviceUID) else { throw BridgeError.driverMissing }
        guard let rate = MicrophoneDevices.loopbackOutputRate(device) else { throw BridgeError.outputUnavailable }
        let output = LoopbackOutput(device: device, sampleRate: rate)
        try output.start()
        self.output = output
        status?("等待收音")
    }

    func stopComputerAudio() {
        guard computerCaptureID != nil else { return }
        computerCaptureID = nil
        computerCaptureReady = false
        computerCapture.setRequest(nil)
    }

    func stop() {
        generation = UUID()
        liveSource = nil
        stopComputerAudio()
        output?.stop()
        output = nil
    }

    func receive(_ samples: [Float], source: Source = .remote) {
        guard (source == .computer) == isCapturingComputer, !samples.isEmpty, let output else { return }
        let token = generation
        output.enqueue(samples) { [weak self] in
            guard let self, self.generation == token else { return }
            self.liveSource = source
            self.status?(source == .remote ? "收到遥控器音频" : "收到电脑音频")
        }
    }

    func startComputerAudio(completion: @escaping (Result<Void, Error>) -> Void) {
        guard computerCaptureID == nil else { return }
        let id = UUID()
        computerCaptureID = id
        computerCapture.setRequest(.init(id: id, receive: { [weak self] samples in
            DispatchQueue.main.async {
                guard let self, self.computerCaptureID == id, self.computerCaptureReady else { return }
                self.receive(samples, source: .computer)
            }
        }, complete: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.computerCaptureID == id else { return }
                switch result {
                case .success: self.computerCaptureReady = true
                case .failure: self.computerCaptureID = nil
                }
                completion(result)
            }
        }))
    }

    deinit { computerCapture.setRequest(nil) }
}

private final class ComputerMicrophoneCapture {
    struct Request {
        let id: UUID
        let receive: ([Float]) -> Void
        let complete: (Result<Void, Error>) -> Void
    }

    private final class Stream {
        let id: UUID
        let device: AudioDeviceID
        let callback: AudioDeviceIOProcID

        init(id: UUID, device: AudioDeviceID, callback: AudioDeviceIOProcID) {
            self.id = id
            self.device = device
            self.callback = callback
        }

        func stop() {
            AudioDeviceStop(device, callback)
            AudioDeviceDestroyIOProcID(device, callback)
        }
    }

    private let queue = DispatchQueue(label: "RemoteGo.computer-microphone", qos: .userInitiated)
    private let stateLock = NSLock()
    // The lock only protects the latest request and worker scheduling. HAL calls can block.
    private var requested: Request?
    private var workerScheduled = false
    private var stream: Stream?

    func setRequest(_ request: Request?) {
        stateLock.lock()
        requested = request
        let shouldSchedule = !workerScheduled
        workerScheduled = true
        stateLock.unlock()
        if shouldSchedule { queue.async { self.updateStream() } }
    }

    private func isRequested(_ request: Request) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requested?.id == request.id
    }

    private func updateStream() {
        while true {
            stateLock.lock()
            let request = requested
            if request?.id == stream?.id {
                workerScheduled = false
                stateLock.unlock()
                return
            }
            stateLock.unlock()

            stream?.stop()
            stream = nil
            guard let request, isRequested(request) else { continue }
            do {
                stream = try startStream(request)
                request.complete(.success(()))
            } catch {
                stateLock.lock()
                let stillRequested = requested?.id == request.id
                if stillRequested { requested = nil }
                stateLock.unlock()
                if stillRequested { request.complete(.failure(error)) }
            }
        }
    }

    private func startStream(_ request: Request) throws -> Stream {
        // Open the physical microphone directly to avoid AVAudioEngine's default-device discovery.
        guard let device = MicrophoneDevices.computer, let format = MicrophoneDevices.inputFormat(device) else {
            throw MicrophoneBridge.BridgeError.computerInputUnavailable
        }
        guard isRequested(request) else { throw CancellationError() }
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw MicrophoneBridge.BridgeError.computerInputUnavailable
        }
        guard isRequested(request) else { throw CancellationError() }
        let pending = DispatchSemaphore(value: 8)
        let queue = self.queue
        var callback: AudioDeviceIOProcID?
        let result = AudioDeviceCreateIOProcIDWithBlock(&callback, device, nil) { _, input, _, _, _ in
            // HAL owns these samples until the callback returns. Keep the worker backlog bounded.
            guard pending.wait(timeout: .now()) == .success else { return }
            guard let pcm = Self.copyInput(input, format: format) else {
                pending.signal()
                return
            }
            queue.async {
                defer { pending.signal() }
                if let samples = Self.convert(pcm, using: converter, target: target) {
                    request.receive(samples)
                }
            }
        }
        guard result == noErr, let callback else {
            throw MicrophoneBridge.BridgeError.computerInputFailed(operation: "AudioDeviceCreateIOProcIDWithBlock", status: result)
        }
        guard isRequested(request) else {
            AudioDeviceDestroyIOProcID(device, callback)
            throw CancellationError()
        }
        let startResult = AudioDeviceStart(device, callback)
        guard startResult == noErr else {
            AudioDeviceDestroyIOProcID(device, callback)
            throw MicrophoneBridge.BridgeError.computerInputFailed(operation: "AudioDeviceStart", status: startResult)
        }
        return Stream(id: request.id, device: device, callback: callback)
    }

    private static func copyInput(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = source.first else { return nil }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        let frames = first.mDataByteSize / bytesPerFrame
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for (input, output) in zip(source, destination) {
            guard input.mNumberChannels == output.mNumberChannels, input.mDataByteSize == output.mDataByteSize,
                  let source = input.mData, let destination = output.mData else { return nil }
            memcpy(destination, source, Int(input.mDataByteSize))
        }
        return pcm
    }

    private static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter,
                                target: AVAudioFormat) -> [Float]? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 32
        guard let pcm = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        let outcome = converter.convert(to: pcm, error: nil) { _, state in
            if consumed {
                state.pointee = .noDataNow
                return nil
            }
            consumed = true
            state.pointee = .haveData
            return input
        }
        guard outcome != .error, let channel = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
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
