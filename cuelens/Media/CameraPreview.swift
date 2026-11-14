import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Observation

struct CameraDevice: Identifiable {
    let id: String
    let name: String

    static func available() -> [Self] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.filter { !VirtualCameraOutput.isVirtual($0.uniqueID) }.map { Self(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func resolve(_ id: String?) -> AVCaptureDevice? {
        id.flatMap(AVCaptureDevice.init(uniqueID:)) ?? (id == nil ? AVCaptureDevice.default(for: .video) : nil)
    }
}

enum CameraFailure: LocalizedError {
    case permission, unavailable, interrupted, unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .permission: "Camera access is off. Enable CueLens in Privacy & Security → Camera."
        case .unavailable: "The selected camera is unavailable. Reconnect it or close an app that is using it."
        case .interrupted: "The camera stopped responding. Check your device and start the preview again."
        case .unsupportedFormat: "This camera no longer supports the selected resolution or frame rate. Choose another format."
        }
    }
}

struct CameraFrame {
    let capturedAt: TimeInterval
    let original: CGImage
    let processed: CGImage
    let tracking: CameraTrackingSample
    let crop: CGRect
    let status: String
    let postureCue: String?
    let fps: Double
    let processingMilliseconds: Double
    let droppedFrames: Int
    var gazeStatus: String? = nil
    var gazeApplied = false
}

/// The camera queue must never accumulate full-resolution images behind a busy UI.
/// Finishing with an error preserves the newest pending frame and then reports failure.
struct CameraFrameFeed {
    let stream: AsyncThrowingStream<CameraFrame, Error>
    private let continuation: AsyncThrowingStream<CameraFrame, Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func receive(_ result: Result<CameraFrame, CameraFailure>) {
        switch result {
        case .success(let frame): continuation.yield(frame)
        case .failure(let error): continuation.finish(throwing: error)
        }
    }

    func finish() { continuation.finish() }
}

@MainActor
@Observable
final class CameraPreview {
    private(set) var starting = false
    private(set) var active = false
    private(set) var frame: CameraFrame?
    private(set) var error: String?
    private(set) var publishing = false
    private(set) var virtualError: String?
    private(set) var deviceID: String?
    private(set) var deskCalibration: DeskCalibration?
    private(set) var calibrationMessage = ""
    private(set) var calibrating = false
    private(set) var calibrationProgress = 0.0
    private(set) var backgroundName: String?
    var format: CameraFormatChoice? { didSet { saveSettings() } }
    var framing = FramingSettings() { didSet { configure(); saveSettings() } }
    var effects = VideoEffects() { didSet { configure(); saveSettings() } }
    var posture = PostureSettings() { didSet { configure(); saveSettings() } }
    var gaze = NativeGazeSettings() { didSet { configure(); saveSettings() } }
    var preset = ResourcePreset.balanced { didSet { configure() } }
    var thermal = ProcessInfo.processInfo.thermalState { didSet { configure() } }
    var lowResources = false { didSet { configure() } }
    @ObservationIgnored var onSettingsChanged: ((CameraStudioSettings) -> Void)?
    @ObservationIgnored private var applyingSettings = false
    @ObservationIgnored private var background: CGImage?
    @ObservationIgnored private var engine: CameraEngine?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var frameWork: Task<Void, Never>?
    @ObservationIgnored private var calibrationWork: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()

    var settingsSnapshot: CameraStudioSettings {
        var savedEffects = effects
        if savedEffects.background == .replacement { savedEffects.background = .original }
        var savedFraming = framing
        savedFraming.locked = false
        return CameraStudioSettings(deviceID: deviceID, format: format, framing: savedFraming,
                                    effects: savedEffects, posture: posture, calibration: deskCalibration, gaze: gaze)
    }

    func applySettings(_ settings: CameraStudioSettings) {
        guard !active, !starting else { return }
        applyingSettings = true
        deviceID = settings.deviceID
        format = settings.format
        framing = settings.framing
        framing.locked = false
        effects = settings.effects
        if effects.background == .replacement { effects.background = .original }
        posture = settings.posture
        deskCalibration = settings.calibration
        gaze = settings.gaze ?? NativeGazeSettings()
        applyingSettings = false
    }

