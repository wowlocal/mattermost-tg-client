import Foundation

/// One entry of `GET /teams/{team_id}/commands/autocomplete_suggestions`.
///
/// The server serialises this struct without JSON tags, so keys are
/// PascalCase (`Complete`, `Suggestion`, ...). Lowercase keys are accepted too.
public struct AutocompleteSuggestion: Codable, Sendable, Equatable {
    /// The full command line to insert when this suggestion is picked.
    public var complete: String
    public var suggestion: String
    public var hint: String
    public var description: String
    /// Base64-encoded SVG or a URL, depending on the command provider.
    public var iconData: String

    public init(complete: String = "", suggestion: String = "", hint: String = "", description: String = "", iconData: String = "") {
        self.complete = complete
        self.suggestion = suggestion
        self.hint = hint
        self.description = description
        self.iconData = iconData
    }

    enum CodingKeys: String, CodingKey {
        case complete = "Complete"
        case suggestion = "Suggestion"
        case hint = "Hint"
        case description = "Description"
        case iconData = "IconData"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.anyKeyContainer()
        func value(_ key: CodingKeys, _ alternate: String) -> String {
            c.optionalString(AnyCodingKey(key.rawValue)) ?? c.optionalString(AnyCodingKey(alternate)) ?? ""
        }
        complete = value(.complete, "complete")
        suggestion = value(.suggestion, "suggestion")
        hint = value(.hint, "hint")
        description = value(.description, "description")
        iconData = value(.iconData, "icon_data")
    }
}

/// Response of `POST /commands/execute`.
public struct CommandResponse: Codable, Sendable, Equatable {
    /// `"ephemeral"` or `"in_channel"`.
    public var responseType: String
    public var text: String
    public var username: String
    public var channelId: String
    public var iconURL: String
    public var type: String
    public var props: [String: JSONValue]
    /// A URL or in-app path the client should navigate to.
    public var gotoLocation: String
    public var triggerId: String
    public var skipSlackParsing: Bool
    public var attachments: [JSONValue]
    public var extraResponses: [JSONValue]

    public init(
        responseType: String = "",
        text: String = "",
        username: String = "",
        channelId: String = "",
        iconURL: String = "",
        type: String = "",
        props: [String: JSONValue] = [:],
        gotoLocation: String = "",
        triggerId: String = "",
        skipSlackParsing: Bool = false,
        attachments: [JSONValue] = [],
        extraResponses: [JSONValue] = []
    ) {
        self.responseType = responseType
        self.text = text
        self.username = username
        self.channelId = channelId
        self.iconURL = iconURL
        self.type = type
        self.props = props
        self.gotoLocation = gotoLocation
        self.triggerId = triggerId
        self.skipSlackParsing = skipSlackParsing
        self.attachments = attachments
        self.extraResponses = extraResponses
    }

    enum CodingKeys: String, CodingKey {
        case responseType = "response_type"
        case text, username
        case channelId = "channel_id"
        case iconURL = "icon_url"
        case type, props
        case gotoLocation = "goto_location"
        case triggerId = "trigger_id"
        case skipSlackParsing = "skip_slack_parsing"
        case attachments
        case extraResponses = "extra_responses"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        responseType = c.string(.responseType)
        text = c.string(.text)
        username = c.string(.username)
        channelId = c.string(.channelId)
        iconURL = c.string(.iconURL)
        type = c.string(.type)
        props = c.jsonObject(.props)
        gotoLocation = c.string(.gotoLocation)
        triggerId = c.string(.triggerId)
        skipSlackParsing = c.bool(.skipSlackParsing)
        attachments = c.array(JSONValue.self, .attachments)
        extraResponses = c.array(JSONValue.self, .extraResponses)
    }
}

/// Response of `POST /posts/{post_id}/actions/{action_id}`.
public struct PostActionResponse: Codable, Sendable, Equatable {
    public var status: String
    /// Set when the integration wants to open an interactive dialog.
    public var triggerId: String

    public init(status: String = "", triggerId: String = "") {
        self.status = status
        self.triggerId = triggerId
    }

    enum CodingKeys: String, CodingKey {
        case status
        case triggerId = "trigger_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.string(.status)
        triggerId = c.string(.triggerId)
    }
}

/// Body of `POST /actions/dialogs/submit`.
public struct DialogSubmission: Codable, Sendable, Equatable {
    public var type: String
    public var url: String
    public var callbackId: String
    public var state: String
    public var userId: String
    public var channelId: String
    public var teamId: String
    /// Element name → value.
    public var submission: [String: JSONValue]
    public var cancelled: Bool

    public init(
        url: String,
        callbackId: String,
        state: String,
        userId: String,
        channelId: String,
        teamId: String,
        submission: [String: JSONValue],
        cancelled: Bool = false,
        type: String = "dialog_submission"
    ) {
        self.type = type
        self.url = url
        self.callbackId = callbackId
        self.state = state
        self.userId = userId
        self.channelId = channelId
        self.teamId = teamId
        self.submission = submission
        self.cancelled = cancelled
    }

    enum CodingKeys: String, CodingKey {
        case type, url
        case callbackId = "callback_id"
        case state
        case userId = "user_id"
        case channelId = "channel_id"
        case teamId = "team_id"
        case submission, cancelled
    }
}

/// Response of `POST /actions/dialogs/submit`. Empty on success.
public struct DialogSubmissionResponse: Codable, Sendable, Equatable {
    public var error: String
    /// Element name → validation error.
    public var errors: [String: String]

    public init(error: String = "", errors: [String: String] = [:]) {
        self.error = error
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey {
        case error, errors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = c.string(.error)
        errors = c.stringMap(.errors)
    }
}

/// Body of `POST /notifications/ack`.
public struct PushNotificationAck: Codable, Sendable, Equatable {
    /// The push's `ack_id`.
    public var id: String
    public var platform: String
    /// The push's `type` (`message`, `clear`, `update_badge`, `session`, ...).
    public var type: String
    public var postId: String?
    /// Set for ID-only pushes: asks the server to return the full notification.
    public var isIdLoaded: Bool
    /// Milliseconds since 1970.
    public var receivedAt: Int64

    public init(id: String, platform: String = "apple", type: String, postId: String? = nil, isIdLoaded: Bool = false, receivedAt: Int64) {
        self.id = id
        self.platform = platform
        self.type = type
        self.postId = postId
        self.isIdLoaded = isIdLoaded
        self.receivedAt = receivedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, platform, type
        case postId = "post_id"
        case isIdLoaded = "is_id_loaded"
        case receivedAt = "received_at"
    }
}

/// Response of `GET /system/ping`.
public struct PingResponse: Codable, Sendable, Equatable {
    /// `"OK"` for a healthy server.
    public var status: String
    /// All fields, including server-specific extras.
    public var fields: [String: JSONValue]

    public init(status: String, fields: [String: JSONValue] = [:]) {
        self.status = status
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        fields = (try? container.decode([String: JSONValue].self)) ?? [:]
        status = fields["status"]?.scalarString ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }

    public var isOK: Bool { status.uppercased() == "OK" }
}

/// Result of a password login.
public struct LoginResult: Sendable, Equatable {
    public var user: User
    /// Session token from the `Token` response header.
    public var token: String

    public init(user: User, token: String) {
        self.user = user
        self.token = token
    }
}
