import SwiftUI
import UIKit

/// Profile pictures fetched from a provider, kept as files.
///
/// Every account avatar in the app goes through here: the You header, the
/// mailbox list, the switcher, the row on the inbox. That means it is asked
/// the same question many times per scroll, and the answer has to be a memory
/// read rather than a network call or a disk read.
///
/// ## Why not `AsyncImage`
///
/// The same reason `BrandIcon` is not, plus one more. `AsyncImage` refetches
/// on every appearance, so a list of four mailboxes scrolling in and out is
/// four downloads a second. And it has nothing to show on a cold launch in a
/// tunnel -- the picture is already on the phone, and a person's own face
/// going missing because the train went underground is not a trade worth
/// making.
///
/// So: bytes on disk under Application Support, decoded once into memory,
/// re-fetched only when the copy is old.
///
/// ⚠️ Keyed by the *account*, not by the URL. Google's picture URLs change
/// when somebody changes their photo, and keying on the URL would leave the
/// old file on disk forever and show it until the new one arrived.
@MainActor
@Observable
final class AvatarStore {

    /// One store, because the cache is the point. Several would each hold
    /// their own copy of the same four images.
    static let shared = AvatarStore()

    /// Bumped when any picture lands, so views that drew a letter redraw with
    /// the face. Views observe the store rather than a notification: an
    /// `@Observable` read inside `body` is the whole subscription.
    private(set) var generation = 0

    // 🔴 All three are `@ObservationIgnored`, and `generation` is the only
    // observed thing here.
    //
    // `image(for:)` fills the memory cache *during* a `View` body -- that is
    // the whole point of it being cheap enough to call from one. If SwiftUI
    // were tracking `memory`, writing it inside a body would invalidate the
    // view that is currently drawing, which redraws, which fills the cache
    // again: a loop that never settles. One deliberate signal out, and the
    // caches stay private.
    @ObservationIgnored private var memory: [String: UIImage] = [:]
    /// Keys already being fetched. Without this, four rows appearing together
    /// start four downloads of the same picture.
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Keys that have been looked at this launch, so a miss is not retried on
    /// every single redraw.
    @ObservationIgnored private var checked: Set<String> = []

    /// How old a stored picture may be before it is fetched again.
    ///
    /// A week. Somebody changing their Google photo and seeing the old one for
    /// a few days is a small wrong; re-downloading four faces on every launch
    /// forever is a steady cost for nothing.
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private init() {}

    // MARK: - Reading

