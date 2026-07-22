import SwiftUI

struct QueueView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            StashyBackground()
            if appState.queueItems.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "queue.empty.title"), systemImage: "arrow.down.circle")
                } description: { Text(String(localized: "queue.empty.body")) }
                .overlay(alignment: .bottom) { IllustrationSlot(placement: .emptyState, height: 110).frame(width: 160).offset(y: 92) }
            } else {
                List(appState.queueItems) { item in
                    QueueRow(item: item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if appState.isQueueItemActive(item.id) {
                                Button(role: .destructive) { appState.cancelQueueItem(id: item.id) } label: {
                                    Label(String(localized: "queue.cancel"), systemImage: "xmark")
                                }
                            } else if item.stage.canRetry {
                                Button { appState.retryQueueItem(item) } label: {
                                    Label(String(localized: "queue.retry"), systemImage: "arrow.clockwise")
                                }
                                .tint(StashyTheme.aqua)
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(String(localized: "tab.queue"))
    }
}

private struct QueueRow: View {
    let item: QueueItem
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(item.post.author.displayName).font(.headline)
                Spacer()
                Text(stageText).font(.caption.weight(.semibold)).foregroundStyle(stageColor)
            }
            ProgressView(value: item.progress)
                .tint(stageColor)
            HStack {
                Text(L10n.format("queue.itemCount", Int64(item.selectedMediaIDs.count)))
                Spacer()
                if let total = item.totalBytes { Text(ByteCountFormatter.string(fromByteCount: item.bytesDownloaded, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if item.bytesPerSecond > 0 || item.estimatedTimeRemaining != nil {
                HStack(spacing: 12) {
                    if item.bytesPerSecond > 0 {
                        Label(L10n.format("queue.speed", ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file)), systemImage: "speedometer")
                    }
                    if let remaining = item.estimatedTimeRemaining {
                        Label(L10n.format("queue.eta", Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))), systemImage: "clock")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
    private var stageText: String {
        switch item.stage {
        case .failed(let message): message
        default: L10n.value(item.stage.titleKey)
        }
    }
    private var stageColor: Color {
        switch item.stage {
        case .completed: StashyTheme.green
        case .failed, .cancelled: StashyTheme.pink
        default: StashyTheme.aqua
        }
    }
}

private extension QueueItem.Stage {
    var canRetry: Bool {
        switch self {
        case .failed, .cancelled: true
        default: false
        }
    }
}
