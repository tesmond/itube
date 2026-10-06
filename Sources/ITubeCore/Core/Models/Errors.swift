import Foundation

public enum PlaybackError: Error, Sendable, Equatable {
    case unavailable
    case restricted
    case networkUnavailable
    case providerFailure
    case streamExpired
    case unsupportedCodec
    case invalidManifest
    case playbackFailed

    /// Never expose implementation details to the user (ADR §47).
    public var userMessage: String {
        switch self {
        case .unavailable: "This video isn’t available."
        case .restricted: "This video is restricted and can’t be played here."
        case .networkUnavailable: "You appear to be offline. Check your connection and try again."
        case .providerFailure: "Couldn’t load this video right now. Please try again."
        case .streamExpired: "The video link expired. Retrying…"
        case .unsupportedCodec: "This video’s format isn’t supported on this device."
        case .invalidManifest: "This video couldn’t be prepared for playback."
        case .playbackFailed: "Playback failed. Please try again."
        }
    }
}

public enum ProviderError: Error, Sendable, Equatable {
    case unsupported
    case notFound
    case restricted
    case unavailable
    case authenticationRequired
    case parsing(String)
}

extension PlaybackError {
    /// Maps any lower-level error into an application-level error.
    public init(_ error: any Error) {
        switch error {
        case let e as PlaybackError: self = e
        case let e as ProviderError:
            switch e {
            case .restricted, .authenticationRequired: self = .restricted
            case .notFound, .unavailable: self = .unavailable
            case .unsupported, .parsing: self = .providerFailure
            }
        case let e as HTTPError:
            switch e {
            case .status(let code) where code == 403 || code == 410: self = .streamExpired
            case .status(let code) where code == 404: self = .unavailable
            default: self = .providerFailure
            }
        case let e as URLError:
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                self = .networkUnavailable
            default: self = .providerFailure
            }
        default: self = .playbackFailed
        }
    }
}
