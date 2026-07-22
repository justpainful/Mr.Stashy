import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        Task { @MainActor in
            let urls = await extractURLs()
            PendingShareStore.enqueue(urls)
            guard let extensionContext,
                  let deepLink = URL(string: "stashy://catch")
            else { return }
            extensionContext.open(deepLink) { _ in
                extensionContext.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    override func configurationItems() -> [Any]! { [] }

    private func extractURLs() async -> [URL] {
        let attachments = extensionContext?.inputItems.compactMap { ($0 as? NSExtensionItem)?.attachments }.flatMap { $0 } ?? []
        var results: [URL] = []
        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) as? URL { results.append(url) }
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) as? String {
                results.append(contentsOf: text.split(whereSeparator: { $0.isWhitespace }).compactMap { URL(string: String($0)) })
            }
        }
        return Array(Dictionary(grouping: results, by: URLCanonicalForm.string).compactMap { $0.value.first })
    }
}
