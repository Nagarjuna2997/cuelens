import CoreImage
import CoreVideo
import XCTest
@testable import cuelens

final class NativeGazeTests: XCTestCase {
    private let frame = CGSize(width: 320, height: 240)
    private let contour = [CGPoint(x: 80, y: 100), CGPoint(x: 89, y: 94), CGPoint(x: 101, y: 94),
                           CGPoint(x: 110, y: 100), CGPoint(x: 101, y: 106), CGPoint(x: 89, y: 106)]

    func testCanonicalEyeOrderingDoesNotDependOnVisionIndices() throws {
        let shuffled = [contour[4], contour[2], contour[0], contour[5], contour[3], contour[1]]
        let rightNetworkEye = try XCTUnwrap(NativeGazeMath.eye(points: shuffled, imageLeft: true, frameSize: frame))
        XCTAssertEqual(rightNetworkEye.points, contour)
        let leftNetworkEye = try XCTUnwrap(NativeGazeMath.eye(points: shuffled, imageLeft: false, frameSize: frame))
        XCTAssertEqual(leftNetworkEye.points, [contour[3], contour[2], contour[1], contour[0], contour[5], contour[4]])
        XCTAssertEqual(rightNetworkEye.crop, leftNetworkEye.crop)
        XCTAssertEqual(rightNetworkEye.openness, 0.4, accuracy: 0.001)
    }

    func testClosedAmbiguousAndEdgeEyesFailClosed() {
        let closed = contour.map { CGPoint(x: $0.x, y: 100 + ($0.y - 100) * 0.1) }
        XCTAssertNil(NativeGazeMath.eye(points: closed, imageLeft: true, frameSize: frame))
        XCTAssertNil(NativeGazeMath.eye(points: contour + [CGPoint(x: 95, y: 94), CGPoint(x: 95, y: 106)], imageLeft: true, frameSize: frame))
        XCTAssertNil(NativeGazeMath.eye(points: contour.map { CGPoint(x: $0.x - 80, y: $0.y) }, imageLeft: true, frameSize: frame))
        var invalid = contour; invalid[1].x = .nan
        XCTAssertNil(NativeGazeMath.eye(points: invalid, imageLeft: true, frameSize: frame))
    }

    func testAnchorMapsUseRawPixelOffsetsAndXYChannelOrder() {
        let eye = NativeGazeEye(points: [CGPoint(x: 20, y: 40), CGPoint(x: 30, y: 30), CGPoint(x: 50, y: 30),
                                        CGPoint(x: 60, y: 40), CGPoint(x: 50, y: 50), CGPoint(x: 30, y: 50)],
                                center: CGPoint(x: 40, y: 40), crop: CGRect(x: 10, y: 20, width: 64, height: 48), openness: 0.5)
        let map = NativeGazeMath.anchors(for: eye)
        XCTAssertEqual(map.count, 48 * 64 * 12)
        XCTAssertEqual(Array(map.prefix(4)), [-10, -20, -20, -10])
        let offset = (30 * 64 + 40) * 12
        XCTAssertEqual(map[offset], 30)
        XCTAssertEqual(map[offset + 1], 10)
    }

    func testAnglesScaleWithResolutionAndStrength() throws {
        let a = CGPoint(x: 200, y: 180), b = CGPoint(x: 280, y: 180)
        let standard = try XCTUnwrap(NativeGazeMath.angles(first: a, second: b, size: CGSize(width: 640, height: 480), calibration: .init(), strength: 1))
        let doubled = try XCTUnwrap(NativeGazeMath.angles(first: CGPoint(x: 400, y: 360), second: CGPoint(x: 560, y: 360), size: CGSize(width: 1280, height: 960), calibration: .init(), strength: 0.5))
        XCTAssertEqual(doubled[0], standard[0] / 2, accuracy: 0.0001)
        XCTAssertEqual(doubled[1], standard[1] / 2, accuracy: 0.0001)
        XCTAssertGreaterThan(standard[0], 0)
        XCTAssertNil(NativeGazeMath.angles(first: a, second: a, size: frame, calibration: .init(), strength: 1))
        XCTAssertNil(NativeGazeMath.angles(first: a, second: b, size: frame, calibration: .init(), strength: .nan))
    }

    func testLearnedFlowSamplerMatchesFLXBoundaryConvention() throws {
        let image = [Float](repeating: 0.25, count: 48 * 64 * 3)
        let flow = [Float](repeating: 0, count: 48 * 64 * 2)
        let lighting = (0..<(48 * 64)).flatMap { _ in [Float(1), Float(0)] }
        let corrected = try XCTUnwrap(NativeGazeMath.warp(image: image, flow: flow, light: lighting))
        XCTAssertEqual(corrected[(20 * 64 + 20) * 3], 0.25, accuracy: 0.00001)
        // The original graph's W/H scaling and clipped-corner weights produce zero
        // at the last column/row; substituting a clamp-to-edge sampler is incorrect.
        XCTAssertEqual(corrected[63 * 3], 0, accuracy: 0.00001)
        XCTAssertEqual(corrected[(47 * 64 + 20) * 3], 0, accuracy: 0.00001)
        let whitePalette = (0..<(48 * 64)).flatMap { _ in [Float(0), Float(1)] }
        XCTAssertTrue(try XCTUnwrap(NativeGazeMath.warp(image: image, flow: flow, light: whitePalette)).allSatisfy { $0 == 1 })
    }

    func testNonfiniteModelOutputsAreRejected() {
        let image = [Float](repeating: 0.25, count: 48 * 64 * 3)
        var flow = [Float](repeating: 0, count: 48 * 64 * 2); flow[10] = .nan
        let lighting = (0..<(48 * 64)).flatMap { _ in [Float(1), Float(0)] }
        XCTAssertNil(NativeGazeMath.warp(image: image, flow: flow, light: lighting))
    }

    func testMissingModelsAndDisabledStrengthPreserveOriginalImage() throws {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &value), kCVReturnSuccess)
        let buffer = try XCTUnwrap(value)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let isolatedMissingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let processor = NativeGazeProcessor(modelsDirectory: isolatedMissingDirectory)
        let context = CIContext()
        let disabled = processor.process(buffer: buffer, image: image, context: context, strength: 0)
        XCTAssertTrue(disabled.image === image); XCTAssertFalse(disabled.applied)
        let missing = processor.process(buffer: buffer, image: image, context: context, strength: 1)
        XCTAssertTrue(missing.image === image); XCTAssertFalse(missing.applied)
        XCTAssertTrue(missing.status.contains("models not installed"))
        let repeated = processor.process(buffer: buffer, image: image, context: context, strength: 1)
        XCTAssertEqual(repeated.status, missing.status)
        let nonfinite = processor.process(buffer: buffer, image: image, context: context, strength: .infinity)
        XCTAssertTrue(nonfinite.image === image); XCTAssertFalse(nonfinite.applied)
    }
}