    func selectDevice(_ id: String?) {
        guard !active, !starting, deviceID != id else { return }
        deviceID = id
        deskCalibration = nil
        calibrationMessage = ""
        format = preferredFormat(for: id)
        saveSettings()
    }

    private func saveSettings() {
        if !applyingSettings { onSettingsChanged?(settingsSnapshot) }
    }

    func formatChoices(for deviceID: String?) -> [CameraFormatChoice] {
        CameraDevice.resolve(deviceID).map(CameraFormatChoice.supported) ?? []
    }

    func preferredFormat(for deviceID: String?) -> CameraFormatChoice? {
        let available = formatChoices(for: deviceID)
        return available.first { $0.width == 1280 && $0.height == 720 && $0.fps == 30 }
            ?? available.last { $0.width <= 1280 && $0.fps == 30 }
            ?? available.last
    }

    func start(deviceID: String? = nil) {
        guard !active, !starting else { return }
        let token = UUID()
        self.token = token
        if self.deviceID != deviceID {
            deskCalibration = nil
            if let format, !formatChoices(for: deviceID).contains(format) { self.format = nil }
        }
        self.deviceID = deviceID
        if format == nil { format = preferredFormat(for: deviceID) }
        saveSettings()
        starting = true
        error = nil
        frame = nil
        calibrationMessage = ""
        request = Task { [weak self] in
            guard let self else { return }
            do {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: break
                case .notDetermined:
                    guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraFailure.permission }
                default: throw CameraFailure.permission
                }
                try Task.checkCancellation()
                let feed = CameraFrameFeed()
                let engine = CameraEngine { result in feed.receive(result) }
                frameWork = Task { [weak self] in
                    do {
                        for try await frame in feed.stream {
                            guard let self, !Task.isCancelled, self.token == token else { return }
                            self.frame = frame
                        }
                    } catch {
                        guard let self, !Task.isCancelled, self.token == token else { return }
                        self.stop()
                        self.error = error.localizedDescription
                    }
                }
                self.engine = engine
                configure()
                try await engine.start(deviceID: deviceID, format: format)
                try Task.checkCancellation()
                guard self.token == token else { engine.stop(); return }
                active = true
                starting = false
            } catch {
                guard self.token == token else { return }
                stop()
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func recenter() {
        framing.locked = false
        engine?.recenter()
    }

    func setBackground(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920
              ] as CFDictionary) else {
            error = "CueLens couldn’t read this background image. Choose a PNG or JPEG."
            return
        }
        background = image
        backgroundName = url.lastPathComponent
        effects.background = .replacement
    }

    func calibrateDesk() {
        guard active, !calibrating else { return }
        calibrating = true
        calibrationProgress = 0
        calibrationMessage = "Sit comfortably with the lens at eye level and both shoulders in view. Hold still for three seconds."
        calibrationWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            var samples = [CameraTrackingSample]()
            var lastFrameTime: TimeInterval = 0
            for step in 0..<22 {
                guard let self, !Task.isCancelled else { return }
                if let frame, frame.capturedAt > lastFrameTime {
                    lastFrameTime = frame.capturedAt
                    if frame.tracking.face != nil { samples.append(frame.tracking) }
                }
                calibrationProgress = Double(step + 1) / 22
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            calibrating = false
            calibrationProgress = 0
            guard let calibration = DeskCalibration(samples: samples) else {
                calibrationMessage = "Keep your face in view and hold a steady sitting position, then try again."
                return
            }
            deskCalibration = calibration
            calibrationMessage = calibration.shoulderMidpoint != nil ? "Your desk position and shoulder alignment are calibrated."
                : "Face position saved. Shoulder coaching needs both shoulders in view."
            saveSettings()
            configure()
            recenter()
        }
    }

    func resetCalibration() {
        calibrationWork?.cancel()
        calibrationWork = nil
        calibrating = false
        calibrationProgress = 0
        deskCalibration = nil
        calibrationMessage = ""
        configure()
        saveSettings()
    }

    func setPublishing(_ enabled: Bool) {
        guard let engine, active else { return }
        if !enabled { publishing = false }
        virtualError = nil
        let token = token
        engine.setPublishing(enabled) { [weak self] result in
            Task { @MainActor in
                guard let self, self.token == token else { return }
                switch result {
                case .success(let active): self.publishing = active
                case .failure(let error):
                    self.publishing = false
                    self.virtualError = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        calibrationWork?.cancel()
        calibrationWork = nil
        calibrating = false
        calibrationProgress = 0
        token = UUID()
        request?.cancel()
        request = nil
        frameWork?.cancel()
        frameWork = nil
        engine?.stop()
        engine = nil
        starting = false
        active = false
        frame = nil
        publishing = false
    }

    private func configure() {
        let reduced = lowResources || thermal == .serious || thermal == .critical
        engine?.configure(framing: framing, effects: effects, posture: posture, calibration: deskCalibration,
                          background: background, preset: reduced ? .low : preset, throttled: reduced, gaze: gaze)
    }
}

private final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.cuelens.camera", qos: .userInitiated)
    private let capture = AVCaptureSession()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let output: @Sendable (Result<CameraFrame, CameraFailure>) -> Void
    private let tracker = CameraTracker()
    private let effectsProcessor = CameraEffects()
    private lazy var gazeProcessor = NativeGazeProcessor()
    private var gazeSettings = NativeGazeSettings()
    private var framing = CameraFraming()
    private var coach = PostureCoach()
    private var framingSettings = FramingSettings()
    private var effects = VideoEffects()
    private var posture = PostureSettings()
    private var calibration: DeskCalibration?
    private var background: CIImage?
    private var latestTracking = CameraTrackingSample.unavailable
    private var virtualCamera: VirtualCameraOutput?
    private var publishStatus: (@Sendable (Result<Bool, Error>) -> Void)?
    private var observers = [NSObjectProtocol]()
    private var running = false
    private var throttled = false
    private var fpsTarget = 30.0
    private var lastFrame = 0.0
    private var lastDetection = 0.0
    private var rateStart = 0.0
    private var fps = 0.0
    private var frameCount = 0
    private var droppedFrames = 0
    private var lateFrames = 0
    private var reduceEffectsUntil = 0.0
    private var retired = false

    init(output: @escaping @Sendable (Result<CameraFrame, CameraFailure>) -> Void) { self.output = output }

    func start(deviceID: String?, format: CameraFormatChoice?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.retired else { throw CancellationError() }
                    try self.startOnQueue(deviceID: deviceID, format: format)
                    continuation.resume()
                } catch { self.stopOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }

    func stop() { queue.async { self.retired = true; self.stopOnQueue() } }
    func recenter() { queue.async { self.framing.reset() } }

    func setPublishing(_ enabled: Bool, report: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        queue.async {
            self.publishStatus = report
            if enabled, self.running {
                do {
                    if self.virtualCamera == nil { self.virtualCamera = try VirtualCameraOutput() }
                    report(.success(true))
                } catch { report(.failure(error)) }
            } else {
                self.virtualCamera?.stop()
                self.virtualCamera = nil
                report(.success(false))
            }
        }
    }

    func configure(framing: FramingSettings, effects: VideoEffects, posture: PostureSettings, calibration: DeskCalibration?, background: CGImage?, preset: ResourcePreset, throttled: Bool, gaze: NativeGazeSettings) {
        queue.async {
            self.framingSettings = framing
            self.effects = effects
            self.posture = posture
            self.calibration = calibration
            self.background = background.map { CIImage(cgImage: $0) }
            self.throttled = throttled
            self.fpsTarget = preset == .low ? 15 : 30
            self.gazeSettings = gaze
        }
    }

    private func startOnQueue(deviceID: String?, format: CameraFormatChoice?) throws {
        guard let device = CameraDevice.resolve(deviceID), device.isConnected,
              !VirtualCameraOutput.isVirtual(device.uniqueID) else { throw CameraFailure.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: queue)
        guard capture.canAddInput(input), capture.canAddOutput(video) else { throw CameraFailure.unavailable }
        capture.beginConfiguration()
        capture.addInput(input)
        capture.addOutput(video)
        capture.commitConfiguration()
        // macOS may choose a new format when starting a session. Keep the device
        // locked through startRunning so the explicitly selected format is retained.
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if let format {
            guard let supported = format.matchingFormat(in: device) else { throw CameraFailure.unsupportedFormat }
            device.activeFormat = supported
            let duration = CMTime(value: 1, timescale: format.fps)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: capture, queue: nil) {
            [weak self] _ in self?.output(.failure(.interrupted))
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
            [weak self] _ in self?.output(.failure(.unavailable))
        })
        capture.startRunning()
        running = capture.isRunning
        guard running else { throw CameraFailure.unavailable }
    }

    private func stopOnQueue() {
        running = false
        virtualCamera?.stop()
        virtualCamera = nil
        publishStatus = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if capture.isRunning { capture.stopRunning() }
        context.clearCaches()
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        droppedFrames += 1
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard running, now - lastFrame >= 0.85 / fpsTarget, let buffer = sample.imageBuffer else { return }
        lastFrame = now
        let input = CIImage(cvPixelBuffer: buffer)
        guard let original = context.createCGImage(input, from: input.extent) else { return }
        let reducedWork = throttled || now < reduceEffectsUntil
        if now - lastDetection >= (reducedWork ? 0.25 : 0.12) {
            latestTracking = tracker.detect(buffer, posture: posture.enabled && !reducedWork)
            lastDetection = now
        }
        let crop = framing.update(latestTracking, settings: framingSettings, now: now)
        var gazeImage = input
        var gazeStatus: String?
        var gazeApplied = false
        if gazeSettings.enabled {
            if effects.bypass {
                gazeStatus = "Eye correction bypassed"
            } else if reducedWork {
                gazeStatus = "Eye correction paused · Resource pressure"
            } else {
                let result = gazeProcessor.process(buffer: buffer, image: input, context: context, strength: gazeSettings.strength)
                gazeImage = result.image
                gazeStatus = result.status
                gazeApplied = result.applied
            }
        }
        let adjusted = effectsProcessor.apply(gazeImage, buffer: buffer, settings: effects, background: background, reducedWork: reducedWork)
        let processedInput: CIImage
        if effects.bypass {
            processedInput = input
        } else {
            let bounds = CGRect(x: input.extent.minX + crop.minX * input.extent.width,
                                y: input.extent.minY + crop.minY * input.extent.height,
                                width: crop.width * input.extent.width, height: crop.height * input.extent.height)
            processedInput = adjusted.image.cropped(to: bounds)
                .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .transformed(by: CGAffineTransform(scaleX: input.extent.width / bounds.width, y: input.extent.height / bounds.height))
                .cropped(to: input.extent)
        }
        guard let processed = context.createCGImage(processedInput, from: input.extent) else { return }
        var status = latestTracking.face == nil ? "Face uncertain · Holding or widening the frame" : "Face tracked locally"
        if framingSettings.locked { status = "Framing locked" }
        if effects.bypass { status = "Original camera · Effects bypassed" }
        if let effectStatus = adjusted.status { status = effectStatus }
        let postureCue = coach.update(latestTracking, calibration: calibration, settings: posture, now: now)?.rawValue
        if let virtualCamera {
            do { try virtualCamera.send(processedInput, using: context) }
            catch {
                virtualCamera.stop()
                self.virtualCamera = nil
                publishStatus?(.failure(error))
            }
        }
        if rateStart == 0 {
            rateStart = now
        } else {
            frameCount += 1
        }
        if now - rateStart >= 1 {
            fps = Double(frameCount) / (now - rateStart)
            frameCount = 0
            rateStart = now
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - now
        lateFrames = elapsed > 1.25 / fpsTarget ? lateFrames + 1 : max(0, lateFrames - 1)
        if lateFrames >= 8 { reduceEffectsUntil = now + 5; lateFrames = 0 }
        self.output(.success(CameraFrame(capturedAt: now, original: original, processed: processed, tracking: latestTracking,
                                         crop: crop, status: status, postureCue: postureCue, fps: fps,
                                         processingMilliseconds: elapsed * 1_000, droppedFrames: droppedFrames,
                                         gazeStatus: gazeStatus, gazeApplied: gazeApplied)))
    }
}
