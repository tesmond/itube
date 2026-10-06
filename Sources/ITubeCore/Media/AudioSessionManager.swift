import AVFoundation
import Foundation

/// Playback audio session, activated lazily when playback starts (ADR §14, §15).
@MainActor
public final class AudioSessionManager: AudioSessionControlling {
    public var onInterruptionBegan: (@MainActor () -> Void)?
    public var onInterruptionEnded: (@MainActor (_ shouldResume: Bool) -> Void)?
    /// Headphones/AirPods disconnected: system convention is to pause.
    public var onRouteBecameUnavailable: (@MainActor () -> Void)?
    public var onMediaServicesReset: (@MainActor () -> Void)?

    private let session: AVAudioSession
    private var tokens: [any NSObjectProtocol] = []
    private var isConfigured = false
    private var isActive = false

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        observe()
    }

    public func activate() {
        do {
            if !isConfigured {
                try session.setCategory(.playback, mode: .moviePlayback)
                isConfigured = true
            }
            if !isActive {
                try session.setActive(true)
                isActive = true
            }
        } catch {
            Log.audio.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func deactivate() {
        guard isActive else { return }
        do { try session.setActive(false, options: .notifyOthersOnDeactivation) } catch {
            Log.audio.error("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
        isActive = false
    }

    public func shutdown() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
    }

    private func observe() {
        let center = NotificationCenter.default
        // Delivered on the main queue, so `assumeIsolated` is valid; closures capture self weakly (no cycle).
        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    self.isActive = false
                    self.onInterruptionBegan?()
                case .ended:
                    let resume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
                    self.onInterruptionEnded?(resume)
                @unknown default: break
                }
            }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let reasonValue, AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }
                self.onRouteBecameUnavailable?()
            }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isConfigured = false; self.isActive = false
                self.onMediaServicesReset?()
            }
        })
    }
}
