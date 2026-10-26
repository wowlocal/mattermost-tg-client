import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// How rich content renders for an account (Phase 3E): the server's and the user's link preview and markdown
/// settings. Read at every bootstrap before posts are written, and again on `config_changed` / `preferences_changed`
/// (`RichContent.swift`).
struct RichContentSettings: Equatable {
    /// The server's `EnableLinkPreviews`.
    var serverLinkPreviews = true
    /// The user's `display_settings/link_previews` (default on).
    var userLinkPreviews = true
    /// The server's `EnablePermalinkPreviews` (permalink embeds are only generated when it is on).
    var permalinkPreviews = true
    /// `HasImageProxy`: external preview images come through the server (`GET /image?url=`). Without it Relay
    /// loads only images on the server itself: Mattermost's clients would fetch them from the third-party site,
    /// which would show the device's address to every site linked in a channel.
    var imageProxy = false
    /// `display_settings/render_emoticons_as_emoji` (default on).
    var emoticons = true
    /// `EnableLatex` and `EnableInlineLatex`.
    var inlineLatex = false

    var linkPreviews: Bool {
        return self.serverLinkPreviews && self.userLinkPreviews
    }

    var markdownOptions: MattermostMarkdown.Options {
        return MattermostMarkdown.Options(emoticons: self.emoticons, inlineLatex: self.inlineLatex)
    }

    /// The server's part from `config` (kept as it was without one).
    func withConfig(_ config: ClientConfig?) -> RichContentSettings {
        guard let config = config else {
            return self
        }
        var result = self
        result.serverLinkPreviews = config.enableLinkPreviews
        result.permalinkPreviews = config.enablePermalinkPreviews
        result.imageProxy = config.hasImageProxy
        result.inlineLatex = config.enableLatex && config.enableInlineLatex
        return result
    }

    /// The user's part from the full list of preferences (missing ones are the defaults).
    func withPreferences(_ preferences: [Preference]) -> RichContentSettings {
        var result = self
        result.userLinkPreviews = RichContentSettings.display(DisplaySettingName.linkPreviews, in: preferences) ?? true
        result.emoticons = RichContentSettings.display(DisplaySettingName.renderEmoticonsAsEmoji, in: preferences) ?? true
        return result
    }

    /// The user's part from changed preferences only (`preferences_changed`): settings not among them stay.
    func withChangedPreferences(_ preferences: [Preference]) -> RichContentSettings {
        var result = self
        if let value = RichContentSettings.display(DisplaySettingName.linkPreviews, in: preferences) {
            result.userLinkPreviews = value
        }
        if let value = RichContentSettings.display(DisplaySettingName.renderEmoticonsAsEmoji, in: preferences) {
            result.emoticons = value
        }
        return result
    }

    /// A compact form for the sync store (what stored messages were rendered with).
    var encoded: String {
        let flags = [self.serverLinkPreviews, self.userLinkPreviews, self.permalinkPreviews, self.imageProxy, self.emoticons, self.inlineLatex]
        return flags.map { $0 ? "1" : "0" }.joined()
    }

    init() {
    }

    init?(encoded: String) {
        let flags = encoded.map { $0 == "1" }
        guard flags.count == 6 else {
            return nil
        }
        self.serverLinkPreviews = flags[0]
        self.userLinkPreviews = flags[1]
        self.permalinkPreviews = flags[2]
        self.imageProxy = flags[3]
        self.emoticons = flags[4]
        self.inlineLatex = flags[5]
    }

    private static func display(_ name: String, in preferences: [Preference]) -> Bool? {
        guard let preference = preferences.first(where: { $0.category == PreferenceCategory.displaySettings && $0.name == name }) else {
            return nil
        }
        return preference.value != "false"
    }
}

/// `metadata.embeds` → Telegram's link preview (`TelegramMediaWebpage` with loaded content), so the chat shows its
/// link preview card: the site name, title, description and image of an OpenGraph page, a picture for a link to an
/// image, and the author, channel and text of a linked post (permalink previews). `message_attachment` embeds are
/// the attachments (`AttachmentConverter`); `link` embeds (no preview data) get no card, as on Mattermost.
enum LinkPreviewConverter {
    struct Result {
        var webpage: TelegramMediaWebpage
        var attribute: WebpagePreviewMessageAttribute
    }

