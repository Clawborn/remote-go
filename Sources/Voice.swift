import AppKit
import AVFoundation
import CoreBluetooth
import Speech

struct VoiceCapabilities {
    let modern: Bool
    let codec: UInt8
    let holdToTalk: Bool
    let frameSize: Int

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 7, bytes[0] == 0x0B else { return nil }
        let version = Self.word(bytes, 1)
        guard version == 0x0100 || (version == 4 && bytes.count >= 9) else { return nil }
        modern = version == 0x0100
        holdToTalk = modern && bytes[4] == 3
        let codecs = bytes[modern ? 3 : 4]
        guard codecs & 3 != 0 else { return nil }
        codec = codecs & 2 != 0 ? 2 : 1
        frameSize = Int(Self.word(bytes, 5))
        guard frameSize > (modern ? 0 : 6), frameSize <= 1024 else { return nil }
    }

    static func word(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    var open: [UInt8] { modern ? [0x0C, 0] : [0x0C, 0, codec] }
    func close(_ stream: UInt8) -> [UInt8] { modern ? [0x0D, stream] : [0x0D] }
}

struct ADPCM {
    private static let steps = [
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,
        107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,
        796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,
        4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,
        16818,18500,20350,22385,24623,27086,29794,32767
    ]
    private static let changes = [-1,-1,-1,-1,2,4,6,8]
    private var predictor = 0
    private var index = 0

    mutating func sync(_ word: UInt16, _ step: UInt8) {
        predictor = Int(Int16(bitPattern: word))
        index = min(88, Int(step))
    }

    mutating func decode(_ bytes: ArraySlice<UInt8>) -> [Int16] {
        bytes.flatMap { byte in [sample(Int(byte >> 4)), sample(Int(byte & 15))] }
    }

    private mutating func sample(_ nibble: Int) -> Int16 {
        let step = Self.steps[index]
        var change = step >> 3
        if nibble & 4 != 0 { change += step }
        if nibble & 2 != 0 { change += step >> 1 }
        if nibble & 1 != 0 { change += step >> 2 }
        predictor = max(-32768, min(32767, predictor + (nibble & 8 == 0 ? change : -change)))
        index = max(0, min(88, index + Self.changes[nibble & 7]))
        return Int16(predictor)
    }
}

