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
            .devices.map { Self(id: $0.uniqueID, name: $0.localizedName) }
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
    var tracking = false { didSet { configure() } }
    var correction = false { didSet { configure() } }
    var strength = 0.55 { didSet { configure() } }
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

    func stop() {
        token = UUID()
        request?.cancel()
        request = nil
        engine?.stop()
        engine = nil
        starting = false
        active = false
        frame = nil
    }

    private func configure() {
        let safe = !lowResources && thermal != .serious && thermal != .critical
        engine?.configure(tracking: tracking && safe, correction: correction && safe, strength: strength,
                          preset: safe ? preset : .low, throttled: !safe)
    }
}

private final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.cuelens.camera", qos: .userInitiated)
    private let capture = AVCaptureSession()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let output: @Sendable (Result<CameraFrame, CameraFailure>) -> Void
    private var gaze: GazeCorrection?
    private var observers = [NSObjectProtocol]()
    private var running = false
    private var tracking = false
    private var correction = false
    private var throttled = false
    private var strength = 0.55
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

    func configure(tracking: Bool, correction: Bool, strength: Double, preset: ResourcePreset, throttled: Bool) {
        queue.async {
            self.tracking = tracking
            self.correction = correction
            self.throttled = throttled
            self.strength = strength
            switch preset {
            case .low: self.fpsTarget = 8
            case .balanced: self.fpsTarget = 14
            case .performance: self.fpsTarget = 24
            }
            if !tracking && !correction { self.gaze = nil }
        }
    }

    private func startOnQueue(deviceID: String?) throws {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? (deviceID == nil ? AVCaptureDevice.default(for: .video) : nil)
        guard let device, device.isConnected else { throw CameraFailure.unavailable }
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
        var centers = [CGPoint]()
        var status = throttled ? "Resource limits · Original feed" : "Original feed"
        if tracking || correction {
            if gaze == nil { gaze = GazeCorrection() }
            if let gaze {
                let eyes = gaze.eyes(in: buffer)
                centers = eyes.map { CGPoint(x: $0.pupil.x / input.extent.width, y: 1 - $0.pupil.y / input.extent.height) }
                if eyes.count != 2 {
                    status = "Eye landmarks uncertain · Original feed"
                } else if correction, let image = gaze.apply(to: input, eyes: eyes, strength: strength) {
                    corrected = context.createCGImage(image, from: input.extent)
                    status = corrected == nil ? "Correction unavailable · Original feed" : "Experimental correction applied"
                } else if correction {
                    status = "Correction unavailable · Original feed"
                } else {
                    status = "Eye landmarks tracked locally"
                }
            }
        }
        if rateStart == 0 { rateStart = now }
        frameCount += 1
        if now - rateStart >= 1 {
            fps = Double(frameCount) / (now - rateStart)
            frameCount = 0
            rateStart = now
        }
        self.output(.success(CameraFrame(original: original, corrected: corrected, eyeCenters: centers, status: status, fps: fps)))
    }
}
