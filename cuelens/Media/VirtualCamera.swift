import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation
import Observation
import SystemExtensions

enum VirtualCameraFailure: LocalizedError {
    case deviceUnavailable, start(Int32), frame, formatMismatch
    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: "CueLens Camera isn’t available. Check its approval in System Settings and restart the meeting app."
        case .start(let code): "CueLens couldn’t open its virtual camera input (\(code)). Use your physical camera while checking the extension."
        case .frame: "CueLens couldn’t prepare a virtual camera frame. Use your physical camera."
        case .formatMismatch: "The installed CueLens Camera uses an older video format. Update the camera extension, then reopen your meeting app."
        }
    }
}

@MainActor
@Observable
final class VirtualCameraControl: NSObject, OSSystemExtensionRequestDelegate {
    private(set) var status = ""
    private(set) var requesting = false
    private(set) var available = false

    private var extensionID: String? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let identifier = id + ".camera"
        let path = Bundle.main.bundleURL.appending(path: "Contents/Library/SystemExtensions/\(identifier).systemextension")
        return FileManager.default.fileExists(atPath: path.path) ? identifier : nil
    }

    var bundled: Bool { extensionID != nil }

    func refresh() { available = VirtualCameraOutput.findInput() != nil }

    func request(install: Bool) {
        guard let extensionID, !requesting else { return }
        let request = install
            ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
            : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        requesting = true
        status = install ? "Requesting camera extension activation…" : "Requesting camera extension removal…"
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            status = "Approve CueLens in System Settings → General → Login Items & Extensions → Camera Extensions."
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            requesting = false
            status = error.localizedDescription
            refresh()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            requesting = false
            status = result == .willCompleteAfterReboot ? "Restart macOS to complete the change." : "macOS completed the request. Refresh camera status if needed."
            refresh()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}

final class VirtualCameraOutput {
    private static let uid = "4D1DE982-586D-49C9-93E5-6E10E0F442A6"
    private static let width = 1_280
    private static let height = 720
    private static let fps: Int32 = 30

    private let device: CMIODeviceID
    private let input: CMIOStreamID
    private let queue: CMSimpleQueue
    private let pool: CVPixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var running = true

    static func isVirtual(_ id: String) -> Bool { id.caseInsensitiveCompare(uid) == .orderedSame }

    init() throws {
        guard let (device, stream) = Self.findInput() else { throw VirtualCameraFailure.deviceUnavailable }
        guard Self.supportsOutputFormat(stream) else { throw VirtualCameraFailure.formatMismatch }
        self.device = device
        input = stream
        var unmanaged: Unmanaged<CMSimpleQueue>?
        let result = CMIOStreamCopyBufferQueue(stream, nil, nil, &unmanaged)
        guard result == noErr, let unmanaged else { throw VirtualCameraFailure.start(result) }
        queue = unmanaged.takeRetainedValue()
        var bufferPool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &bufferPool)
        guard let bufferPool else { throw VirtualCameraFailure.frame }
        pool = bufferPool
        let status = CMIODeviceStartStream(device, stream)
        guard status == noErr else { throw VirtualCameraFailure.start(status) }
    }

    func stop() {
        if running { CMIODeviceStopStream(device, input) }
        running = false
    }

    func send(_ image: CIImage, using context: CIContext) throws {
        let capacity = CMSimpleQueueGetCapacity(queue)
        guard running, capacity > 0, CMSimpleQueueGetCount(queue) < max(1, capacity * 3 / 4) else { return }
        var buffer: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &buffer)
        if allocation == kCVReturnWouldExceedAllocationThreshold { return }
        guard allocation == kCVReturnSuccess, let buffer, image.extent.width > 0, image.extent.height > 0 else {
            throw VirtualCameraFailure.frame
        }
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let fitted = resized.transformed(by: CGAffineTransform(translationX: bounds.midX - resized.extent.midX,
                                                                y: bounds.midY - resized.extent.midY))
            .composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        context.render(fitted, to: buffer, bounds: bounds, colorSpace: colorSpace)

        var description: CMVideoFormatDescription?
        let format = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                                   formatDescriptionOut: &description)
        guard format == noErr, let description else { throw VirtualCameraFailure.frame }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Self.fps),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let result = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                              formatDescription: description, sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw VirtualCameraFailure.frame }
        let retained = Unmanaged.passRetained(sample)
        if CMSimpleQueueEnqueue(queue, element: retained.toOpaque()) != noErr { retained.release() }
    }

    static func findInput() -> (CMIODeviceID, CMIOStreamID)? {
        for device in ids(CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices) {
            var address = property(kCMIODevicePropertyDeviceUID)
            var uid: Unmanaged<CFString>?
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                                                   &used, &uid)
            guard status == noErr, let uid, isVirtual(uid.takeRetainedValue() as String) else { continue }
            for stream in ids(device, selector: kCMIODevicePropertyStreams) {
                var direction: UInt32 = 1
                var address = property(kCMIOStreamPropertyDirection)
                let status = CMIOObjectGetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                                       &used, &direction)
                if status == noErr && direction == 0 { return (device, stream) }
            }
        }
        return nil
    }

    private static func supportsOutputFormat(_ stream: CMIOStreamID) -> Bool {
        var address = property(kCMIOStreamPropertyFormatDescription)
        var unmanaged: Unmanaged<CMFormatDescription>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(stream, &address, 0, nil,
                                               UInt32(MemoryLayout<Unmanaged<CMFormatDescription>?>.size), &used, &unmanaged)
        guard status == noErr, let unmanaged else { return false }
        let description = unmanaged.takeRetainedValue()
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return Int(dimensions.width) == width && Int(dimensions.height) == height
            && CMFormatDescriptionGetMediaSubType(description) == kCVPixelFormatType_32BGRA
    }

    private static func ids(_ device: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var address = property(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= 4, size <= 4_096, size % 4 == 0 else { return [] }
        var list = Array(repeating: CMIOObjectID(), count: Int(size / 4))
        var used: UInt32 = 0
        let result = list.withUnsafeMutableBytes {
            CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, $0.baseAddress!)
        }
        return result == noErr && used <= size ? Array(list.prefix(Int(used / 4))) : []
    }

    private static func property(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
                                  mElement: UInt32(kCMIOObjectPropertyElementMain))
    }

    deinit { stop() }
}
