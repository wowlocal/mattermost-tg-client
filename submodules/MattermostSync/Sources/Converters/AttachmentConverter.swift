import Foundation
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// Plain text plus `TextEntity`s, built piece by piece (ranges are UTF-16 offsets).
struct FormattedTextBuilder {
    private(set) var text = ""
    private(set) var entities: [TextEntity] = []
    private var length = 0
    /// How `appendMarkdown` parses (emoticons, inline LaTeX; 3E).
    var markdownOptions: MattermostMarkdown.Options = .default

    var isEmpty: Bool {
        return self.length == 0
    }

    var position: Int {
        return self.length
    }

    mutating func append(_ value: String, _ types: [TextEntityType] = []) {
        let start = self.length
        self.text += value
        self.length += value.utf16.count
        if self.length > start {
            for type in types {
                self.entities.append(TextEntity(range: start ..< self.length, type: type))
            }
        }
    }

    /// Appends Mattermost markdown, with `types` around all of it.
    mutating func appendMarkdown(_ markdown: String, _ types: [TextEntityType] = []) {
        let formatted = MattermostMarkdown.parse(markdown, options: self.markdownOptions)
        let start = self.length
        self.append(formatted.text)
        for entity in formatted.entities {
            self.entities.append(TextEntity(range: (entity.range.lowerBound + start) ..< (entity.range.upperBound + start), type: entity.type))
        }
        if self.length > start {
            for type in types {
                self.entities.append(TextEntity(range: start ..< self.length, type: type))
            }
        }
    }

    mutating func addEntity(_ type: TextEntityType, from start: Int) {
        if self.length > start {
            self.entities.append(TextEntity(range: start ..< self.length, type: type))
        }
    }

    /// Ends the current paragraph (no leading blank lines).
    mutating func paragraph() {
        if !self.isEmpty && !self.text.hasSuffix("\n\n") {
            self.append(self.text.hasSuffix("\n") ? "\n" : "\n\n")
        }
    }

    mutating func line() {
        if !self.isEmpty && !self.text.hasSuffix("\n") {
            self.append("\n")
        }
    }

    var formatted: FormattedText {
        return FormattedText(text: self.text, entities: self.entities)
    }
}

/// What a tapped attachment button carries (`ReplyMarkupButtonAction.callback` data), so the tap needs
/// no lookup: `POST /posts/{post}/actions/{id}` (with `selected_option` for menus).
public struct MattermostPostActionData: Codable, Equatable {
    public struct Option: Codable, Equatable {
        public var text: String
        public var value: String

        public init(text: String, value: String) {
            self.text = text
            self.value = value
        }
    }

    /// Marks our data among other callback data.
    public var kind: String = "mm-action"
    public var actionId: String
    public var name: String
    public var isSelect: Bool
    public var options: [Option]
    /// `users` or `channels` for dynamic menus.
    public var dataSource: String
    /// Set for actions of ephemeral posts, which are not in the database.
    public var cookie: String

    public init(actionId: String, name: String, isSelect: Bool, options: [Option], dataSource: String, cookie: String) {
        self.actionId = actionId
        self.name = name
        self.isSelect = isSelect
        self.options = options
        self.dataSource = dataSource
        self.cookie = cookie
    }

    func encoded() -> MemoryBuffer {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return MemoryBuffer(data: data)
    }

    public static func decode(_ buffer: MemoryBuffer?) -> MattermostPostActionData? {
        guard let buffer = buffer, let value = try? JSONDecoder().decode(MattermostPostActionData.self, from: buffer.makeData()), value.kind == "mm-action" else {
            return nil
        }
        return value
    }
}

/// Slack-style message attachments (`props.attachments`, from bots and webhooks) → formatted text, buttons
/// and an image (design: rendering gaps, 2C).
///
/// Each attachment becomes a block of text: the pretext, then a quote (Telegram's block quote stands in
/// for the attachment's colour bar) with the author, the title (a link when `title_link` is set), the text,
/// the fields (`Title: value`) and the footer. Telegram has no per-message colour, so `color` is not shown.
/// Buttons and menus become an inline keyboard; the first `image_url` on the server becomes the message's
/// photo when the post has no files (`thumb_url` and `author_icon` are not shown).
enum AttachmentConverter {
    struct Result {
        var replyMarkup: ReplyMarkupMessageAttribute?
        var image: (url: String, width: Int, height: Int)?
    }

    static func attachments(_ props: [String: JSONValue]) -> [[String: JSONValue]] {
        return (props["attachments"]?.arrayValue ?? []).compactMap { $0.objectValue }
    }

