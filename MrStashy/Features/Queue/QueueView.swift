import SwiftUI

struct QueueView: View {
    @Environment(AppState.self) private var appState
    @State private var inspectedFailure: QueueFailure?

    private struct QueueFailure: Identifiable {
        let id: UUID
        let author: String
        let message: String
    }

    var body: some View {
        ZStack {
            StashyBackground()
            if appState.queueItems.isEmpty {
                VStack(spacing: 14) {
                    StashyIllustration(name: "stashyQueue", maxHeight: 230)
                    Label(L10n.value("queue.empty.title"), systemImage: "arrow.down.circle")
                        .font(.title3.weight(.bold))
                    Text(L10n.value("queue.empty.body"))
                        .font(.subheadline)
                        .foregroundStyle(StashyTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else {
                List(appState.queueItems) { item in
                    QueueRow(item: item) {
                        guard let message = item.stage.failureMessage else { return }
                        inspectedFailure = QueueFailure(id: item.id, author: item.post.author.displayName, message: message)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if appState.isQueueItemActive(item.id) {
                            Button(role: .destructive) { appState.cancelQueueItem(id: item.id) } label: {
                                Label(L10n.value("queue.cancel"), systemImage: "xmark")
                            }
                        } else {
                            // A finished row can be removed; a queue that only grows is a list.
                            Button(role: .destructive) { appState.removeQueueItem(id: item.id) } label: {
                                Label(L10n.value("queue.remove"), systemImage: "trash")
                            }
                            if item.stage.canRetry {
                                Button { appState.retryQueueItem(item) } label: {
                                    Label(L10n.value("queue.retry"), systemImage: "arrow.clockwise")
                                }
                                .tint(StashyTheme.aqua)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(L10n.value("tab.queue"))
        .toolbar {
            if appState.hasFinishedQueueItems {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.value("queue.clearFinished")) { appState.clearFinishedQueueItems() }
                        .accessibilityIdentifier("queue.clearFinished")
                }
            }
        }
        .alert(
            L10n.value("queue.stage.failed"),
            isPresented: Binding(get: { inspectedFailure != nil }, set: { if !$0 { inspectedFailure = nil } })
        ) {
            if let failure = inspectedFailure, let item = appState.queueItems.first(where: { $0.id == failure.id }) {
                Button(L10n.value("queue.retry")) {
                    appState.retryQueueItem(item)
                    inspectedFailure = nil
                }
            }
            Button(L10n.value("action.done"), role: .cancel) { inspectedFailure = nil }
        } message: {
            Text(inspectedFailure?.message ?? "")
        }
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let onInspectFailure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                PlatformIcon(platform: item.post.platform, size: 30)
                Text(item.post.author.displayName).font(.headline).lineLimit(1)
                Spacer()
                Text(L10n.value(item.stage.titleKey))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stageColor)
            }
            ProgressView(value: item.progress)
                .tint(stageColor)
            if let message = item.stage.failureMessage {
                // The reason is the useful part of a failure, so it gets its own line and a way
                // to read all of it instead of being squeezed into the status caption.
                Button(action: onInspectFailure) {
                    HStack(spacing: 6) {
                        Text(message).lineLimit(2).multilineTextAlignment(.leading)
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(StashyTheme.pink)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("queue.failureDetail")
            }
            HStack {
                Text(L10n.format("queue.itemCount", Int64(item.selectedMediaIDs.count)))
                Spacer()
                if let total = item.totalBytes {
                    Text(ByteCountFormatter.string(fromByteCount: item.bytesDownloaded, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                } else if item.bytesDownloaded > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: item.bytesDownloaded, countStyle: .file))
                }
            }
            .font(.caption).foregroundStyle(StashyTheme.inkSecondary)
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
                .foregroundStyle(StashyTheme.inkSecondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue.row")
    }

    private var stageColor: Color {
        switch item.stage {
        case .completed: StashyTheme.green
        case .failed, .cancelled: StashyTheme.pink
        default: StashyTheme.aqua
        }
    }
}
