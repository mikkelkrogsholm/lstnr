import Foundation

public struct LocalHviskeBackend: SpeechToTextBackend {
    public static let modelID = "syvai/hviske-v5.3"
    public static let modelRevision = "574bc158f3e8ce91af7995be2928f529a05c24b6"

    public let id = "local-hviske-v5.3"
    public let displayName = "Local Hviske v5.3"
    public var shortName: String { "Hviske" }
    public let capabilities = SpeechToTextBackendCapabilities(
        supportsFileTranscription: true,
        supportsStreamingTranscription: false,
        supportsLanguageHints: true,
        supportsTimestamps: false,
        runsLocally: true,
        requiresNetwork: false,
        requiredCredentialKeys: [],
        supportedSampleRates: [16_000]
    )

    private let pythonURL: URL?
    private let hfHomeURL: URL?
    private let diagnosticLog: (@Sendable (String) async -> Void)?

    public init(
        pythonURL: URL? = nil,
        hfHomeURL: URL? = nil,
        diagnosticLog: (@Sendable (String) async -> Void)? = nil
    ) {
        self.pythonURL = pythonURL
        self.hfHomeURL = hfHomeURL
        self.diagnosticLog = diagnosticLog
    }

    public func transcribe(_ request: SpeechToTextRequest) async throws -> TranscriptionResult {
        let startedAt = Date()
        let audioFile = try await materializeAudioFile(from: request.audio)
        defer { try? FileManager.default.removeItem(at: audioFile.url) }

        let pythonURL = try Self.resolvePythonURL(preferredURL: pythonURL)
        let hfHomeURL = Self.resolveHFHomeURL(preferredURL: hfHomeURL, pythonURL: pythonURL)
        let language = request.languageCode == "en" ? "en" : "da"

        await diagnosticLog?(
            "Local Hviske starting. python=\(pythonURL.path), hfHome=\(hfHomeURL.path), language=\(language), audioDuration=\(String(format: "%.2f", audioFile.durationSeconds))s"
        )

        let response = try await Self.runPythonJSON(
            pythonURL: pythonURL,
            hfHomeURL: hfHomeURL,
            arguments: ["-", audioFile.url.path, language],
            stdin: Self.runnerScript
        )

        await diagnosticLog?(
            "Local Hviske completed. textLength=\(response.text.count), device=\(response.device), dtype=\(response.dtype), elapsed=\(String(format: "%.2f", response.elapsedSeconds))s"
        )

        return TranscriptionResult(
            text: response.text,
            detectedLanguage: language,
            languageConfidence: nil,
            audioDurationSeconds: audioFile.durationSeconds,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            backend: displayName,
            rawJSON: response.rawJSON
        )
    }

    public static func runtimeStatus() -> LocalHviskeRuntimeStatus {
        let managedPython = managedVenvURL.appendingPathComponent("bin/python")
        let spikePython = spikeVenvURL.appendingPathComponent("bin/python")
        let pythonURL: URL?

        if FileManager.default.isExecutableFile(atPath: managedPython.path) {
            pythonURL = managedPython
        } else if FileManager.default.isExecutableFile(atPath: spikePython.path) {
            pythonURL = spikePython
        } else {
            pythonURL = nil
        }

        let hfHomeURL = pythonURL == spikePython && FileManager.default.fileExists(atPath: spikeHFHomeURL.path)
            ? spikeHFHomeURL
            : managedHFHomeURL
        let snapshotURL = hfHomeURL
            .appendingPathComponent("hub/models--syvai--hviske-v5.3/snapshots/\(modelRevision)")

        return LocalHviskeRuntimeStatus(
            pythonURL: pythonURL,
            hfHomeURL: hfHomeURL,
            modelSnapshotURL: snapshotURL,
            hasPythonRuntime: pythonURL != nil,
            hasModelSnapshot: FileManager.default.fileExists(atPath: snapshotURL.path)
        )
    }

    // The runtime is installed out-of-app via scripts/setup-hviske.sh (Terminal),
    // which writes to the EXACT paths runtimeStatus() detects (managedVenvURL /
    // managedHFHomeURL). The shipped, notarized app only detects and guides; it
    // never downloads or executes a Python installer.
}

public struct LocalHviskeRuntimeStatus: Sendable, Hashable {
    public let pythonURL: URL?
    public let hfHomeURL: URL
    public let modelSnapshotURL: URL
    public let hasPythonRuntime: Bool
    public let hasModelSnapshot: Bool

