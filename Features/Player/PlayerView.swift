import AVKit
import ITubeCore
import SwiftUI

/// The shared long-lived video view, hosted (not owned) by SwiftUI so PiP and playback survive navigation (ADR §7, §36).
struct PlayerSurface: UIViewRepresentable {
    let view: PlayerLayerView
    func makeUIView(context: Context) -> PlayerLayerView { view }
    func updateUIView(_ uiView: PlayerLayerView, context: Context) {}
}

struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        v.accessibilityLabel = "AirPlay"
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PlayerView: View {
    let app: AppEnvironment
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var controlsVisible = true
    @State private var showQueue = false
    @State private var showSleep = false

    private var engine: PlaybackEngine { coordinator.engine }
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if isLandscape { videoArea.ignoresSafeArea() }
            else {
                VStack(spacing: 0) {
                    videoArea.aspectRatio(16 / 9, contentMode: .fit)
                    DetailsPane(app: app)
                }
            }
        }
        .background(isLandscape ? Color.black : Color(.systemBackground))
        .statusBarHidden(isLandscape)
        .sheet(isPresented: $showQueue) { QueueView() }
        .onDisappear { OrientationController.rotate(toLandscape: false) }
    }

    // MARK: Video + controls

    private var videoArea: some View {
        ZStack {
            Color.black
            PlayerSurface(view: coordinator.videoView)
                .accessibilityHidden(true)
            if let text = coordinator.subtitles.currentText {
                Text(text)
                    .font(.callout.weight(.medium)).multilineTextAlignment(.center)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, controlsVisible ? 64 : 16)
                    .allowsHitTesting(false)
            }
            statusOverlay
            if controlsVisible { PlayerControls(coordinator: coordinator, showQueue: $showQueue, isLandscape: isLandscape, onClose: { coordinator.dismissPlayer() }) }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() } }
        // Auto-hide: one cancellable sleeping task, restarted whenever inputs change — no repeating timer (ADR §57).
        .task(id: AutoHideKey(visible: controlsVisible, playing: engine.state == .playing)) {
            guard controlsVisible, engine.state == .playing else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { withAnimation { controlsVisible = false } }
        }
    }

    private struct AutoHideKey: Equatable { let visible: Bool; let playing: Bool }

    @ViewBuilder private var statusOverlay: some View {
        switch engine.state {
        case .resolving, .loading, .buffering:
            ProgressView().controlSize(.large).tint(.white)
        case .failed(let error):
            VStack(spacing: 8) {
                Text(error.userMessage).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                if let video = coordinator.displayedVideo {
                    Button("Try Again") { coordinator.play(video, present: false) }.buttonStyle(.borderedProminent)
                }
            }.padding()
        default: EmptyView()
        }
    }
}

// MARK: Controls

struct PlayerControls: View {
    @Bindable var coordinator: PlaybackCoordinator
    @Binding var showQueue: Bool
    let isLandscape: Bool
    var onClose: () -> Void
    @State private var scrubValue: Double?
    @Environment(SettingsManager.self) private var settings

