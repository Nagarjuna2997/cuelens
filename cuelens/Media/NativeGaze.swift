import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

/// Local-only experimental FLX integration. Weights are never bundled with CueLens.
/// The crop, landmark channels, angle calculation and sampler follow the BSD-licensed
/// gaze_correction / gaze-correction-cam implementation. See THIRD_PARTY_NOTICES.md.
struct NativeGazeCalibration: Codable, Equatable {
    var focalLengthAt640: Double = 650
    var interpupillaryDistanceCM: Double = 6.3
    var offsetXCM: Double = 0
    // An explicit, conservative laptop assumption, not a measured screen calibration.
    var offsetYCM: Double = -10
    var offsetZCM: Double = 0
}

struct NativeGazeEye {
    /// Outer corner, upper outer, upper inner, inner corner, lower inner, lower outer.
    let points: [CGPoint]
    let center: CGPoint
    /// Integer, top-left-origin pixel coordinates in the unmirrored input buffer.
    let crop: CGRect
    let openness: Double
}

enum NativeGazeMath {
    static let width = 64
    static let height = 48

    /// Vision revision 3 / 76-point constellation supplies six points per eye.
    /// Validate their geometry instead of depending on undocumented point indices.
    /// This is semantic correspondence to FLX's six landmarks, not dlib equality.
    static func eye(points: [CGPoint], imageLeft: Bool, frameSize: CGSize) -> NativeGazeEye? {
        guard points.count == 6, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let minIndex = points.indices.min(by: { points[$0].x < points[$1].x }),
              let maxIndex = points.indices.max(by: { points[$0].x < points[$1].x }),
              minIndex != maxIndex else { return nil }
        let outerIndex = imageLeft ? minIndex : maxIndex
        let innerIndex = imageLeft ? maxIndex : minIndex
        let outer = points[outerIndex], inner = points[innerIndex]
        let dx = inner.x - outer.x, dy = inner.y - outer.y
        let length = hypot(dx, dy)
        guard abs(dx) >= 12, length.isFinite, abs(dy / dx) <= 0.2 else { return nil }
        var upper: [(Double, CGPoint)] = [], lower: [(Double, CGPoint)] = []
        for index in points.indices where index != outerIndex && index != innerIndex {
            let point = points[index]
            let t = ((point.x - outer.x) * dx + (point.y - outer.y) * dy) / (length * length)
            let down = (dx * (point.y - outer.y) - dy * (point.x - outer.x)) / length * (dx > 0 ? 1 : -1)
            guard t > 0.08, t < 0.92, abs(down) < length * 0.4 else { return nil }
            if down < -0.25 { upper.append((t, point)) }
            else if down > 0.25 { lower.append((t, point)) }
            else { return nil }
        }
        guard upper.count == 2, lower.count == 2 else { return nil }
        upper.sort { $0.0 < $1.0 }; lower.sort { $0.0 > $1.0 }
        guard upper[1].0 - upper[0].0 > 0.15, lower[0].0 - lower[1].0 > 0.15 else { return nil }
        let canonical = [outer, upper[0].1, upper[1].1, inner, lower[0].1, lower[1].1]
        let openness = (hypot(canonical[1].x - canonical[5].x, canonical[1].y - canonical[5].y)
                        + hypot(canonical[2].x - canonical[4].x, canonical[2].y - canonical[4].y)) / (2 * length)
        guard openness >= 0.17, openness <= 0.65 else { return nil }
        let center = CGPoint(x: (outer.x + inner.x) / 2, y: (outer.y + inner.y) / 2)
        let halfWidth = abs(dx) * 0.75, cropHeight = halfWidth * 1.5
        let left = Int(center.x - halfWidth), right = Int(center.x + halfWidth)
        let top = Int(center.y - cropHeight * 7 / 12), bottom = Int(center.y + cropHeight * 5 / 12)
        guard left >= 0, top >= 0, right <= Int(frameSize.width), bottom <= Int(frameSize.height),
              right - left > 12, bottom - top > 10 else { return nil }
        return .init(points: canonical, center: center,
                     crop: CGRect(x: left, y: top, width: right - left, height: bottom - top), openness: openness)
    }

