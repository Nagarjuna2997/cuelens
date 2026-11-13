import AppKit
import Carbon.HIToolbox
import XCTest
@testable import cuelens

final class ShortcutSettingsTests: XCTestCase {
    @MainActor
    func testSessionShortcutsAcceptCapsLockButRespectOtherChords() {
        XCTAssertEqual(Hotkeys.sessionCommand(keyCode: UInt16(kVK_ANSI_C), modifiers: .command), .answer)
        XCTAssertEqual(Hotkeys.sessionCommand(keyCode: UInt16(kVK_ANSI_X), modifiers: [.command, .capsLock]), .capture)
        XCTAssertNil(Hotkeys.sessionCommand(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift]))
        XCTAssertNil(Hotkeys.sessionCommand(keyCode: UInt16(kVK_ANSI_X), modifiers: [.command, .option]))
        XCTAssertNil(Hotkeys.sessionCommand(keyCode: UInt16(kVK_ANSI_C), modifiers: .control))
        XCTAssertNil(Hotkeys.sessionCommand(keyCode: UInt16(kVK_ANSI_V), modifiers: .command))
    }

    @MainActor
    func testCameraSettingsFlushBeforeDebounceAndResourcePreferenceRestores() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(directory: directory)
        var workspace = Workspace()
        workspace.preferences.resourcePreset = .performance
        try vault.save(workspace)
        let model = AppModel(vault: vault, credentials: TestCredentials())
        XCTAssertEqual(model.camera.preset, .performance)
        model.camera.framing.zoom = 1.7
        model.camera.framing.position = .leftThird
        model.flushCameraSettings()
        let saved = try XCTUnwrap(vault.load().camera)
        XCTAssertEqual(saved.framing.zoom, 1.7)
        XCTAssertEqual(saved.framing.position, .leftThird)
        var preferences = model.preferences
        preferences.resourcePreset = .balanced
        XCTAssertTrue(model.savePreferences(preferences))
        XCTAssertEqual(model.camera.preset, .balanced)
        let restored = AppModel(vault: vault, credentials: TestCredentials())
        XCTAssertEqual(restored.camera.framing.zoom, 1.7)
        XCTAssertFalse(restored.camera.active)
        XCTAssertFalse(restored.camera.publishing)
    }

    @MainActor
    func testQuickStartUsesSavedSourcesWithoutEnablingRecordingOrCloudSpeech() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(vault: Vault(directory: directory), credentials: TestCredentials())
        var preferences = model.preferences
        preferences.sessionMicrophone = false
        preferences.sessionMeetingAudio = true
        preferences.sessionScreenContext = true
        preferences.speechProvider = .openAI
        XCTAssertTrue(model.savePreferences(preferences))
        var assistant = AssistantProfile(name: "Role")
        assistant.retainSession = false
        let options = model.quickSessionOptions(for: assistant)
        XCTAssertFalse(options.microphone)
        XCTAssertTrue(options.meetingAudio)
        XCTAssertTrue(options.screenContext)
        XCTAssertFalse(options.save)
        XCTAssertFalse(options.saveAudio)
        XCTAssertFalse(options.allowCloud)
        XCTAssertFalse(options.automaticAnswers)
        preferences.sessionScreenContext = nil
        XCTAssertTrue(model.savePreferences(preferences))
        XCTAssertFalse(model.quickSessionOptions(for: assistant).screenContext)
    }
}
