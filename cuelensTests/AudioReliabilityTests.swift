import AVFoundation
import XCTest
@testable import cuelens

final class AudioReliabilityTests: XCTestCase {
    func testEmptyAndTinyBuffersDoNotTerminateLiveConversion() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        var normalizer = AudioNormalizer()
        XCTAssertNil(try normalizer.convert(input))
        input.frameLength = 16
        for i in 0..<16 { input.floatChannelData?[0][i] = 0.25 }
        var frames = 0
        for _ in 0..<100 {
            if let output = try normalizer.convert(input) {
                frames += Int(output.frameLength)
                XCTAssertEqual(output.format.sampleRate, 24_000)
                XCTAssertEqual(output.format.channelCount, 1)
            }
        }
        XCTAssertGreaterThan(frames, 500)
    }

    func testNormalizerKeepsRightChannelSpeechAndHandlesSampleRateChange() throws {
        var normalizer = AudioNormalizer()
        for rate in [48_000.0, 44_100.0, 24_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048))
            input.frameLength = input.frameCapacity
            for i in 0..<Int(input.frameLength) {
                input.floatChannelData?[0][i] = 0
                input.floatChannelData?[1][i] = 0.3
            }
            let output = try XCTUnwrap(try normalizer.convert(input))
            XCTAssertGreaterThan(AudioPipeline.level(output), 0.05)
            XCTAssertEqual(output.format.channelCount, 1)
            XCTAssertEqual(output.format.sampleRate, 24_000)
        }
    }

    func testTapCopyOwnsCompleteFramesAfterCallbackMemoryChanges() throws {
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                   channels: 2, interleaved: interleaved))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            input.frameLength = input.frameCapacity
            let buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            for buffer in buffers {
                let samples = try XCTUnwrap(buffer.mData?.assumingMemoryBound(to: Float.self))
                for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { samples[i] = 0.4 }
            }
            let copy = try XCTUnwrap(AudioBufferCopy.copy(input.audioBufferList, format: format))
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            XCTAssertEqual(copy.frameLength, 128)
            for buffer in UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList) {
                let samples = try XCTUnwrap(buffer.mData?.assumingMemoryBound(to: Float.self))
                XCTAssertEqual(samples[0], 0.4)
                XCTAssertEqual(samples[Int(buffer.mDataByteSize) / MemoryLayout<Float>.size - 1], 0.4)
            }
        }
    }

    func testPeakDetectsClippingThatAverageMeterCanMiss() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        input.frameLength = input.frameCapacity
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        for i in 0..<1_024 { samples[i] = 0 }
        samples[512] = -1
        XCTAssertEqual(AudioPipeline.peak(input), 1)
        XCTAssertLessThan(AudioPipeline.level(input), 0.04)
    }
}
