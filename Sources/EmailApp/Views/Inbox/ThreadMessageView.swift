import SwiftUI
import UIKit

/// One message inside a conversation.
///
/// Everything that used to be the whole reading screen lives here now: the
/// sender, the warning when their name and address disagree, the pictures
/// notice, the body and the attachments. A thread is a stack of these, and a
/// message on its own is a stack of one -- so there is a single description
/// of what a message looks like rather than two that drift apart.
struct ThreadMessageView: View {
    let message: Message
    /// Whether the body is shown. Older messages in a thread are a header
    /// until somebody asks for them.
    let isExpanded: Bool
    /// The last one in the conversation draws no divider under it.
    var isLast = true
    var onToggle: () -> Void
    var onLink: (URL) -> Void

    @State private var htmlHeight: CGFloat = 0
    /// Pictures for this message, this reading. Deliberately not remembered:
    /// saying yes once is not the same as trusting a sender, and the
    /// sender-level answer has its own item in the same menu.
    @State private var showsImages = false
    @State private var warning: SenderScrutiny.Warning?
    @State private var isShowingWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                if let warning { warningCard(warning) }

                if let html = message.htmlBody, !showsImages,
                   HTMLMessageView.wantsRemoteContent(html) {
                    imagesBlockedBar
                }

                body(for: message)

                // Under the message, not above it. What was sent matters
                // before what came with it, and a deck of five files pushing
                // the actual words off the screen gets the priority backwards.
                if !message.attachments.isEmpty {
                    AttachmentStrip(attachments: message.attachments)
                        .padding(.top, 4)
                }
            }

            if !isLast { Divider() }
        }
        .onAppear {
            showsImages = AppSettings.loadsRemoteImages
                || PersonPreferences.showsImages(from: message.sender.address)
            warning = SenderScrutiny.check(message.sender)
        }
        .alert(warning?.headline ?? "", isPresented: $isShowingWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            if let warning { Text(warning.detail) }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                SenderAvatar(contact: message.sender, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if warning != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.urgent)
                        }
                    }

                    if isExpanded {
                        // 🔴 Was grey fine print under a name anybody can
                        // type. The address is the part that cannot be
                        // forged into looking like somebody else.
                        Text(message.sender.address)
                            .font(.footnote)
                            .foregroundStyle(warning == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.urgent))
                            .lineLimit(1)
                            .textSelection(.enabled)
                    } else {
                        // Collapsed: the first line of what they said, which
                        // is what tells somebody whether to open it.
                        Text(message.preview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(isExpanded ? message.fullDate : message.listDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if message.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Collapses this message" : "Opens this message")
    }

    private var displayName: String {
        message.sender.name.isEmpty ? message.sender.address : message.sender.name
    }

    // MARK: - Pictures

    private var imagesBlockedBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pictures not loaded")
                    .font(.footnote.weight(.semibold))
                Text("Loading them tells the sender you opened this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Menu {
                Button("Show pictures") {
                    withAnimation(.easeOut(duration: 0.2)) { showsImages = true }
                }
                Button("Always from this sender") {
                    PersonPreferences.setShowsImages(true, for: message.sender.address)
                    withAnimation(.easeOut(duration: 0.2)) { showsImages = true }
                }
            } label: {
                Text("Show")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08))
        }
    }

    // MARK: - Who sent it

    private func warningCard(_ warning: SenderScrutiny.Warning) -> some View {
        Button {
            isShowingWarning = true
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.urgent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.headline)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(warning.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12).fill(Color.urgent.opacity(0.10))
            }
        }
        .buttonStyle(.plain)
        // Not colour alone: the symbol, the words and the label carry it too.
        .accessibilityLabel("Warning. \(warning.headline). \(warning.detail)")
    }

    // MARK: - The message itself

    @ViewBuilder
    private func body(for message: Message) -> some View {
        if let html = message.htmlBody, !html.isEmpty {
            ZStack(alignment: .top) {
                // The skeleton holds the space until the web view reports a
                // height, so the message does not appear as an empty gap.
                if htmlHeight == 0 { MessageSkeleton() }

                HTMLMessageView(
                    html: html,
                    height: $htmlHeight,
                    loadsRemoteContent: showsImages,
                    onLink: onLink
                )
                .frame(height: max(htmlHeight, 1))
                .opacity(htmlHeight == 0 ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.25), value: htmlHeight == 0)
        } else if message.body.isEmpty {
            MessageSkeleton()
        } else {
            // A real text view, so a line of the message can be selected and
            // copied on its own rather than the whole body at once.
            SelectableText(message.body, font: .preferredFont(forTextStyle: .body))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
