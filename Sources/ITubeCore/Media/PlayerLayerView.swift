import AVFoundation
import UIKit

/// A single long-lived video view. SwiftUI re-parents it (full player ↔ mini player) so the `AVPlayerLayer`
/// — and therefore the PiP controller — outlives every screen (ADR §36, §79).
public final class PlayerLayerView: UIView {
    public override class var layerClass: AnyClass { AVPlayerLayer.self }
    public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Detaching the player while backgrounded (and not in PiP) lets audio continue without video decoding (ADR §14, §57).
    @MainActor public func setPlayer(_ player: AVPlayer?, attached: Bool) {
        let target = attached ? player : nil
        if playerLayer.player !== target { playerLayer.player = target }
    }
}
