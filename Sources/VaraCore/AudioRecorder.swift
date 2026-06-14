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

    /// Serializes mutation of the tap/converter state, which is touched both by
    /// the audio render thread (tap callback) and the main thread (config-change
    /// notification, stop()).
    private let stateLock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var onLevel: (@Sendable (Double) -> Void)?
    private var configChangeObserver: NSObjectProtocol?

    /// Total number of input buffers dropped (converter failure or zero output
    /// frames). Dropped buffers are lost speech, so this must never silently
    /// stay invisible — it is logged and surfaced via `onBufferDropped`.
    private var droppedBufferCount = 0

    /// Fired whenever an input buffer is dropped, carrying the running total of
    /// dropped buffers this session. Lets the UI/diagnostics surface silent
    /// word loss (e.g. when an AirPods/aggregate device changes format
    /// mid-session). Optional so the existing `start(onLevel:)` API is unaffected.
    public var onBufferDropped: (@Sendable (Int) -> Void)?

    /// Diagnostic log sink for non-fatal audio events (dropped buffers, input
    /// device/format changes). Optional; defaults to no-op.
    public var diagnosticLog: (@Sendable (String) -> Void)?

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

    /// Linear RMS of interleaved PCM s16le samples, normalized to 0...1.
    public static func pcm16RMSLevel(_ data: Data) -> Double {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            var index = 0
            while index + 1 < rawBuffer.count {
                let unsignedSample = UInt16(rawBuffer[index]) | (UInt16(rawBuffer[index + 1]) << 8)
                let sample = Double(Int16(bitPattern: unsignedSample)) / Double(Int16.max)
                sumOfSquares += sample * sample
                index += 2
            }
        }
        return (sumOfSquares / Double(sampleCount)).squareRoot()
    }

    public func start(onLevel: (@Sendable (Double) -> Void)? = nil) throws -> AsyncStream<Data> {
        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)

        // Hoist the converter so it is built once for this session's
        // source→target format pair instead of allocating one per buffer in the
        // render thread. Validates the format pair up front, same as before.
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioRecorderError.cannotCreateConverter("\(sourceFormat) → \(targetFormat)")
        }

        let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)

        stateLock.lock()
        self.continuation = cont
        self.onLevel = onLevel
        self.converter = converter
        self.sourceFormat = sourceFormat
        self.droppedBufferCount = 0
        stateLock.unlock()

        installTap(input: input, sourceFormat: sourceFormat)

        // Rebuild the tap/converter when the input device or its format changes
        // mid-session (e.g. switching to AirPods or an aggregate device). Before
        // this, such a change left the tap bound to a stale format and every
        // buffer was silently dropped, stalling the stream.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeConfigChangeObserver()
            input.removeTap(onBus: 0)
            cont.finish()
            stateLock.lock()
            self.continuation = nil
            self.converter = nil
            self.sourceFormat = nil
            self.onLevel = nil
            stateLock.unlock()
            throw AudioRecorderError.engineStartFailed(error.localizedDescription)
        }
        return stream
    }

    /// Installs the input tap and wires it to the hoisted converter. Called on
    /// start and again after a configuration change.
    private func installTap(input: AVAudioNode, sourceFormat: AVAudioFormat) {
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { [weak self] buffer, _ in
            guard let self else { return }

            self.stateLock.lock()
            let isActive = self.converter != nil
            let cont = self.continuation
            let onLevel = self.onLevel
            self.stateLock.unlock()

            guard isActive, let cont else {
                // Session stopped between the tap firing and here — not a drop.
                return
            }

            // AVAudioConverter is STATEFUL: the one-buffer-then-endOfStream feed
            // pattern below leaves it drained, so a converter reused across
            // buffers returns zero output frames on every buffer after the first
            // (capturing only ~0.1s of audio). Create a fresh converter per
            // buffer — this is the behaviour that shipped and worked; hoisting it
            // to once-per-session was an optimization that broke capture.
            guard let converter = AVAudioConverter(from: sourceFormat, to: self.targetFormat) else {
                self.recordDroppedBuffer(reason: "could not create converter")
                return
            }

            let ratio = self.targetFormat.sampleRate / sourceFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 512)
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: outCapacity) else {
                self.recordDroppedBuffer(reason: "could not allocate output buffer")
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

            if let error {
                self.recordDroppedBuffer(reason: "converter error: \(error.localizedDescription)")
                return
            }
            guard let channelData = out.int16ChannelData else {
                self.recordDroppedBuffer(reason: "no int16 channel data")
                return
            }
            let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
            guard byteCount > 0 else {
                self.recordDroppedBuffer(reason: "zero output frames")
                return
            }
            let data = Data(bytes: channelData.pointee, count: byteCount)
            onLevel?(Self.pcm16RMSLevel(data))
            cont.yield(data)
        }
    }

    /// Records and surfaces a dropped input buffer so lost speech is visible
    /// rather than silent.
    private func recordDroppedBuffer(reason: String) {
        stateLock.lock()
        droppedBufferCount += 1
        let total = droppedBufferCount
        stateLock.unlock()
        diagnosticLog?("AudioRecorder dropped input buffer (\(reason)); total dropped this session=\(total).")
        onBufferDropped?(total)
    }

    /// Rebuilds the tap and converter for the engine's current input format when
    /// the audio device or format changes mid-session.
    private func handleConfigurationChange() {
        stateLock.lock()
        guard continuation != nil else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let input = engine.inputNode
        let newSourceFormat = input.outputFormat(forBus: 0)

        stateLock.lock()
        let previousFormat = sourceFormat
        stateLock.unlock()

        if let previousFormat, previousFormat == newSourceFormat {
            diagnosticLog?("AudioRecorder configuration changed; input format unchanged (\(newSourceFormat)).")
            return
        }

        input.removeTap(onBus: 0)

        guard let newConverter = AVAudioConverter(from: newSourceFormat, to: targetFormat) else {
            diagnosticLog?(
                "AudioRecorder configuration changed but could not rebuild converter for \(newSourceFormat) → \(targetFormat); audio may stall."
            )
            return
        }

        stateLock.lock()
        converter = newConverter
        sourceFormat = newSourceFormat
        stateLock.unlock()

        installTap(input: input, sourceFormat: newSourceFormat)
        diagnosticLog?("AudioRecorder rebuilt tap/converter for new input format \(newSourceFormat).")
    }

    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    public func stop() {
        removeConfigChangeObserver()
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        stateLock.lock()
        let cont = continuation
        continuation = nil
        converter = nil
        sourceFormat = nil
        onLevel = nil
        stateLock.unlock()
        cont?.finish()
    }
}
