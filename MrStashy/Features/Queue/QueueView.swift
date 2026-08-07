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
                Label {
                    Text(L10n.value(stageTitleKey))
                } icon: {
                    // Colour alone cannot carry the difference between finished, failed, and
                    // working: a symbol says it for anyone who cannot separate the hues.
                    Image(systemName: stageSymbol)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(stageTextColor)
                .labelStyle(.titleAndIcon)
            }
            ProgressView(value: item.progress)
                .tint(stageFillColor)
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
                // The count is what actually landed in the archive once the save has finished.
                // Printing the number of items that were *requested* labelled a partial capture
                // as a complete one, with nothing left on the row to say otherwise.
                Text(L10n.format("queue.itemCount", Int64(savedOrRequestedCount)))
                Spacer()
                if let total = item.totalBytes {
                    Text(L10n.format("queue.bytesProgress", L10n.byteCount(item.bytesDownloaded), L10n.byteCount(total)))
                } else if item.bytesDownloaded > 0 {
                    Text(L10n.byteCount(item.bytesDownloaded))
                }
            }
            .font(.caption).foregroundStyle(StashyTheme.inkSecondary)
            if isPartial {
                Label(
                    L10n.format("queue.partial", Int64(savedOrRequestedCount), Int64(item.selectedMediaIDs.count)),
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(StashyTheme.butterText)
                .accessibilityIdentifier("queue.partial")
            }
            if item.bytesPerSecond > 0 || item.estimatedTimeRemaining != nil {
                HStack(spacing: 12) {
                    if item.bytesPerSecond > 0 {
                        Label(L10n.format("queue.speed", L10n.byteCount(Int64(item.bytesPerSecond))), systemImage: "speedometer")
                    }
                    if let remaining = item.estimatedTimeRemaining {
                        Label(L10n.format("queue.eta", L10n.duration(remaining)), systemImage: "clock")
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

    private var savedOrRequestedCount: Int {
        item.savedMediaCount ?? item.selectedMediaIDs.count
    }

    /// A finished save that kept fewer items than were asked for. Comparing counts is what makes
    /// this reliable: a resolver warning can ride along on a capture that saved everything.
    private var isPartial: Bool {
        guard case .completed = item.stage, let saved = item.savedMediaCount else { return false }
        return saved < item.selectedMediaIDs.count
    }

    private var stageTitleKey: String {
        isPartial ? "queue.stage.completedPartially" : item.stage.titleKey
    }

    private var stageSymbol: String {
        if isPartial { return "exclamationmark.circle.fill" }
        switch item.stage {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle.fill"
        default: return "arrow.down.circle"
        }
    }

    /// Text and fills need different values of the same semantic colour: the palette's aqua and
    /// indigo are readable as a bar but far below the contrast floor as a 12pt caption.
    private var stageTextColor: Color {
        if isPartial { return StashyTheme.butterText }
        switch item.stage {
        case .completed: return StashyTheme.greenText
        case .failed, .cancelled: return StashyTheme.pink
        default: return StashyTheme.aquaText
        }
    }

    private var stageFillColor: Color {
        switch item.stage {
        case .completed: StashyTheme.green
        case .failed, .cancelled: StashyTheme.pink
        default: StashyTheme.aqua
        }
    }
}