    /// Appends the attachments' text to `builder` and returns their buttons and image.
    static func convert(props: [String: JSONValue], images: [String: PostImage], serverURL: String, imageProxy: Bool = false, builder: inout FormattedTextBuilder) -> Result {
        var result = Result()
        var rows: [ReplyMarkupRow] = []
        for attachment in attachments(props) {
            func string(_ key: String) -> String {
                return attachment[key]?.scalarString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let pretext = string("pretext")
            if !pretext.isEmpty {
                builder.paragraph()
                builder.appendMarkdown(pretext)
            }
            builder.paragraph()
            let quoteStart = builder.position
            let author = string("author_name")
            if !author.isEmpty {
                let link = string("author_link")
                builder.append(author, link.isEmpty ? [.bold] : [.bold, .textUrl(url: link)])
            }
            let title = string("title")
            if !title.isEmpty {
                builder.line()
                let link = string("title_link")
                builder.append(title, link.isEmpty ? [.bold] : [.bold, .textUrl(url: link)])
            }
            let text = string("text")
            if !text.isEmpty {
                builder.line()
                builder.appendMarkdown(text)
            }
            for field in attachment["fields"]?.arrayValue ?? [] {
                guard let field = field.objectValue else {
                    continue
                }
                let fieldTitle = field["title"]?.scalarString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let value = field["value"]?.scalarString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if fieldTitle.isEmpty && value.isEmpty {
                    continue
                }
                builder.line()
                if !fieldTitle.isEmpty {
                    builder.append(fieldTitle, [.bold])
                    if !value.isEmpty {
                        // Short fields on one line; long values below their title, as Mattermost lays them out.
                        builder.append(field["short"]?.boolValue == true || !value.contains("\n") ? ": " : "\n")
                    }
                }
                if !value.isEmpty {
                    builder.appendMarkdown(value)
                }
            }
            var footer = string("footer")
            if let ts = attachment["ts"]?.int64Value, ts > 0 {
                let date = DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(ts)), dateStyle: .medium, timeStyle: .short)
                footer = footer.isEmpty ? date : footer + " · " + date
            }
            if !footer.isEmpty {
                builder.line()
                builder.append(footer, [.italic])
            }
            if builder.position == quoteStart {
                // Nothing but buttons or an image: the fallback text, if any.
                let fallback = string("fallback")
                if !fallback.isEmpty && string("image_url").isEmpty && (attachment["actions"]?.arrayValue ?? []).isEmpty {
                    builder.append(fallback)
                }
            }
            builder.addEntity(.blockQuote, from: quoteStart)

            // `image_url` only: `thumb_url` is a small decorative icon that Telegram would blow up to a photo.
            if result.image == nil {
                let url = string("image_url")
                if !url.isEmpty, let size = images[url], size.width > 0, size.height > 0, let serverURL = URL(string: serverURL), imageProxy || MattermostURLImageResource.sameOriginURL(url, serverURL: serverURL) != nil {
                    result.image = (url, size.width, size.height)
                }
            }
            rows.append(contentsOf: self.buttonRows(attachment["actions"]?.arrayValue ?? []))
        }
        if !rows.isEmpty {
            result.replyMarkup = ReplyMarkupMessageAttribute(rows: rows, flags: [.inline], placeholder: nil)
        }
        return result
    }

    /// Buttons two to a row in their order; every menu on its own row.
    private static func buttonRows(_ actions: [JSONValue]) -> [ReplyMarkupRow] {
        var rows: [ReplyMarkupRow] = []
        var pending: [ReplyMarkupButton] = []
        func flush() {
            if !pending.isEmpty {
                rows.append(ReplyMarkupRow(buttons: pending))
                pending = []
            }
        }
        for action in actions {
            guard let action = action.objectValue else {
                continue
            }
            let id = action["id"]?.scalarString ?? ""
            let name = action["name"]?.scalarString ?? ""
            if id.isEmpty || name.isEmpty {
                continue
            }
            let isSelect = action["type"]?.scalarString == "select"
            let options = (action["options"]?.arrayValue ?? []).compactMap { option -> MattermostPostActionData.Option? in
                guard let option = option.objectValue, let text = option["text"]?.scalarString, let value = option["value"]?.scalarString else {
                    return nil
                }
                return MattermostPostActionData.Option(text: text, value: value)
            }
            let data = MattermostPostActionData(
                actionId: id,
                name: name,
                isSelect: isSelect,
                options: options,
                dataSource: action["data_source"]?.scalarString ?? "",
                cookie: action["cookie"]?.scalarString ?? ""
            )
            let isDisabled = action["disabled"]?.boolValue == true
            var style: ReplyMarkupButton.Style?
            switch action["style"]?.scalarString ?? "" {
            case "good", "success":
                style = ReplyMarkupButton.Style(color: .success, iconFileId: nil)
            case "danger":
                style = ReplyMarkupButton.Style(color: .danger, iconFileId: nil)
            case "primary":
                style = ReplyMarkupButton.Style(color: .primary, iconFileId: nil)
            default:
                break
            }
            let button = ReplyMarkupButton(
                title: isSelect ? name + " ▾" : name,
                titleWhenForwarded: nil,
                action: isDisabled ? .disabled : .callback(requiresPassword: false, data: data.encoded()),
                style: style
            )
            if isSelect {
                flush()
                rows.append(ReplyMarkupRow(buttons: [button]))
            } else {
                pending.append(button)
                if pending.count == 2 {
                    flush()
                }
            }
        }
        flush()
        return rows
    }
}
