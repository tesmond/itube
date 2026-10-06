import ITubeCore
import SwiftUI

struct HistoryView: View {
    let app: AppEnvironment
    @State private var entries: [HistoryEntry] = []
    @Environment(PlaybackCoordinator.self) private var coordinator

    var body: some View {
        List {
            ForEach(entries) { e in
                VideoRow(video: e.video) { coordinator.play(e.video) }
                    .swipeActions { Button("Remove", role: .destructive) { Task { await app.historyStore.remove(videoID: e.id); await reload() } } }
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
        .toolbar { if !entries.isEmpty { Button("Clear", role: .destructive) { Task { await app.historyStore.clearHistory(); await reload() } } } }
        .overlay { if entries.isEmpty { ContentUnavailableView("No history", systemImage: "clock", description: Text("Videos you watch appear here. History stays on this device.")) } }
        .task { await reload() }
    }

    private func reload() async { entries = await app.historyStore.recent(limit: 200) }
}
