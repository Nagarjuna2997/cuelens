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
    case unreadable, pickerFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "CueLens couldn’t read this image. Try a smaller PNG or JPEG."
        case .pickerFailed: "The window picker couldn’t capture an image. Check Screen & System Audio Recording in System Settings or choose an image file."
        }
    }
}

@MainActor
final class WindowCapture: NSObject, SCContentSharingPickerObserver {
    private let picker = SCContentSharingPicker.shared
    private var completion: ((Result<CaptureImage?, Error>) -> Void)?

    func chooseWindow(completion: @escaping (Result<CaptureImage?, Error>) -> Void) {
        cancel()
        self.completion = completion
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
        finish(.success(nil))
    }

    private func finish(_ result: Result<CaptureImage?, Error>) {
        guard let completion else { return }
        self.completion = nil
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
            guard self.completion != nil else { return }
            let configuration = SCStreamConfiguration()
            let size = filter.contentRect.size
            guard size.width > 0, size.height > 0 else {
                self.finish(.failure(ScreenImageError.pickerFailed))
                return
            }
            let scale = min(CGFloat(filter.pointPixelScale), CGFloat(CaptureImage.maximumDimension) / max(size.width, size.height))
            configuration.width = max(2, Int(size.width * scale))
            configuration.height = max(2, Int(size.height * scale))
            configuration.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                self.finish(.success(try CaptureImage.encode(image)))
            } catch {
                self.finish(.failure(ScreenImageError.pickerFailed))
            }
        }
    }
}
