@preconcurrency import AVFoundation
import Foundation

public enum AudioReaderError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case conversionFailed(String)
    case noChannelData

    public var description: String {
        switch self {
        case .unsupportedFormat(let s): return "Unsupported audio format: \(s)"
        case .conversionFailed(let s): return "Audio conversion failed: \(s)"
        case .noChannelData: return "No audio data in buffer"
        }
    }
}

public enum AudioReader {
    /// Reads any audio file and returns raw PCM 16-bit little-endian mono data at the target sample rate.
    public static func readPCM16(
        url: URL,
        targetSampleRate: Double = 16000
    ) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioReaderError.unsupportedFormat("Cannot build target PCM16 format")
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioReaderError.conversionFailed("Cannot create converter from \(sourceFormat) to \(targetFormat)")
        }

        let sourceCapacity = AVAudioFrameCount(file.length)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceCapacity
        ) else {
            throw AudioReaderError.conversionFailed("Cannot allocate source buffer")
        }
        try file.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio + 4096)
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetCapacity
        ) else {
            throw AudioReaderError.conversionFailed("Cannot allocate target buffer")
        }

        final class FeedState: @unchecked Sendable { var fed = false }
        let state = FeedState()
        var nsError: NSError?
        let status = converter.convert(to: targetBuffer, error: &nsError) { _, outStatus in
            if state.fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            state.fed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let nsError {
            throw AudioReaderError.conversionFailed(nsError.localizedDescription)
        }
        if status == .error {
            throw AudioReaderError.conversionFailed("converter status = error")
        }

        guard let channelData = targetBuffer.int16ChannelData else {
            throw AudioReaderError.noChannelData
        }
        let frameCount = Int(targetBuffer.frameLength)
        let byteCount = frameCount * MemoryLayout<Int16>.size
        return Data(bytes: channelData.pointee, count: byteCount)
    }
}
