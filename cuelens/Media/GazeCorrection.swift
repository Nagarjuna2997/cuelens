import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// A small local pupil-centering warp. Frames with uncertain landmarks use the original feed.
final class GazeCorrection {
    struct Eye {
        let center: CGPoint
        let pupil: CGPoint
        let radius: CGSize
    }

    private let request = VNDetectFaceLandmarksRequest()
    func eyes(in buffer: CVPixelBuffer) -> [Eye] {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let results = request.results, results.count == 1, let face = results.first,
              face.confidence > 0.8,
              abs(face.yaw?.doubleValue ?? 0) < 0.35,
              abs(face.roll?.doubleValue ?? 0) < 0.30,
              abs(face.pitch?.doubleValue ?? 0) < 0.30,
              let landmarks = face.landmarks else { return [] }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let left = Self.eye(outline: landmarks.leftEye, pupil: landmarks.leftPupil, face: face.boundingBox, size: size)
        let right = Self.eye(outline: landmarks.rightEye, pupil: landmarks.rightPupil, face: face.boundingBox, size: size)
        guard let left, let right else { return [] }
        return [left, right]
    }

    func apply(to image: CIImage, eyes: [Eye], strength: Double) -> CIImage? {
        guard eyes.count == 2, strength.isFinite, strength > 0 else { return nil }
        let strength = min(strength, 1)
        var corrected = image
        for eye in eyes {
            guard eye.radius.width > 0, eye.radius.height > 0 else { return nil }
            let x = Self.clamp((eye.center.x - eye.pupil.x) * strength, to: min(eye.radius.width * 0.23, 4))
            let y = Self.clamp((eye.center.y - eye.pupil.y) * strength, to: min(eye.radius.height * 0.28, 2.5))
            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = 0.22
            gradient.radius1 = 1
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
            guard let mask = gradient.outputImage else { return nil }
            let ellipse = CGAffineTransform(a: eye.radius.width, b: 0, c: 0, d: eye.radius.height,
                                            tx: eye.center.x, ty: eye.center.y)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image.clampedToExtent().transformed(by: CGAffineTransform(translationX: x, y: y))
            blend.backgroundImage = corrected
            blend.maskImage = mask.transformed(by: ellipse).cropped(to: image.extent)
            guard let result = blend.outputImage else { return nil }
            corrected = result.cropped(to: image.extent)
        }
        return corrected
    }

    private static func eye(outline: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?,
                            face: CGRect, size: CGSize) -> Eye? {
        guard let outline, outline.pointCount >= 4, let pupil, let position = pupil.normalizedPoints.first else { return nil }
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (face.minX + point.x * face.width) * size.width,
                    y: (face.minY + point.y * face.height) * size.height)
        }
        let points = outline.normalizedPoints.map(pixel)
        guard let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
              let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { return nil }
        let width = x1 - x0
        let height = y1 - y0
        guard width > 10, height > 4, height / width > 0.17 else { return nil }
        let center = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
        let pupilPoint = pixel(position)
        guard abs(pupilPoint.x - center.x) < width * 0.44, abs(pupilPoint.y - center.y) < height * 0.55 else { return nil }
        return Eye(center: center, pupil: pupilPoint, radius: CGSize(width: width * 0.56, height: height * 0.67))
    }

    private static func clamp(_ value: Double, to limit: Double) -> Double {
        max(-limit, min(limit, value))
    }
}