final class RemoteVoice: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var status: ((String) -> Void)?
    var result: ((String, AXUIElement?) -> Void)?
    var locale = "zh-CN"
    var button: ((Bool) -> Void)?
    private var keysOnly = false
    private var pendingVoicePress: UInt8?
    private var completedVoicePress = false

    static func voiceButtonEdge(_ bytes: [UInt8]) -> Bool? {
        switch (bytes.first, bytes.dropFirst().first) {
        case (0x04, 0x03) where bytes.count >= 4: return true
        case (0x00, 0x02): return false
        default: return nil
        }
    }

    private static func uuid(_ id: Int) -> CBUUID {
        CBUUID(string: "AB5E000\(id)-5A21-4F05-BC7D-AF01F617B664")
    }

    private let service = RemoteVoice.uuid(1), txID = RemoteVoice.uuid(2)
    private let audioID = RemoteVoice.uuid(3), controlID = RemoteVoice.uuid(4)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var subscribed: Set<CBUUID> = []
    private var caps: VoiceCapabilities?
    private var watchdog: Timer?
    private var retry: Timer?
    private var requested = false
    private var stream: UInt8?
    private var started = Date.distantPast
    private var lastFrame = Date.distantPast
    private var lastExtend = Date.distantPast
    private var byteQueue: [UInt8] = []
    private var decoder = ADPCM()
    private var format: AVAudioFormat?
    private var codec: UInt8 = 2
    private var sampleCount = 0
    private var peak = 0
    private var previousSample: Int16?
    private var recognizer: SFSpeechRecognizer?
    private var speech: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishTimer: Timer?
    private var generation = UUID()
    private var partial = ""
    private var focusedInput: AXUIElement?
    private var authorizationPending = false

    func enable(keysOnly: Bool = false) {
        guard central == nil, !authorizationPending else { return }
        self.keysOnly = keysOnly
        if keysOnly {
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        authorizationPending = true
        status?("等待语音识别权限")
        SFSpeechRecognizer.requestAuthorization { [weak self] access in
            DispatchQueue.main.async {
                guard let self, self.authorizationPending else { return }
                self.authorizationPending = false
                guard access == .authorized else { self.status?("请在隐私与安全性中允许语音识别"); return }
                self.central = CBCentralManager(delegate: self, queue: .main)
            }
        }
    }

    func disable() {
        authorizationPending = false
        cancelSpeech()
        if let id = stream { write(caps?.close(id) ?? []) }
        watchdog?.invalidate()
        watchdog = nil
        retry?.invalidate()
        retry = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        central = nil
        resetConnection()
        status?("语音已关闭")
    }

    func toggle() {
        if requested || stream != nil { end(close: true); return }
        guard let caps else { status?("请先启用语音，并等待遥控器语音通道就绪"); return }
        requested = true
        started = Date()
        write(caps.open)
        status?("已请求开启遥控器麦克风")
        beginWatchdog()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn: search()
        case .unauthorized: status?("请在隐私与安全性中允许蓝牙访问")
        case .poweredOff, .unsupported:
            cancelSpeech()
            resetConnection()
            status?("蓝牙不可用")
        default: status?("正在等待蓝牙")
        }
    }

    private static func isTarget(_ name: String?) -> Bool {
        name?.localizedCaseInsensitiveContains("Chromecast Remote") == true ||
            name?.localizedCaseInsensitiveContains("Chromecast Voice Remote") == true
    }

    private func search() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        if let match = (central.retrieveConnectedPeripherals(withServices: [service]) +
            central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812")])).first(where: { Self.isTarget($0.name) }) {
            connect(match)
            return
        }
        status?("寻找遥控器语音服务 · 可按一下遥控器唤醒")
        central.scanForPeripherals(withServices: [service], options: nil)
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.search() }
    }

    private func connect(_ device: CBPeripheral) {
        guard let central, peripheral == nil else { return }
        retry?.invalidate()
        central.stopScan()
        peripheral = device
        device.delegate = self
        status?("正在连接遥控器语音服务")
        central.connect(device)
        retry = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self, weak device] _ in
            guard let self, let device, self.peripheral === device else { return }
            self.central?.cancelPeripheralConnection(device)
            self.disconnected(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard Self.isTarget(device.name) ||
              Self.isTarget(advertisementData[CBAdvertisementDataLocalNameKey] as? String) else { return }
        connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard device === peripheral else { return }
        retry?.invalidate()
        status?("正在发现遥控器音频服务")
        device.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        disconnected(device)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        disconnected(device)
    }

    private func disconnected(_ device: CBPeripheral) {
        guard device === peripheral else { return }
        cancelSpeech()
        resetConnection()
        status?("遥控器语音已断开 · 正在等待重连")
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.search() }
    }

    private func resetConnection() {
        releaseVoiceButton()
        completedVoicePress = false
        watchdog?.invalidate()
        watchdog = nil
        peripheral?.delegate = nil
        peripheral = nil
        tx = nil
        caps = nil
        requested = false
        stream = nil
        subscribed.removeAll()
        byteQueue.removeAll()
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard device === peripheral else { return }
        guard let remoteService = device.services?.first(where: { $0.uuid == service }), error == nil else {
            status?("蓝牙已连接，但没有发现 ATVV 语音服务")
            return
        }
        device.discoverCharacteristics([txID, audioID, controlID], for: remoteService)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard device === peripheral else { return }
        guard error == nil, let characteristics = service.characteristics,
              let control = characteristics.first(where: { $0.uuid == controlID }),
              let audio = characteristics.first(where: { $0.uuid == audioID }),
              let tx = characteristics.first(where: { $0.uuid == txID }) else {
            status?("遥控器未公开完整的 ATVV 语音通道")
            return
        }
        self.tx = tx
        device.setNotifyValue(true, for: control)
        device.setNotifyValue(true, for: audio)
    }

    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral else { return }
        guard error == nil, characteristic.isNotifying else {
            status?("无法订阅遥控器语音数据")
            return
        }
        if subscribed.insert(characteristic.uuid).inserted, subscribed.count == 2 {
            write([0x0A, 1, 0, 0, 3, 3])
            status?("正在读取遥控器音频能力")
        }
    }

    func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, let error else { return }
        if stream != nil || requested { end(close: false) }
        status?("遥控器未接受语音指令 · \(error.localizedDescription)")
    }

    private func write(_ bytes: [UInt8]) {
        guard let peripheral, let tx, !bytes.isEmpty else { return }
        let mode: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: tx, type: mode)
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device === peripheral, error == nil, let data = characteristic.value, !data.isEmpty else { return }
        if characteristic.uuid == controlID { control(Array(data)) }
        if characteristic.uuid == audioID {
            if caps == nil, VoiceCapabilities(Array(data)) != nil { control(Array(data)) }
            else if !keysOnly { receivedAudio(data) }
        }
    }

    private func control(_ bytes: [UInt8]) {
        if keysOnly {
            controlAsKey(bytes)
            return
        }
        switch bytes[0] {
        case 0x0B:
            caps = VoiceCapabilities(bytes)
            status?(caps == nil ? "遥控器返回了不兼容的音频格式" : "遥控器麦克风就绪 · 按助理键说话")
        case 0x08: toggle()
        case 0x04:
            guard let caps, !caps.modern || bytes.count >= 4 else { return }
            start(stream: caps.modern ? bytes[3] : 0, codec: caps.modern ? bytes[2] : caps.codec)
        case 0x00:
            if stream != nil || requested {
                end(close: bytes.count < 2 || bytes[1] != 2)
            }
        case 0x0A:
            if caps?.modern == true, bytes.count >= 7, stream != nil {
                byteQueue.removeAll(keepingCapacity: true)
                decoder.sync(VoiceCapabilities.word(bytes, 4), bytes[6])
            }
        case 0x0C:
            requested = false
            watchdog?.invalidate()
            status?("遥控器拒绝开启麦克风")
        default: break
        }
    }

    private func controlAsKey(_ bytes: [UInt8]) {
        if bytes[0] == 0x0B {
            caps = VoiceCapabilities(bytes)
            status?(caps?.holdToTalk == true ? "语音键已连接 · 可测试按下和松开" : "遥控器未确认长按模式 · 可试按语音键")
            return
        }
        switch Self.voiceButtonEdge(bytes) {
        case true:
            guard pendingVoicePress == nil else { return }
            let id = bytes[3]
            pendingVoicePress = id
            started = Date()
            button?(true)
            status?("收到语音键按下")
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, self.pendingVoicePress == id else { return }
                if Date().timeIntervalSince(self.started) >= 45 {
                    self.releaseVoiceButton()
                } else {
                    self.write([0x0E, id])
                }
            }
        case false:
            if pendingVoicePress != nil {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                releaseVoiceButton()
                completedVoicePress = true
                status?("收到语音键松开 · 持续 \(elapsed) 毫秒")
            }
        case nil:
            if pendingVoicePress == nil, !completedVoicePress, bytes[0] == 0x08 || bytes[0] == 0x04 {
                status?("收到语音请求 · 等待实际按下和松开信号")
            }
        }
    }

    private func releaseVoiceButton() {
        guard pendingVoicePress != nil else { return }
        pendingVoicePress = nil
        watchdog?.invalidate()
        watchdog = nil
        button?(false)
    }

    private func start(stream id: UInt8, codec: UInt8) {
        guard stream == nil else { return }
        requested = false
        stream = id
        guard codec == 1 || codec == 2,
              let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              speechRecognizer.supportsOnDeviceRecognition, speechRecognizer.isAvailable,
              let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
        else {
            end(close: true)
            status?("当前语言的离线听写不可用 · 可尝试切换语言")
            return
        }
        cancelSpeech()
        decoder = ADPCM()
        byteQueue.removeAll(keepingCapacity: true)
        self.format = format
        self.codec = codec
        recognizer = speechRecognizer
        focusedInput = Output.focusedInput()
        started = Date()
        lastFrame = started
        lastExtend = started
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        speech = request
        generation = UUID()
        let token = generation
        task = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if let result { self.partial = result.bestTranscription.formattedString }
                if result?.isFinal == true || error != nil {
                    if self.stream != nil { self.end(close: true) }
                    self.complete()
                }
            }
        }
        status?("正在等待遥控器音频")
        beginWatchdog()
    }

    private func receivedAudio(_ data: Data) {
        guard stream != nil, let caps, let format, let speech else { return }
        if lastFrame == started { status?("正在听写 · 松开或再按语音键结束") }
        lastFrame = Date()
        byteQueue.append(contentsOf: data)
        while byteQueue.count >= caps.frameSize {
            let frame = Array(byteQueue.prefix(caps.frameSize))
            byteQueue.removeFirst(caps.frameSize)
            var samples: [Int16]
            if caps.modern {
                samples = decoder.decode(frame[...])
            } else {
                let initial = VoiceCapabilities.word(frame, 3)
                decoder.sync(initial, frame[5])
                samples = [Int16(bitPattern: initial)] + decoder.decode(frame[6...])
            }
            let sampleMultiplier = codec == 1 ? 2 : 1
            let frames = AVAudioFrameCount(samples.count * sampleMultiplier)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = frames
            for (index, value) in samples.enumerated() {
                peak = max(peak, abs(Int(value)))
                let current = Float(value) / 32768
                if sampleMultiplier == 2 {
                    channel[index * 2] = (Float(previousSample ?? value) / 32768 + current) / 2
                    channel[index * 2 + 1] = current
                    previousSample = value
                } else {
                    channel[index] = current
                }
            }
            sampleCount += Int(frames)
            speech.append(buffer)
        }
    }

    private func beginWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.checkStream()
        }
    }

    private func checkStream() {
        let now = Date()
        if requested, now.timeIntervalSince(started) > 4 {
            end(close: true)
            status?("遥控器没有返回音频 · 请唤醒后重试")
        } else if let stream {
            if now.timeIntervalSince(lastFrame) > 2.5 || now.timeIntervalSince(started) > 40 {
                end(close: true)
            } else if caps?.modern == true, now.timeIntervalSince(lastExtend) > 3 {
                lastExtend = now
                write([0x0E, stream])
            }
        }
    }

    private func end(close: Bool) {
        if close { write(caps?.close(stream ?? 0) ?? []) }
        stream = nil
        requested = false
        watchdog?.invalidate()
        watchdog = nil
        guard let speech else { status?("遥控器麦克风就绪 · 按助理键说话"); return }
        speech.endAudio()
        self.speech = nil
        status?("正在完成转写")
        finishTimer?.invalidate()
        finishTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.complete()
        }
    }

    private func complete() {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = focusedInput
        let duration = Double(sampleCount) / 16000
        let level = peak
        cancelSpeech()
        if !text.isEmpty {
            result?(text, target)
        } else if duration == 0 {
            status?("语音已经启动，但没有收到可解码的遥控器音频")
        } else {
            let seconds = duration.formatted(.number.precision(.fractionLength(1)))
            let percent = (Double(level) / 32768).formatted(.percent.precision(.fractionLength(0)))
            status?("收到 \(seconds) 秒音频 · 峰值 \(percent) · 未识别到文字")
        }
    }

    private func cancelSpeech() {
        generation = UUID()
        finishTimer?.invalidate()
        finishTimer = nil
        task?.cancel()
        task = nil
        speech = nil
        recognizer = nil
        partial = ""
        focusedInput = nil
        sampleCount = 0
        peak = 0
        previousSample = nil
        format = nil
    }
}
