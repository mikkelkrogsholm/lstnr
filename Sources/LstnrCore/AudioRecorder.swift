@preconcurrency import AVFoundation
import Foundation

public enum AudioRecorderError: Error, CustomStringConvertible {
    case cannotCreateTargetFormat
    case cannotCreateConverter(String)
    case engineStartFailed(String)

    public var description: String {
        switch self {
        case .cannotCreateTargetFormat: return "Cannot build target PCM16 mono 16kHz format"
        case .cannotCreateConverter(let s): return "Cannot create audio converter: \(s)"
        case .engineStartFailed(let s): return "AVAudioEngine start failed: \(s)"
        }
    }
}

/// Captures microphone audio and yields PCM s16le 16kHz mono chunks on an AsyncStream.
public final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<Data>.Continuation?
    private let targetFormat: AVAudioFormat

    public init() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.cannotCreateTargetFormat
        }
        self.targetFormat = format
    }

    public func start() throws -> AsyncStream<Data> {
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)

        guard AVAudioConverter(from: sourceFormat, to: targetFormat) != nil else {
            throw AudioRecorderError.cannotCreateConverter("\(sourceFormat) → \(targetFormat)")
        }

        let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont

        let targetFormat = self.targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { buffer, _ in
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                return
            }

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 512)
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                return
            }

            final class FeedState: @unchecked Sendable { var fed = false }
            let state = FeedState()
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, status in
                if state.fed {
                    status.pointee = .endOfStream
                    return nil
                }
                state.fed = true
                status.pointee = .haveData
                return buffer
            }

            if error != nil { return }
            guard let channelData = out.int16ChannelData else { return }
            let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
            guard byteCount > 0 else { return }
            let data = Data(bytes: channelData.pointee, count: byteCount)
            cont.yield(data)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            cont.finish()
            self.continuation = nil
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }
        return stream
    }

    public func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        continuation?.finish()
        continuation = nil
    }
}
