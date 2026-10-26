import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit

// Media resources backed by the Mattermost REST API. They are fetched through the auxiliary `fetchResource`
// hook (`TelegramAccountAuxiliaryMethods`), which runs before TelegramCore's own fetcher.
//
// The class names are part of the storage format (PostboxCoding hashes the unqualified type name):
// never rename them.

/// A file attachment (`GET /files/{id}`, `/thumbnail`, `/preview`).
public final class MattermostFileResource: TelegramMediaResource {
    public enum Variant: Int32 {
        case file = 0
        case thumbnail = 1
        case preview = 2
    }

    public let fileId: String
    public let variant: Variant
    public let size: Int64?

    public init(fileId: String, variant: Variant, size: Int64?) {
        self.fileId = fileId
        self.variant = variant
        self.size = size
    }

    public required init(decoder: PostboxDecoder) {
        self.fileId = decoder.decodeStringForKey("f", orElse: "")
        self.variant = Variant(rawValue: decoder.decodeInt32ForKey("v", orElse: 0)) ?? .file
        self.size = decoder.decodeOptionalInt64ForKey("s")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.fileId, forKey: "f")
        encoder.encodeInt32(self.variant.rawValue, forKey: "v")
        if let size = self.size {
            encoder.encodeInt64(size, forKey: "s")
        } else {
            encoder.encodeNil(forKey: "s")
        }
    }

    public var id: MediaResourceId {
        return MediaResourceId("mm-file-\(self.fileId)-\(self.variant.rawValue)")
    }

    public func isEqual(to: MediaResource) -> Bool {
        guard let to = to as? MattermostFileResource else {
            return false
        }
        return self.fileId == to.fileId && self.variant == to.variant && self.size == to.size
    }

    var request: MattermostResource {
        switch self.variant {
        case .file:
            return .file(id: self.fileId)
        case .thumbnail:
            return .fileThumbnail(id: self.fileId)
        case .preview:
            return .filePreview(id: self.fileId)
        }
    }
}

/// A user's profile picture (`GET /users/{id}/image`). `lastPictureUpdate` is part of the id, so a new
/// picture is a new resource.
public final class MattermostAvatarResource: TelegramMediaResource {
    public let userId: String
    public let lastPictureUpdate: Int64

    public init(userId: String, lastPictureUpdate: Int64) {
        self.userId = userId
        self.lastPictureUpdate = lastPictureUpdate
    }

    public required init(decoder: PostboxDecoder) {
        self.userId = decoder.decodeStringForKey("u", orElse: "")
        self.lastPictureUpdate = decoder.decodeInt64ForKey("t", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.userId, forKey: "u")
        encoder.encodeInt64(self.lastPictureUpdate, forKey: "t")
    }

    public var size: Int64? {
        return nil
    }

    public var id: MediaResourceId {
        return MediaResourceId("mm-avatar-\(self.userId)-\(self.lastPictureUpdate)")
    }

    public func isEqual(to: MediaResource) -> Bool {
        guard let to = to as? MattermostAvatarResource else {
            return false
        }
        return self.userId == to.userId && self.lastPictureUpdate == to.lastPictureUpdate
    }
}

/// An image at a URL on the Mattermost server: message attachment images (`image_url`, `thumb_url`) and
/// webhook icons (`override_icon_url`). Only URLs on the account's server are fetched (relative URLs
/// resolve against it); images elsewhere would need the server's image proxy and are not loaded.
public final class MattermostURLImageResource: TelegramMediaResource {
    public let url: String

    public init(url: String) {
        self.url = url
    }

    public required init(decoder: PostboxDecoder) {
        self.url = decoder.decodeStringForKey("u", orElse: "")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.url, forKey: "u")
    }

    public var size: Int64? {
        return nil
    }

    public var id: MediaResourceId {
        return MediaResourceId("mm-url-\(self.url.persistentHashString)")
    }

    public func isEqual(to: MediaResource) -> Bool {
        guard let to = to as? MattermostURLImageResource else {
            return false
        }
        return self.url == to.url
    }

    /// The URL to fetch, or nil when it is not on `serverURL`.
    static func sameOriginURL(_ string: String, serverURL: URL) -> URL? {
        guard let url = URL(string: string, relativeTo: serverURL)?.absoluteURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        func port(_ url: URL) -> Int? {
            return url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }
        guard scheme == serverURL.scheme?.lowercased(), url.host?.lowercased() == serverURL.host?.lowercased(), port(url) == port(serverURL) else {
            return nil
        }
        return url
    }
}

