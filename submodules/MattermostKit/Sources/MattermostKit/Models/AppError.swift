import Foundation

/// The error body Mattermost returns for failed requests.
public struct AppError: Codable, Sendable, Equatable, Error, LocalizedError {
    /// Translation ID, e.g. `"api.user.login.invalid_credentials_email_username"`.
    public var id: String
    public var message: String
    public var detailedError: String
    public var requestId: String
    public var statusCode: Int
    public var isOAuth: Bool

    public init(
        id: String = "",
        message: String = "",
        detailedError: String = "",
        requestId: String = "",
        statusCode: Int = 0,
        isOAuth: Bool = false
    ) {
        self.id = id
        self.message = message
        self.detailedError = detailedError
        self.requestId = requestId
        self.statusCode = statusCode
        self.isOAuth = isOAuth
    }

    enum CodingKeys: String, CodingKey {
        case id
        case message
        case detailedError = "detailed_error"
        case requestId = "request_id"
        case statusCode = "status_code"
        case isOAuth = "is_oauth"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        message = c.string(.message)
        detailedError = c.string(.detailedError)
        requestId = c.string(.requestId)
        statusCode = c.int(.statusCode)
        isOAuth = c.bool(.isOAuth)
    }

    public var errorDescription: String? {
        message.isEmpty ? id : message
    }
}