    /// OpenGraph images at least this wide (and not extremely wide) show large under the text; smaller ones as
    /// a thumbnail beside it, like Mattermost's own cards.
    static let largeImageMinimumWidth = 400

    static func webpage(post: Post, context: PostConversionContext) -> Result? {
        let settings = context.richContent
        guard !post.type.hasPrefix("system_"), !self.previewRemoved(post) else {
            return nil
        }
        let metadata = post.metadata ?? PostMetadata()
        for embed in metadata.embeds {
            // Link previews follow the server's and the user's link preview settings; permalink previews only the
            // server's `EnablePermalinkPreviews`, as in Mattermost's web app.
            switch embed.type {
            case "opengraph":
                if settings.linkPreviews, let openGraph = embed.openGraph, let result = self.openGraph(openGraph, embedURL: embed.url, post: post, images: metadata.images, context: context) {
                    return result
                }
            case "image":
                if settings.linkPreviews, let result = self.image(url: embed.url, post: post, images: metadata.images, context: context) {
                    return result
                }
            case "permalink":
                if settings.permalinkPreviews, let preview = embed.permalink, let result = self.permalink(preview, post: post, context: context) {
                    return result
                }
            default:
                continue
            }
        }
        return nil
    }

    /// A stored permalink preview: the only cards written as safe (in-app links), see `permalink`.
    static func isPermalinkPreview(_ message: Message) -> Bool {
        return message.webpagePreviewAttribute?.isSafe == true
    }

    /// The author removed the preview (the web app's "Remove link preview": `props.remove_link_preview`).
    static func previewRemoved(_ post: Post) -> Bool {
        guard let value = post.props["remove_link_preview"] else {
            return false
        }
        return value.boolValue == true || value.stringValue == "true"
    }

    private static func openGraph(_ openGraph: OpenGraph, embedURL: String, post: Post, images: [String: PostImage], context: PostConversionContext) -> Result? {
        let url = embedURL.isEmpty ? openGraph.url : embedURL
        guard !url.isEmpty else {
            return nil
        }
        let title = openGraph.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = openGraph.description.trimmingCharacters(in: .whitespacesAndNewlines)
        var image: TelegramMediaImage?
        var isLarge = false
        if let candidate = openGraph.images.first(where: { !$0.bestURL.isEmpty }) {
            let imageURL = candidate.bestURL
            var width = candidate.width
            var height = candidate.height
            if width <= 0 || height <= 0, let size = images[imageURL] ?? images[candidate.url] {
                width = size.width
                height = size.height
            }
            if width > 0, height > 0, self.canLoadImage(imageURL, context: context) {
                image = MediaConverter.urlImage(url: imageURL, width: width, height: height, mediaId: context.mediaId("url:" + imageURL))
                isLarge = width >= self.largeImageMinimumWidth && width <= height * 3
            }
        }
        if title.isEmpty && description.isEmpty && image == nil {
            return nil
        }
        let siteName = openGraph.siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = TelegramMediaWebpageLoadedContent(
            url: url,
            displayUrl: self.displayURL(url),
            hash: 0,
            type: "article",
            websiteName: siteName.isEmpty ? self.host(url) : siteName,
            title: title.isEmpty ? nil : title,
            text: description.isEmpty ? nil : description,
            embedUrl: nil,
            embedType: nil,
            embedSize: nil,
            duration: nil,
            author: nil,
            isMediaLargeByDefault: isLarge,
            imageIsVideoCover: false,
            image: image,
            file: nil,
            story: nil,
            attributes: [],
            instantPage: nil
        )
        return self.result(content, post: post, forceLargeMedia: image == nil ? nil : isLarge, context: context)
    }

    /// A link to an image: the picture, large, with the host as the site.
    private static func image(url: String, post: Post, images: [String: PostImage], context: PostConversionContext) -> Result? {
        guard !url.isEmpty, let size = images[url], size.width > 0, size.height > 0, self.canLoadImage(url, context: context) else {
            return nil
        }
        let image = MediaConverter.urlImage(url: url, width: size.width, height: size.height, mediaId: context.mediaId("url:" + url))
        let content = TelegramMediaWebpageLoadedContent(
            url: url,
            displayUrl: self.displayURL(url),
            hash: 0,
            type: "photo",
            websiteName: self.host(url),
            title: nil,
            text: nil,
            embedUrl: nil,
            embedType: nil,
            embedSize: nil,
            duration: nil,
            author: nil,
            isMediaLargeByDefault: true,
            imageIsVideoCover: false,
            image: image,
            file: nil,
            story: nil,
            attributes: [],
            instantPage: nil
        )
        return self.result(content, post: post, forceLargeMedia: true, context: context)
    }