    public var isReady: Bool {
        hasPythonRuntime && hasModelSnapshot
    }
}

public enum LocalHviskeBackendError: Error, CustomStringConvertible, Sendable {
    case runtimeMissing
    case unsupportedAudio(String)
    case processFailed(exitCode: Int32, stderr: String)
    case invalidRunnerOutput(String)

    public var description: String {
        switch self {
        case .runtimeMissing:
            return "Local Hviske is not set up. Run the setup script in Terminal (see Settings > Advanced), then choose Local Hviske."
        case .unsupportedAudio(let reason):
            return "Local Hviske cannot transcribe this audio: \(reason)"
        case .processFailed(let exitCode, let stderr):
            return "Local Hviske process failed with exit code \(exitCode): \(stderr)"
        case .invalidRunnerOutput(let output):
            return "Local Hviske returned invalid output: \(output)"
        }
    }
}

private extension LocalHviskeBackend {
    struct MaterializedAudio: Sendable {
        let url: URL
        let durationSeconds: Double
    }

    struct RunnerResponse: Decodable, Sendable {
        let text: String
        let elapsedSeconds: Double
        let device: String
        let dtype: String
        let rawJSON: Data

        enum CodingKeys: String, CodingKey {
            case text
            case elapsedSeconds = "elapsed_seconds"
            case device
            case dtype
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            elapsedSeconds = try container.decode(Double.self, forKey: .elapsedSeconds)
            device = try container.decode(String.self, forKey: .device)
            dtype = try container.decode(String.self, forKey: .dtype)
            rawJSON = Data()
        }

        init(decoded: RunnerResponse, rawJSON: Data) {
            text = decoded.text
            elapsedSeconds = decoded.elapsedSeconds
            device = decoded.device
            dtype = decoded.dtype
            self.rawJSON = rawJSON
        }
    }

