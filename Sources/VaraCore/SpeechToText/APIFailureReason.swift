import Foundation

/// Why a cloud transcription / credential call failed, in user-actionable terms.
///
/// Shared by two paths so the app can speak plainly instead of dumping a raw
/// HTTP error: the dictation failure path (turn a thrown backend error into a
/// clear message) and the Settings key-validation path (turn a probe response
/// into a status). Classification lives here in VaraCore; the localized wording
/// lives in the app layer.
public enum APIFailureReason: Sendable, Equatable {
    /// 401 — the key is wrong, revoked, or for the wrong account.
    case invalidKey
    /// 429 `insufficient_quota` — the account is out of credit / has no billing.
    case insufficientQuota
    /// 429 rate limit — the key works, the provider is just throttling right now.
    case rateLimited
    /// 403 / model-not-found — the account can't use this model or endpoint.
    case noAccess
    /// Couldn't reach the provider at all (offline, DNS, timeout).
    case network
    /// 5xx — provider-side outage.
    case server
    /// Anything else; carries the status + provider message for display/logging.
    case other(status: Int?, message: String?)

    /// Classify an HTTP status + response body. Understands the OpenAI / Groq
    /// error envelope (`{"error":{"message","type","code"}}`).
    public static func classify(status: Int, body: String) -> APIFailureReason {
        let lower = body.lowercased()
        switch status {
        case 200..<300:
            return .other(status: status, message: nil) // not a failure; caller shouldn't pass 2xx
        case 401:
            return .invalidKey
        case 402:
            return .insufficientQuota
        case 403:
            // 403 is usually "model not accessible / unsupported region" (noAccess),
            // but some org/project setups surface billing/quota problems as 403 too —
            // check the body first so those read as "add credit", not "no access".
            if indicatesNoCredit(lower) { return .insufficientQuota }
            return .noAccess
        case 404:
            if lower.contains("model") { return .noAccess }
            return .other(status: status, message: extractMessage(body))
        case 429:
            if indicatesNoCredit(lower) { return .insufficientQuota }
            return .rateLimited
        case 500..<600:
            return .server
        default:
            // Some providers signal a bad/expired key with a 400 + an explicit code.
            if lower.contains("invalid_api_key") || lower.contains("incorrect api key") {
                return .invalidKey
            }
            if indicatesNoCredit(lower) { return .insufficientQuota }
            return .other(status: status, message: extractMessage(body))
        }
    }

    /// Whether an error body points to "no money on the account" rather than a
    /// transient throttle or an access problem.
    private static func indicatesNoCredit(_ lowercasedBody: String) -> Bool {
        lowercasedBody.contains("insufficient_quota")
            || lowercasedBody.contains("exceeded your current quota")
            || lowercasedBody.contains("billing")
            || lowercasedBody.contains("insufficient funds")
    }

    /// Map a thrown backend error to a reason, or nil if it isn't a recognized
    /// cloud-call failure (e.g. a local encoding bug — let the generic path show).
    public static func reason(for error: Error) -> APIFailureReason? {
        switch error {
        case let openAI as OpenAITranscriptionError:
            switch openAI {
            case .httpError(let status, let body):
                return classify(status: status, body: body)
            case .realtimeConnectionRejected(_, let status, _):
                if let status { return classify(status: status, body: "") }
                return .noAccess
            case .realtimeServerError(let type, let message):
                if type.lowercased().contains("quota") { return .insufficientQuota }
                return .other(status: nil, message: message.isEmpty ? type : message)
            case .invalidResponse, .encodingFailed, .unsupportedAudio:
                return nil
            }
        case let groq as GroqWhisperError:
            switch groq {
            case .httpError(let status, let body):
                return classify(status: status, body: body)
            case .invalidResponse, .unsupportedAudio:
                return nil
            }
        case let urlError as URLError:
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff:
                return .network
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The provider's human-readable message from an error envelope, if present.
    private static func extractMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else { return nil }
        return message
    }
}
