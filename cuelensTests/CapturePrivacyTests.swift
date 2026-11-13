import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import cuelens

final class CapturePrivacyTests: XCTestCase {
    func testImportedImageDropsLocationAndCommentMetadataBeforeSharing() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2_560, height: 960, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2_560, height: 960))
        let sourceImage = try XCTUnwrap(context.makeImage())
        let file = directory.appending(path: "fixture.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.0,
                                           kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private fixture metadata"]
        ]
        CGImageDestinationAddImage(destination, sourceImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])

        let captured = try CaptureImage.read(file)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithData(captured.data as CFData, nil))
        let result = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
        XCTAssertNil(result[kCGImagePropertyGPSDictionary])
        XCTAssertNil((result[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        let width = try XCTUnwrap(result[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(result[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(width, height), CaptureImage.maximumDimension)
        XCTAssertEqual(Double(width) / Double(height), 2_560.0 / 960, accuracy: 0.01)
    }

    @MainActor
    func testSessionWithoutRetentionLeavesNoTranscriptOrRecordingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(directory: directory)
        let live = LiveSession(vault: vault, credentials: TestCredentials())
        live.start(assistant: .init(name: "Temporary review"), settings: .init(),
                   options: .init(microphone: false, meetingAudio: false, save: false, saveAudio: true))
        XCTAssertFalse(live.savingAudio, "Retention disabled must dominate a stale recording option.")
        live.addNote("Temporary text that must not be retained.")
        live.end()
        let deadline = Date().addingTimeInterval(2)
        while live.phase != .idle, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(live.phase, .idle)
        XCTAssertEqual(live.completionMessage, "Session ended")
        XCTAssertTrue(try vault.sessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
