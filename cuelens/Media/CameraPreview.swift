import AVFoundation
import CoreImage
import Foundation
import Observation

struct CameraDevice: Identifiable {
    let id: String
    let name: String

    static func available() -> [Self] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.filter { !VirtualCameraOutput.isVirtual($0.uniqueID) }.map { Self(id: $0.uniqueID, name: $0.localizedName) }
    }
}

enum CameraFailure: LocalizedError {
    case permission, unavailable, interrupted

    var errorDescription: String? {
        switch self {
        case .permission: "Camera access is off. Enable CueLens in Privacy & Security → Camera."
        case .unavailable: "The selected camera is unavailable. Reconnect it or close an app that is using it."
        case .interrupted: "The camera stopped responding. Check your device and start the preview again."
        }
    }
}

struct CameraFrame {
    let original: CGImage
    let corrected: CGImage?
    let eyeCenters: [CGPoint]
    let eyeAim: EyeAim?
    let status: String
    let fps: Double
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
    private(set) var calibration: GazeCalibration?
    private(set) var calibrationMessage = ""
    private(set) var calibrating = false
    @ObservationIgnored private var calibrationWork: Task<Void, Never>?
    var tracking = false { didSet { configure() } }
    var correction = false { didSet { configure() } }
    var strength = 0.85 { didSet { configure() } }
    var preset = ResourcePreset.balanced { didSet { configure() } }
    var thermal = ProcessInfo.processInfo.thermalState { didSet { configure() } }
    var lowResources = false { didSet { configure() } }
    @ObservationIgnored private var engine: CameraEngine?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()

    func start(deviceID: String?) {
        guard !active, !starting else { return }
        let token = UUID()
        self.token = token
        starting = true
        error = nil
        frame = nil
        calibration = nil
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
                let engine = CameraEngine { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.token == token else { return }
                        switch result {
                        case .success(let frame): self.frame = frame
                        case .failure(let failure):
                            self.stop()
                            self.error = failure.localizedDescription
                        }
                    }
                }
                self.engine = engine
                configure()
                try await engine.start(deviceID: deviceID)
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

    func calibrate(reading: Bool) {
        guard active, !calibrating, !lowResources, !reading || calibration != nil else { return }
        calibrating = true
        calibrationMessage = reading ? "Look at your notes and hold still…" : "Look directly into the camera and hold still…"
        configure()
        calibrationWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            var samples = GazeSampler()
            for _ in 0..<14 {
                guard let self, !Task.isCancelled else { return }
                if let aim = frame?.eyeAim { samples.add(aim) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            calibrating = false
            if let aim = samples.result {
                if reading {
                    calibration?.reading = aim
                    calibrationMessage = "Camera and reading positions calibrated."
                } else {
                    calibration = GazeCalibration(lens: aim)
                    calibrationMessage = "Camera position calibrated. You can also calibrate where you read."
                }
            } else {
                calibrationMessage = "Keep both eyes in view and try again."
            }
            configure()
        }
    }

    func resetCalibration() {
        calibration = nil
        calibrationMessage = ""
        configure()
    }

    func stop() {
        calibrationWork?.cancel()
        calibrationWork = nil
        calibrating = false
        token = UUID()
        request?.cancel()
        request = nil
        engine?.stop()
        engine = nil
        starting = false
        active = false
        frame = nil
        publishing = false
    }

    private func configure() {
        let safe = !lowResources && thermal != .serious && thermal != .critical
        engine?.configure(tracking: (tracking || calibrating) && safe, correction: correction && safe,
                          strength: strength, calibration: calibration, preset: safe ? preset : .low, throttled: !safe)
    }
}

private final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.cuelens.camera", qos: .userInitiated)
    private let capture = AVCaptureSession()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let output: @Sendable (Result<CameraFrame, CameraFailure>) -> Void
    private var gaze: GazeCorrection?
    private var virtualCamera: VirtualCameraOutput?
    private var publishStatus: (@Sendable (Result<Bool, Error>) -> Void)?
    private var observers = [NSObjectProtocol]()
    private var running = false
    private var tracking = false
    private var correction = false
    private var throttled = false
    private var strength = 0.85
    private var calibration: GazeCalibration?
    private var smoothAim: EyeAim?
    private var fpsTarget = 12.0
    private var lastFrame = 0.0
    private var rateStart = 0.0
    private var fps = 0.0
    private var frameCount = 0

