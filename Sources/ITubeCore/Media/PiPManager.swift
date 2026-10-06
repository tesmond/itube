import AVFoundation
import AVKit
import Foundation
import Observation

/// Isolates AVKit's Picture in Picture lifecycle (ADR §11–13). The rest of the app never touches
/// `AVPictureInPictureController`. The controller is retained strongly for as long as PiP may be used.
@MainActor @Observable
public final class PiPManager: NSObject {
    public private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    public private(set) var isPossible = false
    public private(set) var isActive = false

    public var automaticallyStartsFromInline = true {
        didSet { controller?.canStartPictureInPictureAutomaticallyFromInline = automaticallyStartsFromInline }
    }
    /// Called when the user taps "restore" in the PiP window; the app should present the full player.
    @ObservationIgnored public var onRestoreUserInterface: (@MainActor () -> Void)?
    @ObservationIgnored public var onStateChange: (@MainActor () -> Void)?
    @ObservationIgnored public var onFailure: (@MainActor (any Error) -> Void)?

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?

    /// Must be given the long-lived layer, not one owned by a transient SwiftUI view.
    public func attach(layer: AVPlayerLayer) {
        guard isSupported else { return }
        if controller?.playerLayer === layer { return }
        teardown()
        guard let c = AVPictureInPictureController(playerLayer: layer) else { return }
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = automaticallyStartsFromInline
        controller = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.isPossible = possible
                self?.onStateChange?()
            }
        }
    }

    public func startPiP() {
        guard let controller, controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    public func stopPiP() { controller?.stopPictureInPicture() }

    public func teardown() {
        possibleObservation?.invalidate(); possibleObservation = nil
        controller?.delegate = nil
        controller = nil
        isPossible = false; isActive = false
    }
}

extension PiPManager: @preconcurrency AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = true; onStateChange?()
    }
    public func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        isActive = false; onStateChange?()
    }
    public func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        Log.pip.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
        isActive = false; onFailure?(error); onStateChange?()
    }
    public func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        onRestoreUserInterface?()
        completion(true)
    }
}
