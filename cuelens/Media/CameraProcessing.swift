import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum FramingPosition: String, Codable, CaseIterable, Identifiable {
    case center = "Center", leftThird = "Left third", rightThird = "Right third"
    var id: Self { self }
    var horizontalTarget: Double {
        switch self {
        case .center: 0.5
        case .leftThird: 1.0 / 3
        case .rightThird: 2.0 / 3
        }
    }
}

struct FramingSettings: Codable, Equatable {
    var enabled = true
    var position = FramingPosition.center
    var zoom = 1.18
    var headroom = 0.12
    var sensitivity = 0.45
    var deadZone = 0.035
    var locked = false
}

enum CameraBackground: String, Codable, CaseIterable, Identifiable {
    case original = "Original", blur = "Blur", replacement = "Image"
    var id: Self { self }
}

enum SegmentationQuality: String, Codable, CaseIterable, Identifiable {
    case fast = "Fast", balanced = "Balanced", accurate = "Detailed"
    var id: Self { self }
    var visionQuality: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
    }
}

struct VideoEffects: Codable, Equatable {
    var bypass = false
    var background = CameraBackground.original
    var segmentation = SegmentationQuality.balanced
    var blurRadius = 12.0
    var exposureEnabled = false
    var exposure = 0.25
    var colorEnabled = false
    var saturation = 1.0
    var lighting = false
    var denoise = false
}

struct CameraFormatChoice: Codable, Hashable, Identifiable {
    let width: Int32
    let height: Int32
    let fps: Int32
    var id: String { "\(width)x\(height)-\(fps)" }
    var label: String { "\(width) × \(height) · \(fps) fps" }

    static func supported(by device: AVCaptureDevice) -> [Self] {
        var choices = Set<Self>()
        for format in device.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard size.width >= 320, size.width <= 1920, size.height <= 1080 else { continue }
            for fps: Int32 in [15, 24, 30] where format.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
            }) {
                choices.insert(.init(width: size.width, height: size.height, fps: fps))
            }
        }
        return choices.sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            if lhs.height != rhs.height { return lhs.height < rhs.height }
            return lhs.fps < rhs.fps
        }
    }

    func matchingFormat(in device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.first { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == width && size.height == height && format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
            }
        }
    }
}

struct CameraTrackingSample {
    let face: CGRect?
    let confidence: Float
    let leftShoulder: CGPoint?
    let rightShoulder: CGPoint?
    var shouldersVisible: Bool { leftShoulder != nil && rightShoulder != nil }

    static let unavailable = Self(face: nil, confidence: 0, leftShoulder: nil, rightShoulder: nil)
}

/// Tracks only one visible person. Ambiguous detections never choose a different face.
final class CameraTracker {
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()

    func detect(_ buffer: CVPixelBuffer, posture: Bool) -> CameraTrackingSample {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        let requests: [VNRequest] = posture ? [faceRequest, bodyRequest] : [faceRequest]
        guard (try? handler.perform(requests)) != nil,
              let faces = faceRequest.results, faces.count == 1,
              let face = faces.first, face.confidence >= 0.75 else { return .unavailable }
        var left: CGPoint?
        var right: CGPoint?
        if posture, let bodies = bodyRequest.results, bodies.count == 1,
           let points = try? bodies[0].recognizedPoints(.all),
           let leftPoint = points[.leftShoulder], let rightPoint = points[.rightShoulder],
           leftPoint.confidence > 0.55, rightPoint.confidence > 0.55 {
            left = leftPoint.location
            right = rightPoint.location
        }
        return .init(face: face.boundingBox, confidence: face.confidence, leftShoulder: left, rightShoulder: right)
    }
}

struct CameraFraming {
    private(set) var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var lastTime: TimeInterval?
    private var lastFaceTime: TimeInterval?
    private var target = CGRect(x: 0, y: 0, width: 1, height: 1)

    mutating func reset() {
        lastTime = nil
        lastFaceTime = nil
    }

