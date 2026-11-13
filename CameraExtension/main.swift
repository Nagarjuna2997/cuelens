import CoreMediaIO
import Foundation
import Security

private enum Video {
    static let width: Int32 = 640
    static let height: Int32 = 480
    static let duration = CMTime(value: 1, timescale: 30)
    static let deviceID = UUID(uuidString: "4D1DE982-586D-49C9-93E5-6E10E0F442A6")!
    static let sourceID = UUID(uuidString: "B9DF0AD3-959D-45AC-B35B-C9673194035D")!
    static let sinkID = UUID(uuidString: "F08D7B5F-3247-497A-925B-BD51DC7268B8")!
}

private final class CameraRelay {
    private let queue = DispatchQueue(label: "org.cuelens.camera.relay", qos: .userInitiated)
    private let description: CMVideoFormatDescription
    private let black: CVPixelBuffer
    private var pending = false
    private var timer: DispatchSourceTimer?
    private var lastForwarded = 0.0
    private var sources = 0
    private var sinks = 0
    weak var source: CMIOExtensionStream?
    weak var sink: CMIOExtensionStream?

    init() throws {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                                    width: Video.width, height: Video.height, extensions: nil,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else { throw CocoaError(.coderInvalidValue) }
        self.description = description
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(Video.width), Int(Video.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw CocoaError(.coderInvalidValue) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let pixels = base.assumingMemoryBound(to: UInt32.self)
            let count = CVPixelBufferGetDataSize(buffer) / MemoryLayout<UInt32>.size
            pixels.update(repeating: UInt32(0xff000000).littleEndian, count: count)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        black = buffer
    }

    var format: CMIOExtensionStreamFormat {
        CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: Video.duration,
                                  minFrameDuration: Video.duration, validFrameDurations: nil)
    }

    func start(source: Bool) {
        queue.async { [self] in
            if source { self.sources += 1 } else { self.sinks += 1 }
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop(source: Bool) {
        queue.async {
            if source { self.sources = max(0, self.sources - 1) } else { self.sinks = max(0, self.sinks - 1) }
            if self.sources == 0 && self.sinks == 0 {
                self.timer?.cancel()
                self.timer = nil
            }
        }
    }

    private func tick() {
        if sinks > 0, !pending, let sink, let client = sink.streamingClients.first {
            pending = true
            sink.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, _ in
                guard let self else { return }
                queue.async {
                    self.pending = false
                    guard let sample, self.sinks > 0 else { return }
                    let time = CMClockGetTime(CMClockGetHostTimeClock())
                    let nanos = UInt64(max(0, CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value))
                    self.sink?.notifyScheduledOutputChanged(.init(sequenceNumber: sequence, hostTimeInNanoseconds: nanos))
                    if self.sources > 0, let image = sample.imageBuffer,
                       CVPixelBufferGetWidth(image) == Int(Video.width), CVPixelBufferGetHeight(image) == Int(Video.height),
                       CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA {
                        self.forward(image, at: time, nanos: nanos)
                    }
                }
            }
        }
        if sources > 0, ProcessInfo.processInfo.systemUptime - lastForwarded > 0.20 {
            let time = CMClockGetTime(CMClockGetHostTimeClock())
            let nanos = UInt64(max(0, CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value))
            forward(black, at: time, nanos: nanos)
        }
    }

    private func forward(_ image: CVPixelBuffer, at time: CMTime, nanos: UInt64) {
        var timing = CMSampleTimingInfo(duration: Video.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let result = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                              formatDescription: description, sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        if result == noErr, let sample {
            source?.send(sample, discontinuity: [], hostTimeInNanoseconds: nanos)
            lastForwarded = ProcessInfo.processInfo.systemUptime
        }
    }
}

private final class Stream: NSObject, CMIOExtensionStreamSource {
    let relay: CameraRelay
    let isSource: Bool
    lazy var stream = CMIOExtensionStream(localizedName: isSource ? "Camera" : "CueLens Frame Input",
                                          streamID: isSource ? Video.sourceID : Video.sinkID,
                                          direction: isSource ? .source : .sink, clockType: .hostTime, source: self)

    init(relay: CameraRelay, isSource: Bool) {
        self.relay = relay
        self.isSource = isSource
    }

    var formats: [CMIOExtensionStreamFormat] { [relay.format] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = Video.duration }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, index != 0 { throw CocoaError(.featureUnsupported) }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        if isSource { return true }
        guard let host = Bundle.main.object(forInfoDictionaryKey: "CueLensHostIdentifier") as? String,
              let team = Bundle.main.object(forInfoDictionaryKey: "CueLensSigningTeam") as? String,
              !team.isEmpty, client.signingID == host else { return false }
        let identity = "anchor apple generic and identifier \"\(host)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        var code: SecCode?
        return SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess
            && SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: client.pid] as CFDictionary, [], &code) == errSecSuccess
            && code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
    }

    func startStream() throws { relay.start(source: isSource) }
    func stopStream() throws { relay.stop(source: isSource) }
}

private final class Device: NSObject, CMIOExtensionDeviceSource {
    private let input: Stream
    private let output: Stream
    lazy var device = CMIOExtensionDevice(localizedName: "CueLens Camera", deviceID: Video.deviceID,
                                         legacyDeviceID: nil, source: self)

    override init() {
        let relay: CameraRelay
        do { relay = try CameraRelay() }
        catch { fatalError("CueLens Camera could not allocate its format.") }
        input = Stream(relay: relay, isSource: false)
        output = Stream(relay: relay, isSource: true)
        super.init()
        relay.source = output.stream
        relay.sink = input.stream
    }

    func connectStreams() throws {
        try device.addStream(output.stream)
        try device.addStream(input.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) { result.model = "CueLens Virtual Camera" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

private final class Provider: NSObject, CMIOExtensionProviderSource {
    private let device = Device()
    lazy var provider = CMIOExtensionProvider(source: self, clientQueue: nil)

    func addDevice() throws {
        try device.connectStreams()
        try provider.addDevice(device.device)
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "CueLens" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

private let service = Provider()
do {
    try service.addDevice()
    CMIOExtensionProvider.startService(provider: service.provider)
    CFRunLoopRun()
} catch {
    fputs("CueLens Camera could not register its device.\n", stderr)
    exit(1)
}
