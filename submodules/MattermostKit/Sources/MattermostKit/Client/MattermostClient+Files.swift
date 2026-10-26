import Foundation

/// A file to upload with `MattermostClient.uploadFiles(_:channelId:progress:)`.
public struct FileUpload: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case data(Data)
        /// A local file; streamed from disk.
        case file(URL)
    }

    /// Client-generated ID, echoed back in `FileUploadResponse.clientIds`.
    public var clientId: String
    public var fileName: String
    public var mimeType: String
    public var content: Content

    public init(clientId: String = UUID().uuidString.lowercased(), fileName: String, mimeType: String = "application/octet-stream", content: Content) {
        self.clientId = clientId
        self.fileName = fileName
        self.mimeType = mimeType
        self.content = content
    }
}

public struct UploadProgress: Sendable, Equatable {
    public var bytesSent: Int64
    public var totalBytes: Int64

    public init(bytesSent: Int64, totalBytes: Int64) {
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(bytesSent) / Double(totalBytes)) : 0
    }
}

/// Binary resources served by the API.
public enum MattermostResource: Sendable, Hashable {
    /// `GET /files/{file_id}`.
    case file(id: String)
    /// `GET /files/{file_id}/thumbnail`.
    case fileThumbnail(id: String)
    /// `GET /files/{file_id}/preview`.
    case filePreview(id: String)
    /// `GET /users/{user_id}/image`. Pass `User.lastPictureUpdate` to bust caches.
    case userImage(userId: String, lastPictureUpdate: Int64? = nil)
    /// `GET /emoji/{emoji_id}/image`.
    case emojiImage(emojiId: String)
    /// `GET /image?url=<url>`: an external image through the server's image proxy (`HasImageProxy` in the
    /// client config). Mattermost's clients build these URLs themselves; the server never rewrites embed images.
    case proxiedImage(url: String)

    var apiRequest: APIRequest {
        switch self {
        case .file(let id):
            return APIRequest(.get, apiPath("files", id), expectsJSON: false)
        case .fileThumbnail(let id):
            return APIRequest(.get, apiPath("files", id, "thumbnail"), expectsJSON: false)
        case .filePreview(let id):
            return APIRequest(.get, apiPath("files", id, "preview"), expectsJSON: false)
        case let .userImage(userId, lastPictureUpdate):
            var query = QueryBuilder()
            query.add("_", lastPictureUpdate)
            return APIRequest(.get, apiPath("users", userId, "image"), query: query.items, expectsJSON: false)
        case .emojiImage(let emojiId):
            return APIRequest(.get, apiPath("emoji", emojiId, "image"), expectsJSON: false)
        case .proxiedImage(let url):
            return APIRequest(.get, "/image", query: [URLQueryItem(name: "url", value: url)], expectsJSON: false)
        }
    }
}

// MARK: - Upload

extension MattermostClient {
    /// `POST /files` (multipart): uploads files to attach to a post in
    /// `channelId`. Cancel by cancelling the calling task (throws
    /// `MattermostError.cancelled`).
    ///
    /// - Parameter progress: Called with upload progress from URLSession's
    ///   delegate queue, and once more with the full size on success.
    public func uploadFiles(
        _ files: [FileUpload],
        channelId: String,
        progress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> FileUploadResponse {
        var form = MultipartFormData()
        // The server reads parts in order: channel_id first, and each client_id
        // before the file it belongs to.
        form.addField(name: "channel_id", value: channelId)
        for file in files {
            form.addField(name: "client_ids", value: file.clientId)
            let content: MultipartFormData.Content
            switch file.content {
            case .data(let data): content = .data(data)
            case .file(let url): content = .file(url)
            }
            form.addFile(name: "files", fileName: file.fileName, mimeType: file.mimeType, content: content)
        }

        var request = try urlRequest(for: APIRequest(.post, "/files"))
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        // Uploads of large files can take far longer than API calls.
        request.timeoutInterval = max(configuration.timeoutInterval, 300)
        let delegate = progress.map(UploadProgressDelegate.init)

        let data: Data
        let response: URLResponse
        var totalBytes: Int64 = 0
        do {
            if form.hasFileContent {
                let bodyURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MattermostKit-upload-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: bodyURL) }
                totalBytes = try form.writeBody(to: bodyURL)
                try Task.checkCancellation()
                (data, response) = try await session.upload(for: request, fromFile: bodyURL, delegate: delegate)
            } else {
                let body = try form.encodedData()
                totalBytes = Int64(body.count)
                (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
            }
        } catch {
            throw MattermostError.wrap(error, url: request.url)
        }
        _ = try validate(response: response, body: data)
        let result = try decode(FileUploadResponse.self, from: data)
        progress?(UploadProgress(bytesSent: totalBytes, totalBytes: totalBytes))
        return result
    }

    /// `GET /files/{file_id}/info`.
    public func fileInfo(id: String) async throws -> FileInfo {
        try await send(APIRequest(.get, apiPath("files", id, "info")))
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let handler: @Sendable (UploadProgress) -> Void

    init(_ handler: @escaping @Sendable (UploadProgress) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        handler(UploadProgress(bytesSent: totalBytesSent, totalBytes: totalBytesExpectedToSend))
    }
}

// MARK: - Download

extension MattermostClient {
    /// An authorised request for a resource, for callers that manage the
    /// transfer themselves (e.g. a media fetcher issuing `Range` requests).
    public func urlRequest(for resource: MattermostResource) throws -> URLRequest {
        try urlRequest(for: resource.apiRequest)
    }

    /// Downloads a resource into memory.
    public func data(for resource: MattermostResource) async throws -> Data {
        let (data, _) = try await perform(resource.apiRequest)
        return data
    }

    /// Downloads a resource to `destination`, replacing any existing file.
    @discardableResult
    public func download(_ resource: MattermostResource, to destination: URL) async throws -> HTTPURLResponse {
        let request = try urlRequest(for: resource.apiRequest)
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            throw MattermostError.wrap(error, url: request.url)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else {
            throw MattermostError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: temporaryURL)) ?? Data()
            throw MattermostError.from(response: http, body: body)
        }
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw MattermostError.transport(URLError(.cannotCreateFile))
        }
        return http
    }
}
