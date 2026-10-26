import Foundation

/// The payload of an `open_dialog` WebSocket event: an integration (a slash command or a message button
/// that got a `trigger_id`) asks the client to show an interactive dialog.
public struct OpenDialogRequest: Codable, Sendable, Equatable {
    public var triggerId: String
    /// Where the client posts the submission (`POST /actions/dialogs/submit` with this `url`).
    public var url: String
    public var dialog: InteractiveDialog

    public init(triggerId: String = "", url: String = "", dialog: InteractiveDialog = InteractiveDialog()) {
        self.triggerId = triggerId
        self.url = url
        self.dialog = dialog
    }

    enum CodingKeys: String, CodingKey {
        case triggerId = "trigger_id"
        case url, dialog
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggerId = c.string(.triggerId)
        url = c.string(.url)
        dialog = c.lenient(InteractiveDialog.self, .dialog) ?? InteractiveDialog()
    }
}

/// An interactive dialog (`model.Dialog`).
public struct InteractiveDialog: Codable, Sendable, Equatable {
    public var callbackId: String
    public var title: String
    /// Markdown shown above the elements.
    public var introductionText: String
    public var iconURL: String
    public var elements: [DialogElement]
    /// The submit button's title; empty means "Submit".
    public var submitLabel: String
    /// Cancelling posts a submission with `cancelled: true`.
    public var notifyOnCancel: Bool
    /// Opaque; sent back with the submission.
    public var state: String

    public init(callbackId: String = "", title: String = "", introductionText: String = "", iconURL: String = "", elements: [DialogElement] = [], submitLabel: String = "", notifyOnCancel: Bool = false, state: String = "") {
        self.callbackId = callbackId
        self.title = title
        self.introductionText = introductionText
        self.iconURL = iconURL
        self.elements = elements
        self.submitLabel = submitLabel
        self.notifyOnCancel = notifyOnCancel
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case callbackId = "callback_id"
        case title
        case introductionText = "introduction_text"
        case iconURL = "icon_url"
        case elements
        case submitLabel = "submit_label"
        case notifyOnCancel = "notify_on_cancel"
        case state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callbackId = c.string(.callbackId)
        title = c.string(.title)
        introductionText = c.string(.introductionText)
        iconURL = c.string(.iconURL)
        elements = c.array(DialogElement.self, .elements)
        submitLabel = c.string(.submitLabel)
        notifyOnCancel = c.bool(.notifyOnCancel)
        state = c.string(.state)
    }
}

/// One field of an interactive dialog (`model.DialogElement`).
public struct DialogElement: Codable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case text
        case textarea
        case select
        case bool
        case radio
        case unknown
    }

    public var displayName: String
    /// The submission key.
    public var name: String
    /// `text`, `textarea`, `select`, `bool` or `radio`.
    public var type: String
    /// For text fields: `email`, `number`, `password`, `tel`, `url` (or empty: plain text).
    public var subtype: String
    /// The initial value (a string also for booleans: `"true"`).
    public var defaultValue: String
    public var placeholder: String
    public var helpText: String
    public var optional: Bool
    public var minLength: Int
    public var maxLength: Int
    /// For selects: `users` or `channels` (options come from the server), or empty (static `options`).
    public var dataSource: String
    public var options: [DialogOption]

    public init(displayName: String = "", name: String = "", type: String = "text", subtype: String = "", defaultValue: String = "", placeholder: String = "", helpText: String = "", optional: Bool = false, minLength: Int = 0, maxLength: Int = 0, dataSource: String = "", options: [DialogOption] = []) {
        self.displayName = displayName
        self.name = name
        self.type = type
        self.subtype = subtype
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.helpText = helpText
        self.optional = optional
        self.minLength = minLength
        self.maxLength = maxLength
        self.dataSource = dataSource
        self.options = options
    }

    public var kind: Kind {
        return Kind(rawValue: type) ?? .unknown
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case name, type, subtype
        case defaultValue = "default"
        case placeholder
        case helpText = "help_text"
        case optional
        case minLength = "min_length"
        case maxLength = "max_length"
        case dataSource = "data_source"
        case options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = c.string(.displayName)
        name = c.string(.name)
        type = c.string(.type)
        subtype = c.string(.subtype)
        defaultValue = c.string(.defaultValue)
        placeholder = c.string(.placeholder)
        helpText = c.string(.helpText)
        optional = c.bool(.optional)
        minLength = c.int(.minLength)
        maxLength = c.int(.maxLength)
        dataSource = c.string(.dataSource)
        options = c.array(DialogOption.self, .options)
    }
}

/// A static option of a `select` or `radio` element.
public struct DialogOption: Codable, Sendable, Equatable {
    public var text: String
    public var value: String

    public init(text: String, value: String) {
        self.text = text
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case text, value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.string(.text)
        value = c.string(.value)
    }
}

// MARK: - Validation

/// Why a dialog value is refused before submitting (Mattermost's clients check the same).
public enum DialogValidationError: Equatable, Sendable {
    case required
    case tooShort(minLength: Int)
    case tooLong(maxLength: Int)
    case invalidEmail
    case invalidNumber
    case invalidURL
}

extension DialogElement {
    /// The submission value of the element's default (`"true"` for a checkbox becomes `true`), or nil.
    public var defaultSubmissionValue: JSONValue? {
        switch kind {
        case .bool:
            let value = defaultValue.lowercased()
            return .bool(value == "true" || value == "1")
        default:
            if defaultValue.isEmpty {
                return nil
            }
            return submissionValue(text: defaultValue)
        }
    }

    /// A text field's text as its submission value: numbers (`subtype` `number`) as numbers, else the text.
    public func submissionValue(text: String) -> JSONValue {
        if kind == .text && subtype == "number" {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let value = Int64(trimmed) {
                return .int(value)
            }
            if let value = Double(trimmed) {
                return .double(value)
            }
        }
        return .string(text)
    }

    /// Checks a value as Mattermost's own clients do before submitting: required fields, text lengths and the
    /// email, number and URL subtypes. Checkboxes are never missing.
    public func validate(_ value: JSONValue?) -> DialogValidationError? {
        if kind == .bool {
            return nil
        }
        let text: String
        switch value {
        case let .string(string)?:
            text = string
        case let .int(number)?:
            text = String(number)
        case let .double(number)?:
            text = String(number)
        default:
            text = ""
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return optional ? nil : .required
        }
        if kind == .text || kind == .textarea {
            if minLength > 0 && text.count < minLength {
                return .tooShort(minLength: minLength)
            }
            if maxLength > 0 && text.count > maxLength {
                return .tooLong(maxLength: maxLength)
            }
        }
        if kind == .text {
            switch subtype {
            case "email":
                if !text.contains("@") || text.hasPrefix("@") || text.hasSuffix("@") {
                    return .invalidEmail
                }
            case "number":
                if Double(text.trimmingCharacters(in: .whitespaces)) == nil {
                    return .invalidNumber
                }
            case "url":
                let lowercased = text.lowercased()
                if !lowercased.hasPrefix("http://") && !lowercased.hasPrefix("https://") {
                    return .invalidURL
                }
            default:
                break
            }
        }
        return nil
    }
}
