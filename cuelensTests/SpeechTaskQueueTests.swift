import XCTest
@testable import cuelens

final class SpeechTaskQueueTests: XCTestCase {
    func testNoSpeechIsDistinguishedFromServiceFailure() {
        XCTAssertTrue(AppleSpeechFailure.isNoMatch(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        for code in [1100, 1101, 1107, 1700] {
            XCTAssertFalse(AppleSpeechFailure.isNoMatch(NSError(domain: "kAFAssistantErrorDomain", code: code)))
        }
        XCTAssertFalse(AppleSpeechFailure.isNoMatch(NSError(domain: "kLSRErrorDomain", code: 1110)))
        XCTAssertFalse(AppleSpeechFailure.isNoMatch(NSError(domain: "kLSRErrorDomain", code: 301)))
    }

    func testSourcesCannotStartRecognitionUntilPriorTurnFinishes() async throws {
        let scheduler = SpeechTaskQueue()
        let callbackQueue = DispatchQueue(label: "speech-test")
        let firstID = UUID()
        let secondID = UUID()
        let first = expectation(description: "First source starts")
        let second = expectation(description: "Second source starts")
        let priorFinished = DispatchSemaphore(value: 0)
        scheduler.enqueue(id: firstID, on: callbackQueue) { first.fulfill() }
        scheduler.enqueue(id: secondID, on: callbackQueue) {
            XCTAssertEqual(priorFinished.wait(timeout: .now()), .success)
            second.fulfill()
        }
        await fulfillment(of: [first], timeout: 1)
        try await Task.sleep(for: .milliseconds(100))
        priorFinished.signal()
        scheduler.finish(firstID)
        await fulfillment(of: [second], timeout: 1)
        scheduler.finish(secondID)
    }

    func testCancellingWaitingTurnDoesNotCancelActiveSource() async {
        let scheduler = SpeechTaskQueue()
        let callbackQueue = DispatchQueue(label: "speech-test-cancel")
        let firstID = UUID()
        let cancelledID = UUID()
        let lastID = UUID()
        let first = expectation(description: "First source starts")
        let cancelled = expectation(description: "Cancelled source must not start")
        cancelled.isInverted = true
        let last = expectation(description: "Next source starts after release")
        scheduler.enqueue(id: firstID, on: callbackQueue) { first.fulfill() }
        scheduler.enqueue(id: cancelledID, on: callbackQueue) { cancelled.fulfill() }
        scheduler.enqueue(id: lastID, on: callbackQueue) { last.fulfill() }
        scheduler.finish(cancelledID)
        await fulfillment(of: [first], timeout: 1)
        scheduler.finish(firstID)
        await fulfillment(of: [last], timeout: 1)
        await fulfillment(of: [cancelled], timeout: 0.1)
        scheduler.finish(lastID)
    }
}