    static func anchors(for eye: NativeGazeEye) -> [Float] {
        var result = [Float](repeating: 0, count: width * height * 12)
        for (index, point) in eye.points.enumerated() {
            let px = Int((point.x - eye.crop.minX) * Double(width) / eye.crop.width)
            let py = Int((point.y - eye.crop.minY) * Double(height) / eye.crop.height)
            for y in 0..<height { for x in 0..<width {
                let offset = (y * width + x) * 12 + index * 2
                // These are pixel offsets, intentionally NOT normalized to [0, 1].
                result[offset] = Float(x - px); result[offset + 1] = Float(y - py)
            } }
        }
        return result
    }

    static func angles(first: CGPoint, second: CGPoint, size: CGSize,
                       calibration c: NativeGazeCalibration, strength: Double) -> [Float]? {
        let values = [first.x, first.y, second.x, second.y, size.width, size.height,
                      c.focalLengthAt640, c.interpupillaryDistanceCM, c.offsetXCM, c.offsetYCM, c.offsetZCM, strength]
        guard values.allSatisfy(\.isFinite), size.width > 0, size.height > 0,
              c.focalLengthAt640 > 0, c.interpupillaryDistanceCM > 0 else { return nil }
        let distance = hypot(first.x - second.x, first.y - second.y)
        guard distance > 10 else { return nil }
        let focal = c.focalLengthAt640 * size.width / 640
        let z = -(focal * c.interpupillaryDistanceCM) / distance
        let x = -abs(z) * (first.x + second.x - size.width) / (2 * focal) + c.offsetXCM
        let y = abs(z) * (first.y + second.y - size.height) / (2 * focal) + c.offsetYCM
        guard abs(z) > 1, c.offsetZCM - z > 1 else { return nil }
        let vertical = (atan(-y / -z) + atan((y - c.offsetYCM) / (c.offsetZCM - z))) * 180 / .pi
        let horizontal = (atan(-x / -z) + atan((x - c.offsetXCM) / (c.offsetZCM - z))) * 180 / .pi
        guard vertical.isFinite, horizontal.isFinite, abs(vertical) <= 15, abs(horizontal) <= 15 else { return nil }
        // Keep sub-degree precision; the original Python implementation truncated angles.
        let scale = min(1, max(0, strength))
        return [Float(vertical * scale), Float(horizontal * scale)]
    }

    /// Exact FLX sampler convention: endpoints map to W/H, not W-1/H-1.
    /// Clipping happens before bilinear weights are calculated, including edge zeros.
    static func warp(image: [Float], flow: [Float], light: [Float]) -> [Float]? {
        guard image.count == width * height * 3, flow.count == width * height * 2,
              light.count == flow.count, image.allSatisfy(\.isFinite),
              flow.allSatisfy({ $0.isFinite && abs($0) <= 1.001 }),
              light.allSatisfy({ $0.isFinite && $0 >= -0.001 && $0 <= 1.001 }) else { return nil }
        var output = [Float](repeating: 0, count: image.count)
        for y in 0..<height { for x in 0..<width {
            let index = y * width + x
            let px = (Float(x) * 2 / Float(width - 1) - 1 + flow[index * 2] + 1) * Float(width) / 2
            let py = (Float(y) * 2 / Float(height - 1) - 1 + flow[index * 2 + 1] + 1) * Float(height) / 2
            let floorX = Int(floor(px)), floorY = Int(floor(py))
            let x0 = max(0, min(width - 1, floorX)), x1 = max(0, min(width - 1, floorX + 1))
            let y0 = max(0, min(height - 1, floorY)), y1 = max(0, min(height - 1, floorY + 1))
            let weights = [(Float(x1) - px) * (Float(y1) - py), (Float(x1) - px) * (py - Float(y0)),
                           (px - Float(x0)) * (Float(y1) - py), (px - Float(x0)) * (py - Float(y0))]
            let offsets = [(y0 * width + x0) * 3, (y1 * width + x0) * 3,
                           (y0 * width + x1) * 3, (y1 * width + x1) * 3]
            for channel in 0..<3 {
                var value: Float = 0
                for sample in 0..<4 { value += weights[sample] * image[offsets[sample] + channel] }
                output[index * 3 + channel] = value * light[index * 2] + light[index * 2 + 1]
            }
        } }
        return output.allSatisfy(\.isFinite) ? output : nil
    }
}

