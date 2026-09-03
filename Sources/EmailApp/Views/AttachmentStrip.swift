import SwiftUI
// `quickLookPreview` is QuickLook's own SwiftUI modifier, not one of
// SwiftUI's, and it does not resolve without this.
import QuickLook

/// The files that came with a message.
///
/// A row each, not a grid of thumbnails: the useful facts about an
/// attachment are its name and how big it is, and a wall of grey document
/// icons tells you neither. Tapping one downloads it and opens it in the
/// system's own previewer, which already knows how to draw a PDF, a
/// spreadsheet and a photo better than this app ever will.
struct AttachmentStrip: View {
    let attachments: [Attachment]

    @Environment(AttachmentStore.self) private var store
    @Environment(MailStore.self) private var mail

    @State private var previewing: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(attachments) { attachment in
                Button {
                    open(attachment)
                } label: {
                    row(for: attachment)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    ShareLink(item: store.location(of: attachment)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!store.isDownloaded(attachment))
                }
            }
        }
        .quickLookPreview($previewing)
    }

    @ViewBuilder
    private func row(for attachment: Attachment) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: 38, height: 38)

                if store.isWorking(on: attachment) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: attachment.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let failure = store.failure(for: attachment) {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(detail(for: attachment))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: store.isDownloaded(attachment) ? "eye" : "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
        .contentShape(Rectangle())
    }

    private func detail(for attachment: Attachment) -> String {
        let size = attachment.sizeDescription
        if store.isDownloaded(attachment) {
            return size.isEmpty ? "Ready" : "\(size) · ready"
        }
        return size.isEmpty ? "Tap to download" : "\(size) · tap to download"
    }

    private func open(_ attachment: Attachment) {
        Task {
            if let url = await store.file(for: attachment, in: mail.account) {
                previewing = url
            }
        }
    }
}
