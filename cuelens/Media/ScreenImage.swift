import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureImage: Sendable {
    let data: Data

    static let maximumDimension = 2_048

    static func read(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? .max) < 24_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
              ] as CFDictionary) else { throw ScreenImageError.unreadable }
        return try encode(image)
    }

    static func encode(_ image: CGImage) throws -> Self {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenImageError.unreadable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 5_000_000 else { throw ScreenImageError.unreadable }
        return Self(data: data as Data)
    }
}

enum ScreenImageError: LocalizedError {
    case unreadable, pickerFailed, displayUnavailable, permissionRequired

    var errorDescription: String? {
        switch self {
        case .unreadable: "CueLens couldn’t read this image. Try a smaller PNG or JPEG."
        case .pickerFailed: "The window picker couldn’t capture an image. Check Screen & System Audio Recording in System Settings or choose an image file."
        case .displayUnavailable: "This display is unavailable. Move the pointer to the display you want to capture and retry."
        case .permissionRequired: "Allow CueLens in System Settings → Privacy & Security → Screen & System Audio Recording, then retry Capture."
        }
    }
}

@MainActor
final class WindowCapture: NSObject, SCContentSharingPickerObserver {
    private let picker = SCContentSharingPicker.shared
    private var completion: ((Result<CaptureImage?, Error>) -> Void)?
    private var requestID: UUID?
    private var screenshotWork: Task<Void, Never>?

    func chooseWindow(completion: @escaping (Result<CaptureImage?, Error>) -> Void) {
        cancel()
        self.completion = completion
        requestID = UUID()
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        if let identifier = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [identifier] }
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present(using: .window)
    }

    func cancel() {
        screenshotWork?.cancel()
        screenshotWork = nil
        finish(.success(nil))
    }

    func captureDisplay() async throws -> CaptureImage {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            throw ScreenImageError.displayUnavailable
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            try Task.checkCancellation()
            throw ScreenImageError.permissionRequired
        }
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenImageError.displayUnavailable
        }
        // This filter affects CueLens's own screenshot only.
        let ownApplication = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplication, exceptingWindows: [])
        return try await Self.image(from: filter)
    }

    private static func image(from filter: SCContentFilter) async throws -> CaptureImage {
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { throw ScreenImageError.pickerFailed }
        let configuration = SCStreamConfiguration()
        let scale = min(CGFloat(filter.pointPixelScale), CGFloat(CaptureImage.maximumDimension) / max(size.width, size.height))
        configuration.width = max(2, Int(size.width * scale))
        configuration.height = max(2, Int(size.height * scale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return try CaptureImage.encode(image)
    }

    private func finish(_ result: Result<CaptureImage?, Error>) {
        guard let completion else { return }
        self.completion = nil
        requestID = nil
        screenshotWork = nil
        picker.remove(self)
        picker.isActive = false
        completion(result)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.cancel() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(.failure(ScreenImageError.pickerFailed)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard let requestID = self.requestID else { return }
            self.screenshotWork?.cancel()
            self.screenshotWork = Task { @MainActor in
                do {
                    let image = try await Self.image(from: filter)
                    guard self.requestID == requestID else { return }
                    self.finish(.success(image))
                } catch {
                    guard !Task.isCancelled, self.requestID == requestID else { return }
                    self.finish(.failure(ScreenImageError.pickerFailed))
                }
            }
        }
    }
}
