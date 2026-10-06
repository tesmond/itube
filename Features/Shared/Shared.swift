import ITubeCore
import SwiftUI

// MARK: Environment

private struct ImageLoaderKey: EnvironmentKey { static let defaultValue: ImageLoader? = nil }
private struct LibraryStoreKey: EnvironmentKey { static let defaultValue: (any LibraryStoring)? = nil }

extension EnvironmentValues {
    var imageLoader: ImageLoader? {
        get { self[ImageLoaderKey.self] }
        set { self[ImageLoaderKey.self] = newValue }
    }
    var libraryStore: (any LibraryStoring)? {
        get { self[LibraryStoreKey.self] }
        set { self[LibraryStoreKey.self] = newValue }
    }
}

// MARK: Thumbnail

/// Loads asynchronously, downsampled to its on-screen size, cached; the task is cancelled when scrolled away (ADR §40, §42).
struct ThumbnailView: View {
    let url: URL?
    @Environment(\.imageLoader) private var loader
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: url) { await load(width: geo.size.width) }
        }
        .accessibilityHidden(true)
    }

    private func load(width: CGFloat) async {
        image = nil
        guard let url, let loader, width > 0 else { return }
        image = try? await loader.image(for: url, maxPixelSize: width * scale)
    }
}

// MARK: Rows

struct VideoRow: View {
    let video: Video
    var onPlay: () -> Void
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.libraryStore) private var library

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                ThumbnailView(url: video.thumbnail(forWidth: 320)?.url)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(width: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        if let d = video.duration {
                            Text(d.clockString)
                                .font(.caption2.monospacedDigit().bold())
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
                                .padding(4)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(3).multilineTextAlignment(.leading)
                    if let channel = video.channel?.name, !channel.isEmpty {
                        Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let meta = Formatters.meta(video) {
                        Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays this video")
        .contextMenu {
            Button("Play Next", systemImage: "text.insert") { coordinator.queue.playNext(video) }
            Button("Add to Queue", systemImage: "text.badge.plus") { coordinator.queue.enqueue(video) }
            Button("Bookmark", systemImage: "bookmark") { Task { await library?.setBookmark(video, bookmarked: true) } }
        }
    }
}

enum Formatters {
    static func meta(_ v: Video) -> String? {
        var parts: [String] = []
        if let views = v.viewCount { parts.append(views.formatted(.number.notation(.compactName)) + " views") }
        if let when = v.publishedText { parts.append(when) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func time(_ d: Duration) -> String { d.clockString }
}

struct ErrorStateView: View {
    let title: String
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry { Button("Try Again", action: retry) }
        }
    }
}
