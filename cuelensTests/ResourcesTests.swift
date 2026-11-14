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

    @MainActor
    func testCameraRecoversAfterCooldownWithoutClearingActiveMemoryPressure() {
        let camera = CameraPreview()
        camera.preset = .balanced
        camera.lowResources = ResourceCondition.evaluate(thermal: .serious, memory: .normal).reducesWork
        XCTAssertEqual(camera.effectiveProcessingPreset, .low)

        camera.lowResources = ResourceCondition.evaluate(thermal: .fair, memory: .warning).reducesWork
        XCTAssertEqual(camera.effectiveProcessingPreset, .low)

        camera.lowResources = ResourceCondition.evaluate(thermal: .fair, memory: .normal).reducesWork
        XCTAssertEqual(camera.effectiveProcessingPreset, .balanced)
        XCTAssertEqual(camera.preset, .balanced, "Temporary throttling must preserve the user's preset.")

        camera.preset = .low
        camera.lowResources = true
        camera.lowResources = false
        XCTAssertEqual(camera.effectiveProcessingPreset, .low, "Recovery must respect a selected low preset.")
        XCTAssertFalse(camera.active)
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