    mutating func update(_ observation: CameraTrackingSample, settings: FramingSettings, now: TimeInterval) -> CGRect {
        guard settings.enabled else {
            crop = CGRect(x: 0, y: 0, width: 1, height: 1)
            lastTime = now
            return crop
        }
        let delta = min(max(now - (lastTime ?? now), 0), 0.2)
        let first = lastTime == nil
        lastTime = now
        guard !settings.locked || first else { return crop }
        let zoom = min(max(settings.zoom, 1), 2.5)
        if let face = observation.face, observation.confidence >= 0.75 {
            lastFaceTime = now
            let horizontalTarget = settings.position.horizontalTarget
            let headroom = min(max(settings.headroom, 0.04), 0.3)
            // Preserve the whole detected face even when the requested zoom would cut it off.
            let horizontalSpace = 2 * min(horizontalTarget, 1 - horizontalTarget) - 0.08
            let requiredSide = max(face.width / horizontalSpace, face.height / (1 - headroom - 0.08))
            let side = min(1, max(1 / zoom, requiredSide))
            let desired = bounded(CGRect(x: face.midX - side * horizontalTarget,
                                         y: face.maxY - side * (1 - headroom), width: side, height: side))
            if first || abs(desired.midX - target.midX) > settings.deadZone || abs(desired.midY - target.midY) > settings.deadZone || abs(desired.width - target.width) > 0.005 {
                target = desired
            }
        } else if first || now - (lastFaceTime ?? 0) > 1.5 {
            // Ease back to the full view after losing the person, so reacquisition remains possible.
            target = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let weight = first ? 1 : 1 - exp(-delta * (1.5 + min(max(settings.sensitivity, 0), 1) * 7))
        crop = bounded(CGRect(x: crop.minX + (target.minX - crop.minX) * weight,
                              y: crop.minY + (target.minY - crop.minY) * weight,
                              width: crop.width + (target.width - crop.width) * weight,
                              height: crop.height + (target.height - crop.height) * weight))
        return crop
    }

    private func bounded(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0.1), 1)
        let height = min(max(rect.height, 0.1), 1)
        return CGRect(x: min(max(rect.minX, 0), 1 - width), y: min(max(rect.minY, 0), 1 - height), width: width, height: height)
    }
}

enum PostureCue: String, Codable, CaseIterable, Identifiable {
    case center = "Center your face"
    case distance = "Move slightly back"
    case shoulders = "Relax your shoulders"
    case seated = "Return to your calibrated sitting position"
    var id: Self { self }
}

struct PostureSettings: Codable, Equatable {
    var enabled = true
    var sensitivity = 0.5
    var enabledCues = Set(PostureCue.allCases)
}

struct DeskCalibration: Codable, Equatable {
    let face: CGRect
    let shoulderMidpoint: CGPoint?
    let shoulderHeightBelowFace: Double?

    init?(samples: [CameraTrackingSample]) {
        let valid = samples.filter { $0.face != nil && $0.confidence >= 0.75 }
        guard valid.count >= 10 else { return nil }
        let faces = valid.compactMap(\.face)
        let count = Double(faces.count)
        let mean = CGRect(x: faces.reduce(0) { $0 + $1.minX } / count,
                          y: faces.reduce(0) { $0 + $1.minY } / count,
                          width: faces.reduce(0) { $0 + $1.width } / count,
                          height: faces.reduce(0) { $0 + $1.height } / count)
        guard faces.allSatisfy({ hypot($0.midX - mean.midX, $0.midY - mean.midY) < 0.04 &&
            abs($0.height - mean.height) < 0.04 }) else { return nil }
        let shoulders = valid.filter(\.shouldersVisible)
        var left: CGPoint?
        var right: CGPoint?
        if shoulders.count >= 10 {
            let shoulderCount = Double(shoulders.count)
            left = CGPoint(x: shoulders.reduce(0) { $0 + ($1.leftShoulder?.x ?? 0) } / shoulderCount,
                           y: shoulders.reduce(0) { $0 + ($1.leftShoulder?.y ?? 0) } / shoulderCount)
            right = CGPoint(x: shoulders.reduce(0) { $0 + ($1.rightShoulder?.x ?? 0) } / shoulderCount,
                            y: shoulders.reduce(0) { $0 + ($1.rightShoulder?.y ?? 0) } / shoulderCount)
        }
        self.init(sample: .init(face: mean, confidence: 1, leftShoulder: left, rightShoulder: right))
    }

    init?(sample: CameraTrackingSample) {
        guard let face = sample.face, sample.confidence >= 0.75 else { return nil }
        self.face = face
        if let left = sample.leftShoulder, let right = sample.rightShoulder {
            let midpoint = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
            shoulderMidpoint = midpoint
            shoulderHeightBelowFace = face.midY - midpoint.y
        } else {
            shoulderMidpoint = nil
            shoulderHeightBelowFace = nil
        }
    }
}

struct PostureCoach {
    private var candidate: PostureCue?
    private var deviationBegan: TimeInterval = 0
    private var lastCueTime = -Double.infinity
    private(set) var message: PostureCue?
    private var messageUntil: TimeInterval = 0

