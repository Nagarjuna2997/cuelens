import XCTest
@testable import cuelens

final class AudioIssueStateTests: XCTestCase {
    func testIncompleteTranscriptionMarkerPersistsAndOlderSessionsStillDecode() throws {
        var session = MeetingSession(title: "Fixture", assistantID: UUID(), assistantName: "Fixture")
        session.transcriptionIncompleteSources = [.meeting]
        let encoded = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(MeetingSession.self, from: encoded)
        XCTAssertEqual(restored.transcriptionIncompleteSources, [.meeting])
        XCTAssertTrue(restored.transcriptionNotice?.contains(AudioSource.meeting.rawValue) == true)
        XCTAssertTrue(SessionExport.transcript(restored).contains("may be incomplete"))

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "transcriptionIncompleteSources")
        let legacySession = try JSONDecoder().decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacySession.transcriptionIncompleteSources)
        XCTAssertNil(legacySession.transcriptionNotice)
    }

    func testSpeechRecoveryClearsOnlyThatSourceSpeechError() {
        var issues = AudioIssueState()
        issues.speechFailed(.microphone, message: "Microphone transcription stopped.")
        issues.speechFailed(.meeting, message: "Meeting transcription stopped.")
        issues.speechRecovered(.microphone)
        XCTAssertNil(issues.messages[.microphone])
        XCTAssertEqual(issues.messages[.meeting], "Meeting transcription stopped.")
    }

    func testSpeechRecoveryPreservesConcurrentRecordingFailure() {
        var issues = AudioIssueState()
        issues.captureFailed(.meeting, message: "Audio recording could not be saved.")
        issues.speechFailed(.meeting, message: "Speech service is unavailable.")
        XCTAssertTrue(issues.messages[.meeting]?.contains("Audio recording could not be saved.") == true)
        XCTAssertTrue(issues.messages[.meeting]?.contains("Speech service is unavailable.") == true)
        issues.speechRecovered(.meeting)
        XCTAssertEqual(issues.messages[.meeting], "Audio recording could not be saved.")
        issues.clear(.meeting)
        XCTAssertNil(issues.messages[.meeting])
    }
}