    private var engine: PlaybackEngine { coordinator.engine }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            VStack {
                topBar
                Spacer()
                centerButtons
                Spacer()
                bottomBar
            }
            .padding(12)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            control("chevron.down", label: "Minimise player", action: onClose)
            Spacer()
            if coordinator.pip.isSupported {
                control("pip.enter", label: "Picture in Picture") { coordinator.pip.startPiP() }
                    .disabled(!coordinator.pip.isPossible)
            }
            RoutePickerView().frame(width: 32, height: 32)
            menu
        }
    }

    private var centerButtons: some View {
        HStack(spacing: 40) {
            control("backward.end.fill", label: "Previous video") { coordinator.previous() }
            control("gobackward.15", label: "Back 15 seconds", size: 30) { Task { await engine.seek(by: .seconds(-15)) } }
            control(engine.state.isActivelyPlaying ? "pause.fill" : "play.fill",
                    label: engine.state.isActivelyPlaying ? "Pause" : "Play", size: 44) { coordinator.togglePlayPause() }
            control("goforward.15", label: "Forward 15 seconds", size: 30) { Task { await engine.seek(by: .seconds(15)) } }
            control("forward.end.fill", label: "Next video") { coordinator.next() }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { scrubValue ?? engine.currentTime.totalSeconds }, set: { scrubValue = $0 }),
                in: 0...max(1, engine.duration?.totalSeconds ?? 1),
                onEditingChanged: { editing in
                if !editing, let v = scrubValue {
                    scrubValue = nil
                    Task { await engine.seek(to: Duration(seconds: v)) }
                }
            })
            .tint(.white)
            .accessibilityLabel("Timeline")
            .accessibilityValue("\(engine.currentTime.clockString) of \(engine.duration?.clockString ?? "unknown")")
            HStack {
                Text(Duration(seconds: scrubValue ?? engine.currentTime.totalSeconds).clockString)
                Spacer()
                if let d = engine.duration {
                    let remaining = max(0, d.totalSeconds - (scrubValue ?? engine.currentTime.totalSeconds))
                    Text("-" + Duration(seconds: remaining).clockString)
                }
                control(isLandscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label: isLandscape ? "Exit full screen" : "Full screen", size: 16) {
                    OrientationController.rotate(toLandscape: !isLandscape)
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    private var menu: some View {
        Menu {
            Menu("Quality (\(engine.quality.title))", systemImage: "slider.horizontal.3") {
                Picker("Quality", selection: Binding(get: { engine.quality }, set: { q in Task { await engine.setQuality(q) } })) {
                    ForEach(engine.availableQualities) { Text($0.title).tag($0) }
                }
            }
            Menu("Speed (\(String(format: "%g×", engine.rate)))", systemImage: "speedometer") {
                Picker("Speed", selection: Binding(get: { engine.rate }, set: { engine.setRate($0) })) {
                    ForEach(PlaybackEngine.supportedRates, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
            }
            captionsMenu
            Menu("Sleep Timer", systemImage: "moon.zzz") {
                ForEach(SleepTimerOption.all) { o in Button(o.title) { coordinator.sleepTimer.start(o) } }
                if coordinator.sleepTimer.option != nil { Button("Cancel Timer", role: .destructive) { coordinator.sleepTimer.cancel() } }
            }
            Toggle("Loop", systemImage: "repeat.1", isOn: Binding(get: { engine.isLooping }, set: { engine.setLooping($0) }))
            Button("Queue", systemImage: "list.bullet") { showQueue = true }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).frame(width: 32, height: 32)
        }
        .accessibilityLabel("More options")
    }

    @ViewBuilder private var captionsMenu: some View {
        let subs = coordinator.subtitles
        Menu("Captions", systemImage: "captions.bubble") {
            Button("Off") { subs.disable(); settings.settings.captionsEnabled = false }
            ForEach(subs.tracks) { t in
                Button(t.displayName + (t.isAutoGenerated ? " (auto)" : "")) {
                    settings.settings.captionsEnabled = true; settings.settings.captionLanguage = t.languageCode
                    Task { await subs.select(track: t) }
                }
            }
            ForEach(subs.nativeOptions) { o in Button(o.name) { subs.selectNative(id: o.id) } }
            if let base = subs.tracks.first(where: { !$0.isTranslation }), !subs.translations.isEmpty {
                Menu("Translate") {
                    ForEach(subs.translations.prefix(40)) { l in Button(l.name) { Task { await subs.select(translation: l, of: base) } } }
                }
            }
        }
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 22, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(minWidth: 44, minHeight: 44)   // 44pt hit target
        }
        .accessibilityLabel(label)
    }
}

// MARK: Details

struct DetailsPane: View {
    let app: AppEnvironment
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.libraryStore) private var library
    @State private var bookmarked = false
    @State private var showFullDescription = false

    var body: some View {
        let video = coordinator.displayedVideo
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let video {
                    Text(video.title).font(.headline)
                    HStack {
                        if let channel = video.channel { Text(channel.name).font(.subheadline.weight(.semibold)) }
                        Spacer()
                        Button(bookmarked ? "Bookmarked" : "Bookmark", systemImage: bookmarked ? "bookmark.fill" : "bookmark") {
                            bookmarked.toggle()
                            Task { await library?.setBookmark(video, bookmarked: bookmarked) }
                        }.labelStyle(.iconOnly)
                    }
                }
                if let d = coordinator.details, !d.description.isEmpty {
                    Text(d.description).font(.footnote).foregroundStyle(.secondary).lineLimit(showFullDescription ? nil : 3)
                        .onTapGesture { showFullDescription.toggle() }
                        .accessibilityAddTraits(.isButton)
                }
                if let related = coordinator.details?.related, !related.isEmpty {
                    Text("Up Next").font(.title3.bold()).padding(.top, 8).accessibilityAddTraits(.isHeader)
                    ForEach(related.prefix(25)) { v in
                        VideoRow(video: v) { coordinator.play(v, upcoming: Array(related.drop { $0.id != v.id }.dropFirst()), present: false) }
                    }
                }
            }
            .padding(16)
        }
        .task(id: video?.id) {
            if let id = video?.id { bookmarked = await library?.isBookmarked(id) ?? false }
        }
    }
}

struct QueueView: View {
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = coordinator.queue.queue.current {
                    Section("Now Playing") { Text(current.title).lineLimit(2) }
                }
                Section("Up Next") {
                    ForEach(coordinator.queue.queue.upcoming) { v in
                        VideoRow(video: v) {
                            coordinator.play(v, upcoming: Array(coordinator.queue.queue.upcoming.drop { $0.id != v.id }.dropFirst()), present: false)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { coordinator.queue.queue.upcoming[$0].id }
                        ids.forEach(coordinator.queue.remove)
                    }
                    .onMove { coordinator.queue.move(from: $0, to: $1) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .overlay { if coordinator.queue.queue.upcoming.isEmpty { ContentUnavailableView("Queue is empty", systemImage: "list.bullet", description: Text("Long-press a video and choose Add to Queue.")) } }
        }
        .presentationDetents([.medium, .large])
    }
}