    mutating func update(_ sample: CameraTrackingSample, calibration: DeskCalibration?, settings: PostureSettings, now: TimeInterval) -> PostureCue? {
        guard settings.enabled, let face = sample.face, sample.confidence >= 0.75 else {
            candidate = nil
            message = nil
            return nil
        }
        if now >= messageUntil { message = nil }
        if let message, !settings.enabledCues.contains(message) || (message == .shoulders && !sample.shouldersVisible) {
            self.message = nil
        }
        let sensitivity = min(max(settings.sensitivity, 0), 1)
        let threshold = 0.06 + (1 - sensitivity) * 0.08
        var next: PostureCue?
        if face.height > 0.44 && settings.enabledCues.contains(.distance) {
            next = .distance
        } else if let reference = calibration {
            if let baseline = reference.shoulderHeightBelowFace,
               let left = sample.leftShoulder, let right = sample.rightShoulder,
               reference.face.height > 0, face.height > 0,
               baseline / reference.face.height - (face.midY - (left.y + right.y) / 2) / face.height > 0.15 + (1 - sensitivity) * 0.25,
               settings.enabledCues.contains(.shoulders) {
                next = .shoulders
            } else if hypot(face.midX - reference.face.midX, face.midY - reference.face.midY) > threshold,
                      settings.enabledCues.contains(.seated) {
                next = .seated
            }
        } else if abs(face.midX - 0.5) > threshold + 0.12 && settings.enabledCues.contains(.center) {
            next = .center
        }
        if next != candidate {
            candidate = next
            deviationBegan = now
        }
        if let next, now - deviationBegan >= 3, now - lastCueTime >= 18 {
            message = next
            lastCueTime = now
            messageUntil = now + 6
        }
        return message
    }
}

final class CameraEffects {
    private let segmenter = VNGeneratePersonSegmentationRequest()

    func apply(_ input: CIImage, buffer: CVPixelBuffer, settings: VideoEffects, background: CIImage?, reducedWork: Bool) -> (image: CIImage, status: String?) {
        guard !settings.bypass else { return (input, "All effects bypassed") }
        var image = input
        var status: String?
        if settings.background != .original {
            if reducedWork {
                status = "Background effect paused to keep video responsive"
            } else {
                segmenter.qualityLevel = settings.segmentation.visionQuality
                segmenter.outputPixelFormat = kCVPixelFormatType_OneComponent8
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
                if (try? handler.perform([segmenter])) != nil, let maskBuffer = segmenter.results?.first?.pixelBuffer {
                    let mask = CIImage(cvPixelBuffer: maskBuffer)
                    let scaledMask = mask.transformed(by: CGAffineTransform(scaleX: input.extent.width / mask.extent.width,
                                                                            y: input.extent.height / mask.extent.height))
                    let backdrop: CIImage
                    if settings.background == .replacement, let background {
                        let scale = max(input.extent.width / background.extent.width, input.extent.height / background.extent.height)
                        let resized = background.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        backdrop = resized.transformed(by: CGAffineTransform(translationX: input.extent.midX - resized.extent.midX,
                                                                              y: input.extent.midY - resized.extent.midY))
                    } else {
                        backdrop = input.clampedToExtent().applyingGaussianBlur(sigma: settings.blurRadius)
                    }
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = image
                    blend.backgroundImage = backdrop.cropped(to: input.extent)
                    blend.maskImage = scaledMask
                    image = blend.outputImage?.cropped(to: input.extent) ?? image
                } else { status = "Person mask unavailable · Original background" }
            }
        }
        if settings.exposureEnabled {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = Float(min(max(settings.exposure, -1), 1))
            image = exposure.outputImage ?? image
        }
        if settings.colorEnabled {
            let color = CIFilter.colorControls()
            color.inputImage = image
            color.saturation = Float(min(max(settings.saturation, 0), 1.5))
            image = color.outputImage ?? image
        }
        if settings.lighting {
            let light = CIFilter.highlightShadowAdjust()
            light.inputImage = image
            light.shadowAmount = 0.22
            light.highlightAmount = 0.9
            image = light.outputImage ?? image
        }
        if settings.denoise && !reducedWork {
            let noise = CIFilter.noiseReduction()
            noise.inputImage = image
            noise.noiseLevel = 0.015
            noise.sharpness = 0.3
            image = noise.outputImage ?? image
        }
        return (image.cropped(to: input.extent), status)
    }
}

/// User preferences only. Camera activation, publishing, and image pixels are never persisted here.
struct CameraStudioSettings: Codable, Equatable {
    var deviceID: String?
    var format: CameraFormatChoice?
    var framing = FramingSettings()
    var effects = VideoEffects()
    var posture = PostureSettings()
    var calibration: DeskCalibration?
}
