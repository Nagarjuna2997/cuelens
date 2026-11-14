import XCTest
@testable import cuelens

final class SessionCameraStartTests: XCTestCase {
    @MainActor
    func testDefaultSessionDoesNotStartCamera() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(vault: Vault(directory: directory), credentials: TestCredentials())
        model.live.onEnded = nil
        let assistant = AssistantProfile(name: "Fixture")
        XCTAssertNil(model.preferences.startCameraWithSession)
        XCTAssertFalse(model.quickSessionOptions(for: assistant).previewCamera)
        model.live.start(assistant: assistant, settings: model.preferences,
                         options: .init(microphone: false, save: false))
        model.startCameraForSessionIfEnabled()
        XCTAssertFalse(model.camera.starting)
        XCTAssertFalse(model.camera.active)
        model.live.end()
        for _ in 0..<100 where model.live.isOpen {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.live.isOpen)
    }

    @MainActor
    func testCameraOptInAndExplicitSourcePersistWithoutStartingOnAppLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(directory: directory)
        let model = AppModel(vault: vault, credentials: TestCredentials())
        let selectedID = "fixture-external-camera-\(UUID().uuidString)"
        model.camera.selectDevice(selectedID)
        model.flushCameraSettings()
        var preferences = model.preferences
        preferences.startCameraWithSession = true
        XCTAssertTrue(model.savePreferences(preferences))

        let restored = AppModel(vault: vault, credentials: TestCredentials())
        XCTAssertEqual(restored.preferences.startCameraWithSession, true)
        XCTAssertEqual(restored.camera.deviceID, selectedID)
        XCTAssertFalse(restored.camera.active)
        XCTAssertFalse(restored.camera.starting)
        let conversation = AssistantProfile(name: "Conversation")
        XCTAssertTrue(restored.quickSessionOptions(for: conversation).previewCamera)
        var practice = AssistantProfile(name: "Practice")
        practice.kind = .mockInterview
        XCTAssertTrue(restored.quickSessionOptions(for: practice).previewCamera)
        restored.startCameraForSessionIfEnabled()
        XCTAssertFalse(restored.camera.starting, "The stored opt-in applies only to starting a session.")
        XCTAssertEqual(restored.camera.deviceID, selectedID)
    }

    func testMissingExplicitCameraDoesNotResolveToSystemDefault() {
        XCTAssertNil(CameraDevice.resolve("fixture-missing-camera-\(UUID().uuidString)"))
    }
}
