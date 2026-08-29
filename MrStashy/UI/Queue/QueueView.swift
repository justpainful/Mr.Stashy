import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.jobs.isEmpty {
                    EmptyNotice(symbol: "arrow.down.circle", text: L10n.value("queue.empty"), action: (L10n.value("library.goCatch"), { model.selectedTab = .catchTab }))
                        .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.jobs) { job in
                            JobRow(job: job)
                                .accessibilityIdentifier("queue.job.\(job.id.uuidString)")
                        }
                    }
                    .padding(16)
                }
            }
            .background(Theme.paper)
            .navigationTitle(L10n.value("tab.queue"))
            .navigationDestination(for: UUID.self) { id in ArchiveDetailView(archiveID: id) }
            .toolbar {
                if model.jobs.contains(where: { $0.stage.isFinished }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.value("queue.clearFinished")) { model.clearFinished() }
                    }
                }
            }
        }
    }
}

struct JobRow: View {
    var job: SaveJob
    @Environment(AppModel.self) private var model

    private var post: Post { job.request.post }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(post.title.flatMap { $0.isEmpty ? nil : $0 } ?? post.author.display.nonEmpty ?? L10n.value(post.platform.titleKey))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        PlatformGlyph(platform: post.platform, size: 18)
                        Text(L10n.plural("queue.itemCount", job.itemCount))
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                    stageLine
                }
                Spacer()
                controls
            }
            if !job.stage.isFinished {
                ProgressView(value: job.progress)
                    .tint(Theme.amber)
                SpecLine([bytesText, Format.speed(job.bytesPerSecond), etaText])
            } else if case .failed(let message) = job.stage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
            }
        }
        .padding(14)
        .card()
    }

    private var thumbnail: some View {
        RemoteThumbnail(url: post.items.first { job.request.selectedItemIDs.contains($0.id) }?.thumbnailURL ?? post.items.first?.thumbnailURL)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var stageLine: some View {
        HStack(spacing: 6) {
            switch job.stage {
            case .done:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.verified)
                Text(L10n.plural("queue.savedCount", job.savedCount))
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.warn)
                Text(L10n.value(job.stage.titleKey))
            case .cancelled:
                Image(systemName: "slash.circle").foregroundStyle(Theme.muted)
                Text(L10n.value(job.stage.titleKey))
            default:
                ProgressView().controlSize(.mini)
                Text(L10n.value(job.stage.titleKey))
                if job.itemCount > 1, job.stage == .downloading {
                    Text(L10n.format("queue.itemProgress", Int64(job.currentItem + 1), Int64(job.itemCount)))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
    }

    @ViewBuilder private var controls: some View {
        switch job.stage {
        case .done:
            if let archiveID = job.archiveID {
                NavigationLink(value: archiveID) {
                    Image(systemName: "chevron.forward").foregroundStyle(Theme.muted)
                }
                .accessibilityLabel(L10n.value("queue.open"))
            }
        case .failed, .cancelled:
            HStack(spacing: 14) {
                Button { model.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(L10n.value("common.retry"))
                Button(role: .destructive) { model.remove(job.id) } label: { Image(systemName: "trash").foregroundStyle(Theme.warn) }
                    .accessibilityLabel(L10n.value("common.delete"))
            }
        default:
            Button { model.cancel(job.id) } label: { Image(systemName: "xmark.circle").foregroundStyle(Theme.muted) }
                .accessibilityLabel(L10n.value("common.cancel"))
        }
    }

    private var bytesText: String? {
        guard job.bytesReceived > 0 else { return nil }
        if let expected = job.bytesExpected, expected > 0 {
            return "\(L10n.byteCount(job.bytesReceived)) / \(L10n.byteCount(expected))"
        }
        return L10n.byteCount(job.bytesReceived)
    }

    private var etaText: String? {
        guard let expected = job.bytesExpected, job.bytesPerSecond > 1024, expected > job.bytesReceived else { return nil }
        let seconds = Double(expected - job.bytesReceived) / job.bytesPerSecond
        guard seconds.isFinite, seconds < 36_000 else { return nil }
        return L10n.format("queue.eta", L10n.duration(seconds))
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
