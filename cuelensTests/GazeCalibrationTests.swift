import CoreGraphics
import XCTest
@testable import cuelens

final class GazeCalibrationTests: XCTestCase {
    func testCalibrationAcceptsReadingPositionAndReleasesLargeGlances() {
        let lens = EyeAim(left: .zero, right: .zero)
        let reading = EyeAim(left: CGPoint(x: 0.05, y: -0.35), right: CGPoint(x: 0.05, y: -0.35))
        let away = EyeAim(left: CGPoint(x: 0.7, y: 0), right: CGPoint(x: 0.7, y: 0))
        let calibration = GazeCalibration(lens: lens, reading: reading)
        XCTAssertEqual(calibration.weight(for: lens), 1, accuracy: 0.001)
        XCTAssertEqual(calibration.weight(for: reading), 1, accuracy: 0.001)
        XCTAssertEqual(calibration.weight(for: away), 0, accuracy: 0.001)
    }

    func testSamplerRequiresMultipleFramesAndAveragesEyeAim() throws {
        var sample = GazeSampler()
        let lens = EyeAim(left: CGPoint(x: 0.1, y: 0.2), right: CGPoint(x: -0.1, y: 0.2))
        for _ in 0..<4 { sample.add(lens) }
        XCTAssertNil(sample.result)
        sample.add(.init(left: .zero, right: .zero))
        let average = try XCTUnwrap(sample.result)
        XCTAssertEqual(average.left.x, 0.08, accuracy: 0.001)
        XCTAssertEqual(average.right.y, 0.16, accuracy: 0.001)
    }
}
