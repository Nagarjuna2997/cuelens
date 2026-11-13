import Foundation
import XCTest
@testable import cuelens

final class ResourcesTests: XCTestCase {
    func testResourcePressureSelectsFallbackForThermalOrMemoryWarnings() {
        XCTAssertEqual(ResourceCondition.evaluate(thermal: .nominal, memory: .normal), .normal)
        XCTAssertTrue(ResourceCondition.evaluate(thermal: .serious, memory: .normal).reducesWork)
        XCTAssertEqual(ResourceCondition.evaluate(thermal: .nominal, memory: .warning), .constrained)
        XCTAssertEqual(ResourceCondition.evaluate(thermal: .fair, memory: [.warning, .critical]), .critical)
    }

    func testStoppedAudioPipelineCannotBeRestarted() async {
        let pipeline = AudioPipeline(source: .manual) { _ in }
        await pipeline.stop()
        do {
            try await pipeline.start(microphoneID: nil, speechProvider: nil, locale: "", apiKey: nil, recordingURL: nil)
            XCTFail("A retired pipeline should reject delayed startup.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
