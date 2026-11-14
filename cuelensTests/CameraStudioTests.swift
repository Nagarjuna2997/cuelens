import CoreImage
import CoreVideo
import XCTest
@testable import cuelens

final class CameraStudioTests: XCTestCase {
    @MainActor
    func testNativeGazePreferenceRestoresWithoutStartingCaptureAndMigratesLegacySettings() throws {
        var saved = CameraStudioSettings()
        saved.gaze = NativeGazeSettings(enabled: true, strength: 0.4)
        let encoded = try JSONEncoder().encode(saved)
        let restored = CameraPreview()
        restored.applySettings(try JSONDecoder().decode(CameraStudioSettings.self, from: encoded))
        XCTAssertTrue(restored.gaze.enabled)
        XCTAssertEqual(restored.gaze.strength, 0.4)
        XCTAssertFalse(restored.active)
        XCTAssertFalse(restored.starting)
        XCTAssertFalse(restored.publishing)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "gaze")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        restored.applySettings(try JSONDecoder().decode(CameraStudioSettings.self, from: legacyData))
        XCTAssertFalse(restored.gaze.enabled)
    }

    private func person(x: Double = 0.5, y: Double = 0.65) -> CameraTrackingSample {
        .init(face: CGRect(x: x - 0.1, y: y - 0.12, width: 0.2, height: 0.24), confidence: 0.95,
              leftShoulder: CGPoint(x: x - 0.18, y: 0.35), rightShoulder: CGPoint(x: x + 0.18, y: 0.35))
    }

    func testFramingBoundsSmoothingAndLock() {
        var framing = CameraFraming()
        var settings = FramingSettings()
        settings.zoom = 2
        let first = framing.update(person(), settings: settings, now: 1)
        XCTAssertEqual(first.width, 0.5, accuracy: 0.001)
        let moved = framing.update(person(x: 0.8), settings: settings, now: 1.03)
        XCTAssertGreaterThan(moved.midX, first.midX)
        XCTAssertLessThan(moved.midX, 0.75)
        settings.locked = true
        XCTAssertEqual(framing.update(person(x: 0.1), settings: settings, now: 2), moved)
        settings.locked = false
        for time in stride(from: 2.1, through: 7.0, by: 0.1) {
            _ = framing.update(person(x: 0.98), settings: settings, now: time)
        }
        XCTAssertGreaterThanOrEqual(framing.crop.minX, 0)
        XCTAssertLessThanOrEqual(framing.crop.maxX, 1)
        XCTAssertLessThanOrEqual(framing.crop.maxY, 1)
    }

    func testFramingHoldsBriefLossThenWidensAndBypasses() {
        var framing = CameraFraming()
        var settings = FramingSettings()
        settings.zoom = 1.5
        let initial = framing.update(person(), settings: settings, now: 1)
        XCTAssertEqual(framing.update(.unavailable, settings: settings, now: 1.2), initial)
        let widened = framing.update(.unavailable, settings: settings, now: 3)
        XCTAssertGreaterThan(widened.width, initial.width)
        settings.enabled = false
        XCTAssertEqual(framing.update(person(), settings: settings, now: 4), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testPostureRequiresSustainedDeviationAndRespectsCooldownAndVisibility() {
        var coach = PostureCoach()
        var settings = PostureSettings()
        let offCenter = person(x: 0.85)
        XCTAssertNil(coach.update(offCenter, calibration: nil, settings: settings, now: 0))
        XCTAssertNil(coach.update(offCenter, calibration: nil, settings: settings, now: 2.9))
        XCTAssertEqual(coach.update(offCenter, calibration: nil, settings: settings, now: 3.1), .center)
        XCTAssertNil(coach.update(offCenter, calibration: nil, settings: settings, now: 10))
        XCTAssertNil(coach.update(.unavailable, calibration: nil, settings: settings, now: 21))
        XCTAssertNil(coach.update(offCenter, calibration: nil, settings: settings, now: 22))
        XCTAssertEqual(coach.update(offCenter, calibration: nil, settings: settings, now: 25.1), .center)
        settings.enabled = false
        XCTAssertNil(coach.update(offCenter, calibration: nil, settings: settings, now: 26))
    }

    func testShoulderCueNeedsVisibleCalibratedShoulders() throws {
        var coach = PostureCoach()
        let baseline = try XCTUnwrap(DeskCalibration(sample: person()))
        let raised = CameraTrackingSample(face: person().face, confidence: 0.95,
                                          leftShoulder: CGPoint(x: 0.32, y: 0.49), rightShoulder: CGPoint(x: 0.68, y: 0.49))
        _ = coach.update(raised, calibration: baseline, settings: .init(), now: 0)
        XCTAssertEqual(coach.update(raised, calibration: baseline, settings: .init(), now: 3.1), .shoulders)
        let hidden = CameraTrackingSample(face: person().face, confidence: 0.95, leftShoulder: nil, rightShoulder: nil)
        var freshCoach = PostureCoach()
        _ = freshCoach.update(hidden, calibration: baseline, settings: .init(), now: 0)
        XCTAssertNil(freshCoach.update(hidden, calibration: baseline, settings: .init(), now: 4))
    }

    func testGlobalBypassKeepsOriginalPixelsWithEffectsSelected() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        var settings = VideoEffects()
        settings.bypass = true
        settings.exposureEnabled = true
        settings.background = .blur
        let result = CameraEffects().apply(image, buffer: pixelBuffer, settings: settings, background: nil, reducedWork: false)
        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.status, "All effects bypassed")
    }
    func testFramingExpandsToKeepLargeFaceInsideCrop() {
        let sample = CameraTrackingSample(face: CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.55),
                                          confidence: 0.95, leftShoulder: nil, rightShoulder: nil)
        var settings = FramingSettings()
        settings.zoom = 2.5
        settings.headroom = 0.3
        for position in FramingPosition.allCases {
            settings.position = position
            var framing = CameraFraming()
            let crop = framing.update(sample, settings: settings, now: 1)
            XCTAssertTrue(crop.contains(sample.face!), "A large face must remain inside the \(position) framing crop")
            XCTAssertGreaterThan(crop.width, 0.4)
        }
    }

    func testDeskCalibrationUsesStableSamplesAndRejectsMovingPerson() throws {
        var samples = (0..<12).map { index in person(x: 0.5 + (index.isMultiple(of: 2) ? 0.01 : -0.01)) }
        let calibration = try XCTUnwrap(DeskCalibration(samples: samples))
        XCTAssertEqual(calibration.face.midX, 0.5, accuracy: 0.001)
        XCTAssertNotNil(calibration.shoulderMidpoint)
        samples[11] = person(x: 0.8)
        XCTAssertNil(DeskCalibration(samples: samples))
        XCTAssertNil(DeskCalibration(samples: Array(samples.prefix(5))))
    }

    @MainActor
    func testCameraPreferencesRestoreWithoutActivatingCapture() throws {
        var settings = CameraStudioSettings()
        settings.deviceID = "fixture-device"
        settings.framing.position = .rightThird
        settings.framing.zoom = 1.7
        settings.framing.locked = true
        settings.effects.exposureEnabled = true
        settings.effects.background = .replacement
        let decoded = try JSONDecoder().decode(CameraStudioSettings.self, from: JSONEncoder().encode(settings))
        let preview = CameraPreview()
        preview.applySettings(decoded)
        XCTAssertFalse(preview.active)
        XCTAssertFalse(preview.starting)
        XCTAssertFalse(preview.publishing)
        XCTAssertFalse(preview.framing.locked)
        XCTAssertEqual(preview.deviceID, "fixture-device")
        XCTAssertEqual(preview.framing.position, .rightThird)
        XCTAssertEqual(preview.effects.background, .original)
        XCTAssertTrue(preview.effects.exposureEnabled)
    }

    func testMovingFartherFromCameraDoesNotBecomeRaisedShoulders() throws {
        let baseline = try XCTUnwrap(DeskCalibration(sample: person()))
        let farther = CameraTrackingSample(face: CGRect(x: 0.43, y: 0.566, width: 0.14, height: 0.168),
                                           confidence: 0.95, leftShoulder: CGPoint(x: 0.374, y: 0.44),
                                           rightShoulder: CGPoint(x: 0.626, y: 0.44))
        var coach = PostureCoach()
        _ = coach.update(farther, calibration: baseline, settings: .init(), now: 0)
        XCTAssertNil(coach.update(farther, calibration: baseline, settings: .init(), now: 4))
    }

    func testBusyPreviewKeepsOnlyNewestFrameAndPreservesFailure() async throws {
        let image = try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
            CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
            from: CGRect(x: 0, y: 0, width: 2, height: 2)))
        let feed = CameraFrameFeed()
        for sequence in 0..<200 {
            feed.receive(.success(CameraFrame(capturedAt: Double(sequence), original: image, processed: image,
                                               tracking: .unavailable, crop: .zero, status: "", postureCue: nil,
                                               fps: 30, processingMilliseconds: 1, droppedFrames: 0)))
        }
        feed.receive(.failure(.unavailable))
        var consumer = feed.stream.makeAsyncIterator()
        let newest = try await consumer.next()
        XCTAssertEqual(newest?.capturedAt, 199)
        do {
            _ = try await consumer.next()
            XCTFail("A capture failure must survive frame coalescing")
        } catch {
            XCTAssertEqual(error.localizedDescription, CameraFailure.unavailable.localizedDescription)
        }
    }

}
