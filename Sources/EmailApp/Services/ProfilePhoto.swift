import SwiftUI
import UIKit

/// The picture somebody chose for themselves.
///
/// A file rather than a field on `AppAccount`, because `AppAccount` is
/// JSON-encoded into `UserDefaults` and an image in `UserDefaults` is a
/// megabyte of base64 read into memory on every launch, whether or not
/// anything is going to draw it.
///
/// Account-wide, not per-mailbox: it belongs to the person, the same way
/// `AIMemory` and the onboarding answers do. Signing out removes it; adding or
/// dropping a mailbox does not.
///
/// `@MainActor` rather than lock-guarded like `AIUsage` and
/// `PersonPreferences`, and the reason is `UIImage`: it is not `Sendable`, so
/// it cannot go inside `Guarded` at all -- `OSAllocatedUnfairLock` requires
/// its state to be. Nothing here is read off the main actor anyway. Only views
/// draw a face.
@MainActor
enum ProfilePhoto {

    /// Bumped when the picture changes, so views redraw. A file on disk is
    /// not something SwiftUI can observe.
    static let changed = Notification.Name("maily.profilePhotoChanged")

    /// The longest edge, in pixels.
    ///
    /// A modern phone camera hands over something like 4000×3000. Drawn at
    /// 56 points it would be decoded at full size on every appearance for no
    /// visible gain -- and it is written to disk, read back, and one day
    /// uploaded. 512 is comfortably more than a circle this size will ever
    /// resolve.
    private static let longestEdge: CGFloat = 512

    private static var url: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }

        let folder = base.appendingPathComponent("Maily", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("profile.jpg")
    }

    // MARK: - Reading

    /// Cached, because the You header draws this on every redraw and a disk
    /// read per frame is a scroll that stutters.
    ///
    /// Double optional on purpose: the outer one is "have we looked yet", the
    /// inner one is "was there a picture". Collapsing them would mean going
    /// back to disk on every draw for somebody who has not set one.
    private static var cache: UIImage??

    static var image: UIImage? {
        if let cached = cache { return cached }

        let loaded = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(UIImage.init(data:))

        cache = .some(loaded)
        return loaded
    }

    /// The stored bytes, for the settings sync.
    ///
    /// Read from disk rather than re-encoded from `image`: the file is already
    /// the scaled JPEG, and encoding it again would cost a second compression
    /// pass and produce something slightly different every call.
    static var data: Data? {
        url.flatMap { try? Data(contentsOf: $0) }
    }

    // MARK: - Writing

    /// Takes a picture that came from another device, already encoded.
    ///
    /// Skips the scaling in `set` -- these bytes went through it on whichever
    /// phone chose the picture, and rescaling a 512px JPEG only loses to it.
    @discardableResult
    static func adopt(_ data: Data) -> Bool {
        guard let url, UIImage(data: data) != nil else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            cache = .some(UIImage(data: data))
            NotificationCenter.default.post(name: changed, object: nil)
            return true
        } catch {
            return false
        }
    }

    /// Scales, encodes and stores. Returns false if any of that failed, so the
    /// screen can say so rather than showing the old picture and implying the
    /// new one took.
    @discardableResult
    static func set(_ image: UIImage) -> Bool {
        guard let url, let data = jpeg(from: image) else { return false }

        do {
            // Complete protection: this is a face, and it is one of the few
            // files here that is obviously a person.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            cache = .some(UIImage(data: data))
            NotificationCenter.default.post(name: changed, object: nil)
            // The picture is part of the profile, and choosing one is an
            // edit whether or not Save is pressed afterwards.
            SettingsSync.notify(.profile)
            return true
        } catch {
            return false
        }
    }

    static func remove() {
        if let url { try? FileManager.default.removeItem(at: url) }
        cache = .some(nil)
        NotificationCenter.default.post(name: changed, object: nil)
        SettingsSync.notify(.profile)
    }

    /// Signing out takes the picture with it, the same as the memories and the
    /// answers.
    static func clearAll() { remove() }

    // MARK: - Encoding

    private static func jpeg(from image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }

        let scale = min(1, longestEdge / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat.default()
            // The source may be @3x already; rendering at 1x here means the
            // pixel dimensions are the ones asked for rather than three times
            // them.
            format.scale = 1
            return format
        }())

        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.85)
    }
}

/// The person's own face, wherever it is drawn.
///
/// Three answers in a deliberate order, and the order is the whole design:
///
///   1. **A picture they chose.** Somebody who went to Edit profile and picked
///      a photo meant it, and nothing may quietly replace it.
///   2. **The one their provider holds.** Signing in with Google hands this
///      over with the same `profile` scope that supplies the name -- it was
///      always there and was being thrown away, so the header drew a coloured
///      letter beside a name taken from the very same object.
///   3. **A coloured letter**, via `SenderAvatar`, which already knows how.
///
/// Apple and email sign-in have no picture to give, so step 2 is genuinely
/// absent for most people and step 3 is not a failure state.
struct ProfileAvatar: View {
    let contact: Contact
    var size: CGFloat = 56
    /// The provider's picture, and a stable key to file it under. Nil for a
    /// screen that has no account to hand, which then behaves exactly as
    /// before.
    var photoURL: URL? = nil
    var photoKey: String? = nil

    // Loaded in `onAppear` rather than as a default value: a property
    // initialiser is not main-actor isolated, and `ProfilePhoto` is.
    @State private var image: UIImage?

    private var store: AvatarStore { .shared }

    var body: some View {
        // Observed, so the header redraws when the download lands.
        let _ = store.generation
        let provided = photoKey.flatMap { store.image(for: $0) }

        Group {
            if let chosen = image ?? provided {
                Image(uiImage: chosen)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                // No brand lookup: this is a person, and their own email
                // domain's logo is not their face.
                SenderAvatar(contact: contact, size: size, allowsBrandIcon: false)
            }
        }
        .onAppear {
            image = ProfilePhoto.image
            if let photoKey { store.ensure(key: photoKey, url: photoURL) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfilePhoto.changed)) { _ in
            image = ProfilePhoto.image
        }
    }
}
