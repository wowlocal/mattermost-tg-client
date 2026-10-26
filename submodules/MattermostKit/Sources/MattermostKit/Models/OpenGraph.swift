import Foundation

/// Link preview data (`POST /opengraph`, and `opengraph` post embeds).
public struct OpenGraph: Codable, Sendable, Equatable {
    public struct Image: Codable, Sendable, Equatable {
        public var url: String
        public var secureURL: String
        public var type: String
        public var width: Int
        public var height: Int

        public init(url: String = "", secureURL: String = "", type: String = "", width: Int = 0, height: Int = 0) {
            self.url = url
            self.secureURL = secureURL
            self.type = type
            self.width = width
            self.height = height
        }

        enum CodingKeys: String, CodingKey {
            case url
            case secureURL = "secure_url"
            case type, width, height
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = c.string(.url)
            secureURL = c.string(.secureURL)
            type = c.string(.type)
            width = c.int(.width)
            height = c.int(.height)
        }

        /// `secure_url` if present, else `url`.
        public var bestURL: String { secureURL.isEmpty ? url : secureURL }
    }

    public var type: String
    public var url: String
    public var title: String
    public var description: String
    public var determiner: String
    public var siteName: String
    public var locale: String
    public var images: [Image]
    public var videos: [JSONValue]
    public var audios: [JSONValue]

    public init(
        type: String = "",
        url: String = "",
        title: String = "",
        description: String = "",
        determiner: String = "",
        siteName: String = "",
        locale: String = "",
        images: [Image] = [],
        videos: [JSONValue] = [],
        audios: [JSONValue] = []
    ) {
        self.type = type
        self.url = url
        self.title = title
        self.description = description
        self.determiner = determiner
        self.siteName = siteName
        self.locale = locale
        self.images = images
        self.videos = videos
        self.audios = audios
    }

    enum CodingKeys: String, CodingKey {
        case type, url, title, description, determiner
        case siteName = "site_name"
        case locale, images, videos, audios
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.string(.type)
        url = c.string(.url)
        title = c.string(.title)
        description = c.string(.description)
        determiner = c.string(.determiner)
        siteName = c.string(.siteName)
        locale = c.string(.locale)
        images = c.array(Image.self, .images)
        videos = c.array(JSONValue.self, .videos)
        audios = c.array(JSONValue.self, .audios)
    }
}
