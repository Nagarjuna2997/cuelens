import AppKit
import AVFoundation
import CoreAudio

struct Microphone: Identifiable, Equatable {
    let id: String
    let name: String

    static func available() -> [Self] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Self(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var activeModeLabel: String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .voiceIsolation: "Voice Isolation"
        case .wideSpectrum: "Wide Spectrum"
        case .standard: "Standard"
        @unknown default: "System managed"
        }
    }

    @MainActor
    static func showSystemModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}

enum AudioFailure: LocalizedError, Equatable {
    case microphonePermission, microphoneUnavailable, speechPermission, speechUnavailable, speechInterrupted
    case systemAudio(Int32), invalidFormat, inputChanged, inputInterrupted, tooSlow, audioStorage, cloudStream
    case speechService(String, Int)
    case speechTimeout
    case speechDrainTimeout

    var errorDescription: String? {
        switch self {
        case .microphonePermission: "Microphone access is off. Enable CueLens in Privacy & Security → Microphone."
        case .microphoneUnavailable: "The selected microphone is unavailable. Reconnect it or choose another input."
        case .speechPermission: "Speech Recognition access is off. Enable CueLens in Privacy & Security → Speech Recognition."
        case .speechUnavailable: "Apple on-device speech is unavailable for this locale. Choose another locale or OpenAI Realtime."
        case .speechInterrupted: "Apple on-device transcription stopped. Retry the audio source."
        case .speechService(let domain, let code): "Apple speech could not transcribe this turn (\(domain) \(code)). Retry the audio source if this continues."
        case .speechTimeout: "Apple speech did not return text for the last audio turn. Retry the source if speech is still missing."
        case .speechDrainTimeout: "Some buffered audio could not be transcribed before the session finished. The saved transcript is incomplete."
        case .systemAudio(let status): "Meeting audio couldn’t start (Core Audio \(status)). Check Screen & System Audio Recording and retry."
        case .invalidFormat: "CueLens couldn’t read the input audio format. Reconnect the device or choose another source."
        case .inputChanged: "The audio device changed. Retry this source to use the current device."
        case .inputInterrupted: "The audio input stopped. Check the selected device, then retry."
        case .tooSlow: "Transcription is behind the audio. A buffered turn was skipped. Retry the source or reduce overlapping audio."
        case .audioStorage: "CueLens couldn’t write raw audio. Transcription can continue. Check free storage."
        case .cloudStream: "OpenAI Realtime stopped. Check your API key, access, and network connection, then retry."
        }
    }
}

enum AudioPermissions {
    static func microphone() async throws {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else { throw AudioFailure.microphonePermission }
    }
}

protocol AudioInput: AnyObject {
    func start() throws
    func stop()
}

final class MicrophoneInput: NSObject, AudioInput, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let capture = AVCaptureSession()
    private let deviceID: String?
    private let queue: DispatchQueue
    private let feed: (AVAudioPCMBuffer) -> Void
    private let failure: (AudioFailure) -> Void
    private var observers = [NSObjectProtocol]()
    private var active = false

    init(deviceID: String?, queue: DispatchQueue, feed: @escaping (AVAudioPCMBuffer) -> Void,
         failure: @escaping (AudioFailure) -> Void) {
        self.deviceID = deviceID
        self.queue = queue
        self.feed = feed
        self.failure = failure
    }

    func start() throws {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? (deviceID == nil ? AVCaptureDevice.default(for: .audio) : nil)
        guard let device, device.isConnected else { throw AudioFailure.microphoneUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard capture.canAddInput(input), capture.canAddOutput(output) else { throw AudioFailure.microphoneUnavailable }
        capture.beginConfiguration()
        capture.addInput(input)
        capture.addOutput(output)
        capture.commitConfiguration()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: capture, queue: nil) {
            [weak self] _ in self?.report(.inputInterrupted)
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
            [weak self] _ in self?.report(.inputChanged)
        })
        capture.startRunning()
        active = capture.isRunning
        guard active else { throw AudioFailure.microphoneUnavailable }
    }

    func stop() {
        active = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if capture.isRunning { capture.stopRunning() }
    }

    private func report(_ error: AudioFailure) {
        queue.async { [weak self] in
            guard let self, active else { return }
            failure(error)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, let description = sample.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              sample.numSamples > 0, sample.numSamples < 65_536,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        pcm.frameLength = pcm.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples),
                                                                into: pcm.mutableAudioBufferList)
        if status == noErr { feed(pcm) }
    }
}

final class MeetingAudioInput: AudioInput {
    private let queue: DispatchQueue
    private let feed: (AVAudioPCMBuffer) -> Void
    private let failure: (AudioFailure) -> Void
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "org.cuelens.meeting-io", qos: .userInitiated)
    private let pending = DispatchSemaphore(value: 12)
    private var accepting = false

    init(queue: DispatchQueue, feed: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (AudioFailure) -> Void) {
        self.queue = queue
        self.feed = feed
        self.failure = failure
    }

    func start() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: processObject().map { [$0] } ?? [])
        description.name = "CueLens Meeting Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap))
        var address = Self.address(kAudioTapPropertyFormat)
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &stream))
        guard let format = AVAudioFormat(streamDescription: &stream) else { throw AudioFailure.invalidFormat }

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CueLens Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate))
        let pending = self.pending
        let queue = self.queue
        accepting = true
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, ioQueue) { [weak self] _, input, _, _, _ in
            guard pending.wait(timeout: .now()) == .success else { return }
            guard let copy = AudioBufferCopy.copy(input, format: format) else {
                pending.signal()
                return
            }
            queue.async {
                defer { pending.signal() }
                guard let self, self.accepting else { return }
                self.feed(copy)
            }
        })
        guard let io else { throw AudioFailure.invalidFormat }
        try check(AudioDeviceStart(aggregate, io))
        var output = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.failure(.inputChanged) }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &output, queue, listener) == noErr {
            outputListener = listener
        }
    }

    func stop() {
        accepting = false
        if let outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
            self.outputListener = nil
        }
        if let io {
            AudioDeviceStop(aggregate, io)
            AudioDeviceDestroyIOProcID(aggregate, io)
            self.io = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func processObject() -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioFailure.systemAudio(status) }
    }
}

enum AudioBufferCopy {
    /// Core Audio owns the callback buffers. The queued consumer must own a complete copy.
    static func copy(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        let expectedCount = format.isInterleaved ? 1 : Int(format.channelCount)
        guard bytesPerFrame > 0, buffers.count == expectedCount, let first = buffers.first,
              first.mDataByteSize > 0, first.mDataByteSize % bytesPerFrame == 0 else { return nil }
        let frames = first.mDataByteSize / bytesPerFrame
        guard frames < 65_536, buffers.allSatisfy({ $0.mData != nil && $0.mDataByteSize == first.mDataByteSize }),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames
        let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, target) in zip(buffers, destinations) {
            guard let from = source.mData, let to = target.mData,
                  source.mDataByteSize == target.mDataByteSize else { return nil }
            memcpy(to, from, Int(source.mDataByteSize))
        }
        return copy
    }
}
