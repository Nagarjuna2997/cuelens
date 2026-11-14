import AppKit
import XCTest
@testable import cuelens

final class CaptureBatchTests: XCTestCase {
    @MainActor
    func testImagesAppendInOrderAndFailuresPreserveAttachments() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = try imageURL(color: .red, name: "red", directory: directory)
        let blue = try imageURL(color: .blue, name: "blue", directory: directory)
        let green = try imageURL(color: .green, name: "green", directory: directory)
        let unreadable = directory.appending(path: "broken.png")
        try Data("invalid image".utf8).write(to: unreadable)
        let stream = CaptureBatchStream()
        let live = LiveSession(vault: Vault(directory: directory), credentials: TestCredentials(), streamer: stream)
        live.start(assistant: .init(name: "Images"), settings: .init(),
                   options: .init(microphone: false, save: false, screenContext: true))

        live.attachImage(red)
        try await waitUntil { !live.capturing }
        let firstID = try XCTUnwrap(live.captureAttachments.first?.id)
        live.attachImages([blue, green])
        try await waitUntil { !live.capturing }
        let expected = try [red, blue, green].map { try CaptureImage.read($0).data }
        XCTAssertEqual(live.captureImages.map(\.data), expected)
        XCTAssertEqual(live.captureAttachments.first?.id, firstID)
        let requests = await stream.batches
        XCTAssertTrue(requests.isEmpty)

        live.removeCaptureImage(live.captureAttachments[1].id)
        XCTAssertEqual(live.captureImages.map(\.data), [expected[0], expected[2]])
        live.attachImages([blue, unreadable])
        try await waitUntil { !live.capturing }
        XCTAssertNotNil(live.captureError)
        XCTAssertEqual(live.captureImages.map(\.data), [expected[0], expected[2]])

        live.attachImage(blue)
        live.setScreenContext(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(live.captureImages.isEmpty)
        XCTAssertFalse(live.capturing)
        live.end()
        try await waitUntil { live.phase == .idle }
    }

    @MainActor
    func testAttachmentLimitsAndClearAll() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try imageURL(color: .blue, name: "fixture", directory: directory)
        let live = LiveSession(vault: Vault(directory: directory), credentials: TestCredentials())
        live.start(assistant: .init(name: "Images"), settings: .init(),
                   options: .init(microphone: false, save: false, screenContext: true))
        live.attachImages(Array(repeating: file, count: LiveSession.maximumCaptureImages))
        try await waitUntil { !live.capturing }
        XCTAssertEqual(live.captureImages.count, 6)
        live.attachImage(file)
        XCTAssertNotNil(live.captureError)
        XCTAssertEqual(live.captureImages.count, 6)

        let thirdLimit = LiveSession.maximumCaptureBytes / 3
        let large = CaptureImage(data: Data(repeating: 0, count: thirdLimit))
        XCTAssertNil(LiveSession.captureLimitError(for: [large, large, large]))
        XCTAssertNotNil(LiveSession.captureLimitError(for: [large, large, large, .init(data: Data([0]))]))
        live.discardImage()
        XCTAssertTrue(live.captureImages.isEmpty)
        live.attachImage(file)
        live.end()
        try await waitUntil { live.phase == .idle }
        XCTAssertTrue(live.captureImages.isEmpty)
        XCTAssertFalse(live.capturing)
    }

    @MainActor
    func testExplicitAnswerSendsEntireBatchAndRetryRetainsExactImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = try imageURL(color: .red, name: "red", directory: directory)
        let blue = try imageURL(color: .blue, name: "blue", directory: directory)
        let green = try imageURL(color: .green, name: "green", directory: directory)
        let credentials = TestCredentials()
        try credentials.write("fixture-only", for: .openAI)
        let stream = CaptureBatchStream(failures: 1)
        let live = LiveSession(vault: Vault(directory: directory), credentials: credentials, streamer: stream)
        live.start(assistant: .init(name: "Images", provider: .openAI), settings: .init(),
                   options: .init(microphone: false, save: false, screenContext: true))
        live.attachImages([red, blue])
        try await waitUntil { !live.capturing }
        let sentImages = live.captureImages.map(\.data)
        live.composer = "Use both images to solve this problem."
        live.askComposer()
        try await waitUntil { !live.generating && live.answerError != nil }
        XCTAssertTrue(live.captureImages.isEmpty)

        live.attachImage(green)
        try await waitUntil { !live.capturing }
        let pendingImages = live.captureImages.map(\.data)
        live.regenerate()
        try await waitUntil { !live.generating && live.answer == "Combined answer" }
        var batches = await stream.batches
        XCTAssertEqual(batches, [sentImages, sentImages])
        XCTAssertEqual(live.captureImages.map(\.data), pendingImages)

        live.askComposer()
        try await waitUntil { !live.generating }
        batches = await stream.batches
        XCTAssertEqual(batches, [sentImages, sentImages, pendingImages])
        live.setScreenContext(false)
        live.regenerate()
        XCTAssertNotNil(live.captureError)
        let afterClear = await stream.batches
        XCTAssertEqual(afterClear.count, 3)
        live.end()
        try await waitUntil { live.phase == .idle }
    }

    @MainActor
    private func imageURL(color: NSColor, name: String, directory: URL) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 {
            for y in 0..<2 { bitmap.setColor(color, atX: x, y: y) }
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let file = directory.appending(path: name + ".png")
        try data.write(to: file)
        return file
    }

    @MainActor
    private func waitUntil(_ check: () -> Bool) async throws {
        for _ in 0..<150 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for attachment state.")
        throw CancellationError()
    }
}

private actor CaptureBatchStream: AnswerStreaming {
    private(set) var batches = [[Data]]()
    private var failures: Int

    init(failures: Int = 0) { self.failures = failures }

    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        batches.append(prompt.images.map(\.data))
        if failures > 0 {
            failures -= 1
            throw ProviderError.http(500)
        }
        await emit(.text("Combined answer"))
        await emit(.finished)
    }
}