/// Call synchronously on the camera processing queue. Concurrent calls fail closed.
/// Strength scales requested angle AND patch blending; zero is a byte-for-byte bypass.
final class NativeGazeProcessor {
    static var modelsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueLens/GazeModels", isDirectory: true)
    }
    static var modelsAvailable: Bool {
        ["L", "R"].allSatisfy { FileManager.default.fileExists(atPath: modelsDirectoryURL.appendingPathComponent("FLX-\($0).mlmodelc").path) }
    }

    private struct Network {
        let model: MLModel
        let image: MLMultiArray
        let anchors: MLMultiArray
        let angles: MLMultiArray
        let input: MLDictionaryFeatureProvider

        init(url: URL) throws {
            let configuration = MLModelConfiguration()
            // This float32 CPU path is the one checked against the original checkpoints.
            configuration.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: url, configuration: configuration)
            for (name, shape) in [("inputs_input_img", [1, 48, 64, 3]), ("inputs_input_fp", [1, 48, 64, 12]), ("inputs_input_ang", [1, 2])] {
                guard model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape.map(\.intValue) == shape else { throw Failure.model }
            }
            image = try MLMultiArray(shape: [1, 48, 64, 3], dataType: .float32)
            anchors = try MLMultiArray(shape: [1, 48, 64, 12], dataType: .float32)
            angles = try MLMultiArray(shape: [1, 2], dataType: .float32)
            input = try MLDictionaryFeatureProvider(dictionary: ["inputs_input_img": MLFeatureValue(multiArray: image),
                "inputs_input_fp": MLFeatureValue(multiArray: anchors), "inputs_input_ang": MLFeatureValue(multiArray: angles)])
        }

        func predict(pixels: [Float], anchorMap: [Float], target: [Float]) throws -> [Float] {
            for (array, values) in [(image, pixels), (anchors, anchorMap), (angles, target)] {
                guard array.count == values.count else { throw Failure.model }
                values.withUnsafeBufferPointer { source in
                    array.dataPointer.copyMemory(from: source.baseAddress!, byteCount: values.count * MemoryLayout<Float>.size)
                }
            }
            let prediction = try model.prediction(from: input)
            func values(_ name: String) throws -> [Float] {
                guard let array = prediction.featureValue(for: name)?.multiArrayValue,
                      array.shape.map(\.intValue) == [1, 48, 64, 2], array.dataType == .float32 else { throw Failure.model }
                let strides = array.strides.map(\.intValue)
                guard strides.count == 4, strides.allSatisfy({ $0 > 0 }) else { throw Failure.model }
                let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
                var result = [Float](repeating: 0, count: 48 * 64 * 2)
                for y in 0..<48 { for x in 0..<64 { for channel in 0..<2 {
                    result[(y * 64 + x) * 2 + channel] = pointer[y * strides[1] + x * strides[2] + channel * strides[3]]
                } } }
                return result
            }
            guard let corrected = NativeGazeMath.warp(image: pixels, flow: try values("flow"), light: try values("light")) else { throw Failure.model }
            return corrected
        }
    }

    private enum Failure: Error { case model, pixels }
    private let lock = NSLock()
    private let directory: URL
    private let calibration: NativeGazeCalibration
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let request = VNDetectFaceLandmarksRequest()
    private var networks: [Network]?
    private var modelFailure: String?
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    init(modelsDirectory: URL = NativeGazeProcessor.modelsDirectoryURL, calibration: NativeGazeCalibration = .init()) {
        directory = modelsDirectory; self.calibration = calibration
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        request.revision = VNDetectFaceLandmarksRequestRevision3
        request.constellation = .constellation76Points
    }

    func process(buffer: CVPixelBuffer, image: CIImage, context: CIContext, strength: Double) -> (image: CIImage, status: String, applied: Bool) {
        func bypass(_ reason: String) -> (image: CIImage, status: String, applied: Bool) { (image, reason, false) }
        guard strength.isFinite, strength > 0 else { return bypass("Native eye correction off") }
        guard lock.try() else { return bypass("Native eye correction busy") }
        defer { lock.unlock() }
        if let modelFailure { return bypass(modelFailure) }
        if networks == nil {
            guard ["L", "R"].allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("FLX-\($0).mlmodelc").path) }) else {
                modelFailure = "Native eye correction · models not installed"
                return bypass(modelFailure!)
            }
            do { networks = try [Network(url: directory.appendingPathComponent("FLX-R.mlmodelc")), Network(url: directory.appendingPathComponent("FLX-L.mlmodelc"))] }
            catch { modelFailure = "Native eye correction · model could not load"; return bypass(modelFailure!) }
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              image.extent == CGRect(x: 0, y: 0, width: width, height: height) else { return bypass("Native eye correction · unsupported frame") }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        do { try handler.perform([faceRequest]) }
        catch { return bypass("Native eye correction · face uncertain") }
        guard let faces = faceRequest.results, faces.count == 1, let pose = faces.first,
              pose.confidence >= 0.85 else { return bypass("Native eye correction · one clear face needed") }
        // Landmark revision 3 alone invokes the older detector, which leaves pitch
        // nil. Seed it with current-frame rectangle revision 3's measured pose.
        guard let yaw = pose.yaw?.doubleValue, let roll = pose.roll?.doubleValue, let pitch = pose.pitch?.doubleValue,
              yaw.isFinite, roll.isFinite, pitch.isFinite, abs(yaw) <= 0.26, abs(pitch) <= 0.26, abs(roll) <= 0.16 else {
            return bypass("Native eye correction · face the camera")
        }
        request.inputFaceObservations = [pose]
        do { try handler.perform([request]) }
        catch { return bypass("Native eye correction · eye landmarks uncertain") }
        guard let observations = request.results, observations.count == 1, let face = observations.first,
              let landmarks = face.landmarks, landmarks.confidence >= 0.75,
              let left = landmarks.leftEye, let right = landmarks.rightEye else { return bypass("Native eye correction · eye landmarks uncertain") }
        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.normalizedPoints.map { p in
                CGPoint(x: (face.boundingBox.minX + p.x * face.boundingBox.width) * CGFloat(width),
                        y: (1 - face.boundingBox.minY - p.y * face.boundingBox.height) * CGFloat(height))
            }
        }
        let leftPoints = points(left), rightPoints = points(right)
        guard leftPoints.count == 6, rightPoints.count == 6 else { return bypass("Native eye correction · eye landmarks uncertain") }
        let leftX = leftPoints.reduce(CGFloat.zero) { $0 + $1.x }
        let rightX = rightPoints.reduce(CGFloat.zero) { $0 + $1.x }
        let regions = leftX < rightX ? [leftPoints, rightPoints] : [rightPoints, leftPoints]
        guard let first = NativeGazeMath.eye(points: regions[0], imageLeft: true, frameSize: CGSize(width: width, height: height)),
              let second = NativeGazeMath.eye(points: regions[1], imageLeft: false, frameSize: CGSize(width: width, height: height)),
              !first.crop.intersects(second.crop) else { return bypass("Native eye correction · eyes closed or uncertain") }
        guard let angles = NativeGazeMath.angles(first: first.center, second: second.center, size: CGSize(width: width, height: height),
                                                calibration: calibration, strength: strength),
              angles.contains(where: { abs($0) >= 0.25 }) else { return bypass("Native eye correction · outside calibrated range") }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return bypass("Native eye correction · frame unavailable") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self), let networks else { return bypass("Native eye correction · frame unavailable") }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        do {
            let eyes = [first, second]
            var corrected: [[Float]] = []
            for index in 0..<2 {
                let pixels = Self.extract(eye: eyes[index], base: base, rowBytes: rowBytes)
                corrected.append(try networks[index].predict(pixels: pixels, anchorMap: NativeGazeMath.anchors(for: eyes[index]), target: angles))
            }
            guard let output = makeOutput(width: width, height: height),
                  CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return bypass("Native eye correction · output busy") }
            defer { CVPixelBufferUnlockBaseAddress(output, []) }
            guard let destination = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else { throw Failure.pixels }
            let outputStride = CVPixelBufferGetBytesPerRow(output)
            for y in 0..<height { destination.advanced(by: y * outputStride).update(from: base.advanced(by: y * rowBytes), count: width * 4) }
            for index in 0..<2 { Self.composite(corrected[index], eye: eyes[index], base: destination, rowBytes: outputStride, strength: min(1, strength)) }
            CVBufferPropagateAttachments(buffer, output)
            return (CIImage(cvPixelBuffer: output), "Experimental · native eye correction", true)
        } catch {
            modelFailure = "Native eye correction · processing failed"
            return bypass(modelFailure!)
        }
    }

    private func makeOutput(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if poolSize != size {
            pool = nil; poolSize = size
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attributes, &output) == kCVReturnSuccess else { return nil }
        return output
    }

    private static func extract(eye: NativeGazeEye, base: UnsafePointer<UInt8>, rowBytes: Int) -> [Float] {
        let w = Int(eye.crop.width), h = Int(eye.crop.height), left = Int(eye.crop.minX), top = Int(eye.crop.minY)
        var result = [Float](repeating: 0, count: 48 * 64 * 3)
        for y in 0..<48 { for x in 0..<64 {
            let sx = (Double(x) + 0.5) * Double(w) / 64 - 0.5, sy = (Double(y) + 0.5) * Double(h) / 48 - 0.5
            let x0 = Int(floor(sx)), y0 = Int(floor(sy)), dx = Float(sx - floor(sx)), dy = Float(sy - floor(sy))
            for c in 0..<3 {
                func pixel(_ px: Int, _ py: Int) -> Float { Float(base[(top + max(0, min(h - 1, py))) * rowBytes + (left + max(0, min(w - 1, px))) * 4 + c]) }
                let value = (1 - dx) * (1 - dy) * pixel(x0, y0) + dx * (1 - dy) * pixel(x0 + 1, y0)
                    + (1 - dx) * dy * pixel(x0, y0 + 1) + dx * dy * pixel(x0 + 1, y0 + 1)
                result[(y * 64 + x) * 3 + c] = value.rounded(.toNearestOrEven) / 255
            }
        } }
        return result
    }

    private static func composite(_ pixels: [Float], eye: NativeGazeEye, base: UnsafeMutablePointer<UInt8>, rowBytes: Int, strength: Double) {
        let w = Int(eye.crop.width), h = Int(eye.crop.height), left = Int(eye.crop.minX), top = Int(eye.crop.minY)
        // The source removes 3 rows and 4 columns after resizing to the original crop.
        for y in 3..<(h - 3) { for x in 4..<(w - 4) {
            let sx = (Double(x) + 0.5) * 64 / Double(w) - 0.5, sy = (Double(y) + 0.5) * 48 / Double(h) - 0.5
            let x0 = Int(floor(sx)), y0 = Int(floor(sy)), dx = Float(sx - floor(sx)), dy = Float(sy - floor(sy))
            let feather = min(1, Float(min(x - 3, w - 4 - x, y - 2, h - 3 - y)) / 2)
            let alpha = Float(strength) * feather
            for c in 0..<3 {
                func pixel(_ px: Int, _ py: Int) -> Float { pixels[(max(0, min(47, py)) * 64 + max(0, min(63, px))) * 3 + c] }
                let value = (1 - dx) * (1 - dy) * pixel(x0, y0) + dx * (1 - dy) * pixel(x0 + 1, y0)
                    + (1 - dx) * dy * pixel(x0, y0 + 1) + dx * dy * pixel(x0 + 1, y0 + 1)
                let offset = (top + y) * rowBytes + (left + x) * 4 + c
                let blended = Float(base[offset]) * (1 - alpha) + min(255, max(0, value * 255)) * alpha
                base[offset] = UInt8(min(255, max(0, blended.rounded())))
            }
        } }
    }
}
