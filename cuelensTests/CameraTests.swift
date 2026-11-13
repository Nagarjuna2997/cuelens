import CoreImage
import XCTest
@testable import cuelens

final class CameraTests: XCTestCase {
    func testCorrectionUsesOriginalFeedWithoutTwoEyesOrWithZeroStrength() {
        let gaze = GazeCorrection()
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let eye = GazeCorrection.Eye(center: CGPoint(x: 18, y: 17), pupil: CGPoint(x: 16, y: 17),
                                     radius: CGSize(width: 8, height: 5))
        XCTAssertNil(gaze.apply(to: image, eyes: [eye], strength: 0.8))
        XCTAssertNil(gaze.apply(to: image, eyes: [eye, eye], strength: 0))
    }

    func testCorrectionMovesPixelsOnlyNearEyes() throws {
        let gaze = GazeCorrection()
        let extent = CGRect(x: 0, y: 0, width: 64, height: 32)
        let pupil = CIImage(color: .black).cropped(to: CGRect(x: 14, y: 13, width: 3, height: 5))
        let original = pupil.composited(over: CIImage(color: .white)).cropped(to: extent)
        let eyes = [
            GazeCorrection.Eye(center: CGPoint(x: 17, y: 15), pupil: CGPoint(x: 15, y: 15),
                               radius: CGSize(width: 10, height: 6)),
            GazeCorrection.Eye(center: CGPoint(x: 46, y: 15), pupil: CGPoint(x: 46, y: 15),
                               radius: CGSize(width: 10, height: 6))
        ]
        let corrected = try XCTUnwrap(gaze.apply(to: original, eyes: eyes, strength: 1))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        XCTAssertEqual(corrected.extent, extent)
        XCTAssertEqual(pixel(context, original, x: 2, y: 3), pixel(context, corrected, x: 2, y: 3))
        XCTAssertGreaterThan(pixel(context, original, x: 17, y: 15), pixel(context, corrected, x: 17, y: 15))
    }

    private func pixel(_ context: CIContext, _ image: CIImage, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return bytes[0]
    }
}
