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
}
