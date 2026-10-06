import ITubeCore
import SwiftUI

/// The same playback session, presented compactly (ADR §36). Shows artwork rather than a second video surface.
struct MiniPlayerView: View {
    @Bindable var coordinator: PlaybackCoordinator

    var body: some View {
        if let video = coordinator.displayedVideo {
            HStack(spacing: 12) {
                ThumbnailView(url: video.thumbnail(forWidth: 160)?.url)
                    .aspectRatio(16 / 9, contentMode: .fit).frame(width: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let c = video.channel?.name { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Button { coordinator.togglePlayPause() } label: {
                    Image(systemName: coordinator.engine.state.isActivelyPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel(coordinator.engine.state.isActivelyPlaying ? "Pause" : "Play")
                Button { coordinator.closeSession() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close player")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture { coordinator.presentPlayer() }
            .accessibilityElement(children: .contain)
            .accessibilityHint("Double tap to open the player")
            .overlay(alignment: .top) {
                ProgressView(value: coordinator.engine.currentTime.totalSeconds, total: max(1, coordinator.engine.duration?.totalSeconds ?? 1))
                    .progressViewStyle(.linear).tint(.accentColor).frame(height: 2)
            }
        }
    }
}