    /// A permalink to another post: its author as the title, its text, and its channel as the site. Tapping the
    /// card opens the post (TelegramUI's permalink handling).
    private static func permalink(_ preview: PermalinkPreview, post: Post, context: PostConversionContext) -> Result? {
        guard let linked = preview.post, linked.deleteAt == 0, !preview.teamName.isEmpty else {
            return nil
        }
        let url = MattermostLink.permalink(serverURL: context.serverURL, teamName: preview.teamName, postId: preview.postId)
        var text = MattermostMarkdown.parse(linked.message, options: context.richContent.markdownOptions).text
        if text.isEmpty, let file = linked.metadata?.files.first {
            text = file.name
        }
        if text.count > 300 {
            text = String(text.prefix(300)) + "…"
        }
        let author = context.userDisplayName(linked.userId) ?? "Message"
        let channel: String
        switch preview.channelType {
        case "D", "G":
            channel = preview.channelDisplayName.isEmpty ? "Direct Message" : preview.channelDisplayName
        default:
            channel = preview.channelDisplayName.isEmpty ? preview.teamName : "~" + preview.channelDisplayName
        }
        let content = TelegramMediaWebpageLoadedContent(
            url: url,
            displayUrl: self.displayURL(url),
            hash: 0,
            type: "article",
            websiteName: channel,
            title: author,
            text: text.isEmpty ? nil : text,
            embedUrl: nil,
            embedType: nil,
            embedSize: nil,
            duration: nil,
            author: nil,
            isMediaLargeByDefault: false,
            imageIsVideoCover: false,
            image: nil,
            file: nil,
            story: nil,
            attributes: [],
            instantPage: nil
        )
        return self.result(content, post: post, forceLargeMedia: nil, context: context, isSafe: true)
    }

    /// The media id changes with the content, so an edited post (the server adds embeds after posting, then sends
    /// `post_edited`) stores a new preview instead of updating a shared media entry.
    private static func result(_ content: TelegramMediaWebpageLoadedContent, post: Post, forceLargeMedia: Bool?, context: PostConversionContext, isSafe: Bool = false) -> Result {
        let fingerprint = [content.url, content.type ?? "", content.websiteName ?? "", content.title ?? "", content.text ?? "", content.image.flatMap { $0.representations.last.map { "\($0.dimensions.width)x\($0.dimensions.height)" } } ?? "", content.image?.imageId.id.description ?? ""].joined(separator: "\u{1}")
        let mediaId = context.mediaId("webpage:\(post.id):\(fingerprint.persistentHashString)")
        let webpage = TelegramMediaWebpage(webpageId: MediaId(namespace: Namespaces.Media.CloudWebpage, id: mediaId), content: .Loaded(content))
        return Result(webpage: webpage, attribute: WebpagePreviewMessageAttribute(leadingPreview: false, forceLargeMedia: forceLargeMedia, isManuallyAdded: false, isSafe: isSafe))
    }

    /// Images on the server load directly; others only through the server's image proxy.
    static func canLoadImage(_ url: String, context: PostConversionContext) -> Bool {
        if context.richContent.imageProxy {
            return URL(string: url)?.scheme.map { ["http", "https"].contains($0.lowercased()) } ?? false
        }
        guard let serverURL = URL(string: context.serverURL) else {
            return false
        }
        return MattermostURLImageResource.sameOriginURL(url, serverURL: serverURL) != nil
    }

    static func host(_ url: String) -> String? {
        guard var host = URL(string: url)?.host else {
            return nil
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    static func displayURL(_ url: String) -> String {
        var display = url
        for prefix in ["https://", "http://"] where display.lowercased().hasPrefix(prefix) {
            display.removeFirst(prefix.count)
            break
        }
        return display
    }
}