    init(output: @escaping @Sendable (Result<CameraFrame, CameraFailure>) -> Void) { self.output = output }

    func start(deviceID: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.startOnQueue(deviceID: deviceID); continuation.resume() }
                catch { self.stopOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }

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

    func configure(tracking: Bool, correction: Bool, strength: Double, calibration: GazeCalibration?, preset: ResourcePreset, throttled: Bool) {
        queue.async {
            self.tracking = tracking
            self.correction = correction
            self.throttled = throttled
            self.strength = strength
            self.calibration = calibration
            switch preset {
            case .low: self.fpsTarget = 8
            case .balanced: self.fpsTarget = 14
            case .performance: self.fpsTarget = 24
            }
            if !tracking && !correction { self.gaze = nil; self.smoothAim = nil }
        }
    }

    private func startOnQueue(deviceID: String?) throws {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? (deviceID == nil ? AVCaptureDevice.default(for: .video) : nil)
        guard let device, device.isConnected, !VirtualCameraOutput.isVirtual(device.uniqueID) else { throw CameraFailure.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: queue)
        guard capture.canAddInput(input), capture.canAddOutput(video) else { throw CameraFailure.unavailable }
        capture.beginConfiguration()
        if capture.canSetSessionPreset(.vga640x480) { capture.sessionPreset = .vga640x480 }
        capture.addInput(input)
        capture.addOutput(video)
        capture.commitConfiguration()
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
        gaze = nil
        context.clearCaches()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard running, now - lastFrame >= 1 / fpsTarget,
              let buffer = sample.imageBuffer else { return }
        lastFrame = now
        let input = CIImage(cvPixelBuffer: buffer)
        guard let original = context.createCGImage(input, from: input.extent) else { return }
        var corrected: CGImage?
        var correctedInput: CIImage?
        var centers = [CGPoint]()
        var eyeAim: EyeAim?
        var status = throttled ? "Resource limits · Original feed" : "Original feed"
        if tracking || correction {
            if gaze == nil { gaze = GazeCorrection() }
            if let gaze {
                let eyes = gaze.eyes(in: buffer)
                centers = eyes.map { CGPoint(x: $0.pupil.x / input.extent.width, y: 1 - $0.pupil.y / input.extent.height) }
                if eyes.count != 2 {
                    smoothAim = nil
                    status = "Eye landmarks uncertain · Original feed"
                } else {
                    let aim = EyeAim(left: eyes[0].aim, right: eyes[1].aim)
                    eyeAim = aim
                    let smoothed = smoothAim?.averaged(with: aim, weight: 0.52) ?? aim
                    smoothAim = smoothed
                    if correction {
                        let weight = calibration?.weight(for: smoothed) ?? 1
                        if weight > 0.01, let image = gaze.apply(to: input, eyes: eyes, strength: strength * weight,
                                                                 target: calibration?.lens, observed: smoothed) {
                            corrected = context.createCGImage(image, from: input.extent)
                            if corrected != nil { correctedInput = image }
                            if corrected == nil { status = "Correction unavailable · Original feed" }
                            else { status = calibration == nil ? "Experimental correction" : "Calibrated correction" }
                        } else {
                            status = "Original feed · Correction inactive"
                        }
                    } else {
                        status = "Eye landmarks tracked locally"
                    }
                }
            }
        }
        if let virtualCamera {
            do { try virtualCamera.send(correctedInput ?? input, using: context) }
            catch {
                virtualCamera.stop()
                self.virtualCamera = nil
                publishStatus?(.failure(error))
            }
        }
        if rateStart == 0 { rateStart = now }
        frameCount += 1
        if now - rateStart >= 1 {
            fps = Double(frameCount) / (now - rateStart)
            frameCount = 0
            rateStart = now
        }
        self.output(.success(CameraFrame(original: original, corrected: corrected, eyeCenters: centers, eyeAim: eyeAim, status: status, fps: fps)))
    }
}