extension String {
    /// FNV-1a of the UTF-8 bytes as hex: stable across launches (unlike `hashValue`).
    var persistentHashString: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

private var mattermostDeclaredEncodables: Void = {
    declareEncodable(MattermostFileResource.self, f: { MattermostFileResource(decoder: $0) })
    declareEncodable(MattermostAvatarResource.self, f: { MattermostAvatarResource(decoder: $0) })
    declareEncodable(MattermostURLImageResource.self, f: { MattermostURLImageResource(decoder: $0) })
    return
}()

/// Registers MattermostSync's PostboxCoding types. Call it wherever `telegramUIDeclareEncodables()` runs
/// (app and every extension that opens Postbox).
public func mattermostDeclareEncodables() {
    let _ = mattermostDeclaredEncodables
}

/// The REST client of each account's postbox, for the media fetcher.
final class MattermostResourceClients {
    static let shared = MattermostResourceClients()

    private struct Entry {
        weak var postbox: Postbox?
        let client: Promise<MattermostClient?>
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    private func entry(postbox: Postbox) -> Entry {
        self.lock.lock()
        defer { self.lock.unlock() }
        let key = ObjectIdentifier(postbox)
        if let entry = self.entries[key], entry.postbox === postbox {
            return entry
        }
        let entry = Entry(postbox: postbox, client: Promise<MattermostClient?>(nil))
        self.entries[key] = entry
        return entry
    }

    func register(postbox: Postbox, client: MattermostClient) {
        self.entry(postbox: postbox).client.set(.single(client))
    }

    func client(postbox: Postbox) -> Signal<MattermostClient, NoError> {
        return self.entry(postbox: postbox).client.get()
        |> mapToSignal { client -> Signal<MattermostClient, NoError> in
            if let client = client {
                return .single(client)
            } else {
                return .complete()
            }
        }
        |> take(1)
    }
}

/// The auxiliary fetch hook for Mattermost resources; nil for every other resource type.
///
/// Spike D downloads the whole file in one request and ignores the requested byte ranges (Range requests
/// for streaming video come later).
public func mattermostFetchResource(postbox: Postbox, resource: MediaResource) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>? {
    if let signal = MattermostReactionImages.fetch(postbox: postbox, resource: resource) {
        return signal
    }
    if let resource = resource as? MattermostURLImageResource {
        return fetchURLImage(postbox: postbox, resource: resource)
    }
    let request: MattermostResource
    if let resource = resource as? MattermostFileResource {
        request = resource.request
    } else if let resource = resource as? MattermostAvatarResource {
        request = .userImage(userId: resource.userId, lastPictureUpdate: resource.lastPictureUpdate)
    } else {
        return nil
    }
    let resourceId = resource.id.stringRepresentation
    return MattermostResourceClients.shared.client(postbox: postbox)
    |> castError(MediaResourceDataFetchError.self)
    |> mapToSignal { client -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> in
        return Signal { subscriber in
            let task = Task {
                do {
                    let data = try await client.data(for: request)
                    subscriber.putNext(.reset)
                    subscriber.putNext(.dataPart(resourceOffset: 0, data: data, range: 0 ..< Int64(data.count), complete: true))
                    subscriber.putCompletion()
                } catch {
                    if !Task.isCancelled {
                        MMLog.log("fetch \(resourceId) failed: \(error)")
                    }
                    subscriber.putError(.generic)
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}

/// A `MattermostURLImageResource`: a plain GET on the server's origin (static images need no session).
private func fetchURLImage(postbox: Postbox, resource: MattermostURLImageResource) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> {
    let resourceId = resource.id.stringRepresentation
    return MattermostResourceClients.shared.client(postbox: postbox)
    |> castError(MediaResourceDataFetchError.self)
    |> mapToSignal { client -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> in
        guard let url = MattermostURLImageResource.sameOriginURL(resource.url, serverURL: client.serverURL) else {
            MMLog.log("fetch \(resourceId): \(resource.url) is not on the server; not loaded")
            return .fail(.generic)
        }
        return Signal { subscriber in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.setValue(MattermostSync.userAgent, forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode), !data.isEmpty else {
                        throw URLError(.badServerResponse)
                    }
                    let image = flattenedImageData(data)
                    subscriber.putNext(.reset)
                    subscriber.putNext(.dataPart(resourceOffset: 0, data: image, range: 0 ..< Int64(image.count), complete: true))
                    subscriber.putCompletion()
                } catch {
                    if !Task.isCancelled {
                        MMLog.log("fetch \(resourceId) failed: \(error)")
                    }
                    subscriber.putError(.generic)
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}

/// Telegram draws photos opaque, so the (arbitrary) colour of transparent pixels would show: images with
/// an alpha channel (logos, icons) are flattened onto white.
private func flattenedImageData(_ data: Data) -> Data {
    guard let image = UIImage(data: data), let cgImage = image.cgImage else {
        return data
    }
    switch cgImage.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
        return data
    default:
        break
    }
    let size = CGSize(width: cgImage.width, height: cgImage.height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        image.draw(in: CGRect(origin: .zero, size: size))
    }
    return rendered.pngData() ?? data
}