    static var applicationSupportURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("vara", isDirectory: true)
    }

    static var managedVenvURL: URL {
        applicationSupportURL.appendingPathComponent("hviske-venv", isDirectory: true)
    }

    static var managedHFHomeURL: URL {
        applicationSupportURL.appendingPathComponent("models/huggingface", isDirectory: true)
    }

    static var spikeVenvURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/vara-hviske-spike/venv", isDirectory: true)
    }

    static var spikeHFHomeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/vara-hviske-spike/hf", isDirectory: true)
    }

    func materializeAudioFile(from audio: SpeechToTextAudio) async throws -> MaterializedAudio {
        switch audio {
        case .file(let url):
            return MaterializedAudio(url: url, durationSeconds: 0)
        case .pcm16Stream(let stream, let sampleRate):
            guard sampleRate == 16_000 else {
                throw LocalHviskeBackendError.unsupportedAudio("expected PCM16 mono at 16000 Hz, got \(sampleRate) Hz")
            }

            var pcmData = Data()
            for await chunk in stream {
                pcmData.append(chunk)
            }
            guard !pcmData.isEmpty else {
                throw LocalHviskeBackendError.unsupportedAudio("recorded audio is empty")
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("vara-hviske-\(UUID().uuidString).wav")
            try Self.writePCM16WAV(data: pcmData, sampleRate: sampleRate, to: tempURL)
            return MaterializedAudio(
                url: tempURL,
                durationSeconds: Double(pcmData.count / 2) / Double(sampleRate)
            )
        }
    }

    static func resolvePythonURL(preferredURL: URL?) throws -> URL {
        if let preferredURL, FileManager.default.isExecutableFile(atPath: preferredURL.path) {
            return preferredURL
        }

        if let envPython = ProcessInfo.processInfo.environment["VARA_HVISKE_PYTHON"] {
            let url = URL(fileURLWithPath: NSString(string: envPython).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let status = runtimeStatus()
        guard let pythonURL = status.pythonURL else {
            throw LocalHviskeBackendError.runtimeMissing
        }
        return pythonURL
    }

    static func resolveHFHomeURL(preferredURL: URL?, pythonURL: URL) -> URL {
        if let preferredURL {
            return preferredURL
        }
        if let envHFHome = ProcessInfo.processInfo.environment["VARA_HVISKE_HF_HOME"] {
            return URL(fileURLWithPath: NSString(string: envHFHome).expandingTildeInPath)
        }
        if pythonURL.path.hasPrefix(spikeVenvURL.path), FileManager.default.fileExists(atPath: spikeHFHomeURL.path) {
            return spikeHFHomeURL
        }
        return managedHFHomeURL
    }

    static func runPythonJSON(
        pythonURL: URL,
        hfHomeURL: URL,
        arguments: [String],
        stdin: String
    ) async throws -> RunnerResponse {
        let output = try await runProcess(
            executableURL: pythonURL,
            arguments: arguments,
            environment: [
                "HF_HOME": hfHomeURL.path,
                "PYTORCH_ENABLE_MPS_FALLBACK": "1"
            ],
            stdin: stdin
        )

        guard let jsonLine = output.stdout
            .split(separator: "\n")
            .last
            .map(String.init),
              let jsonData = jsonLine.data(using: .utf8) else {
            throw LocalHviskeBackendError.invalidRunnerOutput(output.stdout)
        }

        do {
            let decoded = try JSONDecoder().decode(RunnerResponse.self, from: jsonData)
            return RunnerResponse(decoded: decoded, rawJSON: jsonData)
        } catch {
            throw LocalHviskeBackendError.invalidRunnerOutput(output.stdout)
        }
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        stdin: String?
    ) async throws -> (stdout: String, stderr: String) {
        // Delegates to the shared `runSubprocess` helper (which keeps the
        // non-Sendable Process, dual-pipe drain and cancellation discipline in
        // one place) and preserves this backend's exact contract: a non-zero
        // exit throws `processFailed` with stderr (or stdout when stderr empty).
        let result = try await runSubprocess(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            stdin: stdin
        )
        guard result.exitCode == 0 else {
            throw LocalHviskeBackendError.processFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return (stdout: result.stdout, stderr: result.stderr)
    }

    static func writePCM16WAV(data: Data, sampleRate: Int, to url: URL) throws {
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let bitsPerSample = UInt16(16)
        let dataSize = UInt32(data.count)
        let riffSize = UInt32(36 + data.count)

        var wav = Data()
        wav.appendASCII("RIFF")
        wav.appendLittleEndian(riffSize)
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.appendASCII("data")
        wav.appendLittleEndian(dataSize)
        wav.append(data)
        try wav.write(to: url, options: .atomic)
    }

    static let runnerScript = #"""
import json
import sys
import time

import torch
from transformers import AutoProcessor, AutoModelForSpeechSeq2Seq
from transformers.audio_utils import load_audio
import transformers.models.cohere_asr.processing_cohere_asr as cohere_asr_processing

MODEL_ID = "syvai/hviske-v5.3"
REVISION = "574bc158f3e8ce91af7995be2928f529a05c24b6"

def main():
    audio_path = sys.argv[1]
    language = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "da"
    if language not in {"da", "en"}:
        language = "da"

    cohere_asr_processing.LANGUAGES = set(cohere_asr_processing.LANGUAGES) | {"da"}

    started_at = time.time()
    processor = AutoProcessor.from_pretrained(MODEL_ID, revision=REVISION, trust_remote_code=False)
    audio = load_audio(audio_path, sampling_rate=16000)

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = torch.bfloat16 if device == "mps" else torch.float32
    model = AutoModelForSpeechSeq2Seq.from_pretrained(
        MODEL_ID,
        revision=REVISION,
        trust_remote_code=False,
        dtype=dtype,
    ).to(device).eval()

    inputs = processor(audio, sampling_rate=16000, return_tensors="pt", language=language)
    audio_chunk_index = inputs.pop("audio_chunk_index", None)
    inputs.to(model.device, dtype=model.dtype)

    with torch.inference_mode():
        outputs = model.generate(**inputs, max_new_tokens=256)

    if hasattr(processor, "batch_decode"):
        decoded = processor.batch_decode(
            outputs,
            skip_special_tokens=True,
            audio_chunk_index=audio_chunk_index,
            language=language,
        )
        text = decoded[0] if decoded else ""
    else:
        text = processor.decode(
            outputs[0],
            skip_special_tokens=True,
            audio_chunk_index=audio_chunk_index,
            language=language,
        )

    print(json.dumps({
        "text": text.strip(),
        "elapsed_seconds": time.time() - started_at,
        "device": device,
        "dtype": str(dtype),
    }, ensure_ascii=False))

if __name__ == "__main__":
    main()
"""#
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