    /// The picture for a key, if it is already in hand.
    ///
    /// Never asks the network. A `View` body must be able to call this, and a
    /// body that starts work is a body that starts it again on every redraw.
    func image(for key: String) -> UIImage? {
        if let held = memory[key] { return held }
        guard let url = Self.file(for: key),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)
        else { return nil }
        memory[key] = image
        return image
    }

    /// Whether a picture reaches its own edges -- an app icon, a BIMI mark,
    /// a photograph -- or is a glyph floating on transparency. That decides
    /// whether `SenderAvatar` may draw it edge to edge like a face.
    ///
    /// Remembered per picture: the answer reads pixels, and a `View` body
    /// asks on every draw. Not observed, for the same reason `memory` is not.
    @ObservationIgnored private var fills: [String: Bool] = [:]

    func fillsFrame(_ key: String) -> Bool {
        if let known = fills[key] { return known }
        guard let image = image(for: key) else { return true }
        let answer = image.fillsItsFrame
        fills[key] = answer
        return answer
    }

    /// Fetches the picture if there is not a fresh one already.
    ///
    /// Safe to call from `onAppear` on every row: the guards below make the
    /// second and later calls free.
    func ensure(key: String, url: URL?) {
        guard let url else { return }
        guard !inFlight.contains(key) else { return }

        // Already have it, and it is not stale.
        if let file = Self.file(for: key),
           let modified = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
           Date.now.timeIntervalSince(modified) < Self.maxAge {
            _ = image(for: key)
            return
        }

        // 🔴 One attempt per key per launch, whatever the outcome.
        //
        // This guard used to apply only to a *miss*, which left the stale-copy
        // case unbounded: a week-old picture and a provider that cannot be
        // reached meant a fresh download attempt every time the row scrolled
        // back on. `inFlight` does not help -- those attempts are sequential,
        // not concurrent. The stale copy is still drawn meanwhile, because
        // `image(for:)` does not care how old a file is.
        if checked.contains(key) { return }

        inFlight.insert(key)
        Task { [weak self] in
            let fetched = await Self.download(url)
            guard let self else { return }
            self.inFlight.remove(key)
            self.checked.insert(key)
            guard let fetched else { return }

            self.memory[key] = fetched
            Self.write(fetched, for: key)
            // Only after a real picture landed. Bumping on a miss would redraw
            // every avatar in the app to show exactly what was already there.
            self.generation &+= 1
        }
    }

    /// Drops a picture, for a mailbox being signed out of.
    func forget(key: String) {
        memory[key] = nil
        fills[key] = nil
        checked.remove(key)
        if let file = Self.file(for: key) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Every face, for signing out of Maily itself.
    ///
    /// The whole folder rather than a loop over the mailboxes still in the
    /// registry: by the time somebody signs out, some of those records are
    /// already gone, and a picture whose owner has been deleted is exactly the
    /// one nothing would think to remove.
    func forgetAll() {
        memory.removeAll()
        fills.removeAll()
        checked.removeAll()
        if let folder = Self.folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Disk

    private static var folder: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }

        let folder = base
            .appendingPathComponent("Maily", isDirectory: true)
            .appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Nil when there is no file, so the caller can tell "never fetched" from
    /// "fetched and stale".
    private static func file(for key: String) -> URL? {
        guard let url = path(for: key),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    private static func path(for key: String) -> URL? {
        // A mailbox id is an address-derived string and an account id is a
        // UUID; neither is guaranteed to be a legal filename, and an address
        // certainly is not.
        let safe = key.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return folder?.appendingPathComponent("\(safe).jpg")
    }

    private static func write(_ image: UIImage, for key: String) {
        // 🔴 PNG when there is transparency to keep. JPEG has no alpha, so a
        // mark floating on nothing came back from disk on the next launch as
        // a mark on a black square -- right in memory, wrong after a relaunch,
        // the kind of difference nobody thinks to test. The file keeps its
        // `.jpg` name; `UIImage(data:)` reads the bytes, not the name.
        guard let path = path(for: key),
              let data = image.hasAlphaChannel
                  ? image.pngData()
                  : image.jpegData(compressionQuality: 0.9)
        else { return }
        try? data.write(to: path, options: .atomic)
    }

    // MARK: - Network

    private static func download(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        // A face is worth a few seconds and no more. Everything that draws one
        // has a letter to show meanwhile.
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // 🔴 The status is read, not assumed. `BrandIcon` learned this the
            // expensive way: a service that answers a miss with a 404 whose
            // body is still a decodable image will hand every account the same
            // placeholder, and nothing about the picture looks wrong.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}

extension UIImage {
    /// Whether the picture carries transparency at all.
    var hasAlphaChannel: Bool {
        guard let alpha = cgImage?.alphaInfo else { return false }
        switch alpha {
        case .none, .noneSkipLast, .noneSkipFirst: return false
        default: return true
        }
    }

    /// Whether the picture reaches its own edges.
    ///
    /// The circle an avatar is cropped to touches the middle of each side and
    /// never the corners, so it is the side midpoints that are read: an app
    /// icon with rounded corners passes, a mark floating on transparency does
    /// not. Drawn down to 8x8 and read back -- tiny, and done once per
    /// picture by `AvatarStore`.
    var fillsItsFrame: Bool {
        guard hasAlphaChannel, let cg = cgImage else { return true }

        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base, width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return true }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

            func alpha(_ x: Int, _ y: Int) -> UInt8 { buffer[(y * side + x) * 4 + 3] }
            let sides = [
                alpha(3, 0), alpha(4, 0), alpha(3, 7), alpha(4, 7),
                alpha(0, 3), alpha(0, 4), alpha(7, 3), alpha(7, 4),
            ]
            return sides.allSatisfy { $0 >= 230 }
        }
    }
}
