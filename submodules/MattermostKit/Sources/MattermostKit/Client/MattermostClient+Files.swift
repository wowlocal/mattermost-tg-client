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
        retryState: UploadRetryState = UploadRetryState(),
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
        let uploadRequest = request
        let delegate = UploadProgressDelegate(progress, diagnostic: configuration.onDiagnostic)
        let started = ProcessInfo.processInfo.systemUptime
        configuration.onDiagnostic?("upload start channel=\(channelId) files=\(files.count) bodyInactivity=\(configuration.uploadInactivityTimeout)s responseAllowance=\(request.timeoutInterval)s")

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
                (data, response) = try await uploadWithActivityTimeout(delegate: delegate, totalBytes: totalBytes, retryState: retryState, responseTimeout: request.timeoutInterval) {
                    try await self.session.upload(for: uploadRequest, fromFile: bodyURL, delegate: delegate)
                }
            } else {
                let body = try form.encodedData()
                totalBytes = Int64(body.count)
                (data, response) = try await uploadWithActivityTimeout(delegate: delegate, totalBytes: totalBytes, retryState: retryState, responseTimeout: request.timeoutInterval) {
                    try await self.session.upload(for: uploadRequest, from: body, delegate: delegate)
                }
            }
        } catch {
            configuration.onDiagnostic?("upload failed channel=\(channelId) after \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))ms bytes=\(delegate.bytesSent) code=\((error as NSError).code)")
            if let urlError = error as? URLError, urlError.code == .timedOut, delegate.exhaustedResponseAllowance(elapsedRequest: ProcessInfo.processInfo.systemUptime - started, allowance: request.timeoutInterval) {
                throw MattermostError.uploadStalled(.responseWait)
            }
            throw MattermostError.wrap(error, url: request.url)
        }
        configuration.onDiagnostic?("upload response channel=\(channelId) after \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))ms bytes=\(totalBytes) status=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        _ = try validate(response: response, body: data)
        let result = try decode(FileUploadResponse.self, from: data)
        progress?(UploadProgress(bytesSent: totalBytes, totalBytes: totalBytes))
        return result
    }

    private func uploadWithActivityTimeout(delegate: UploadProgressDelegate, totalBytes: Int64, retryState: UploadRetryState, responseTimeout: TimeInterval, operation: @escaping @Sendable () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        let timeout = max(0.01, configuration.uploadInactivityTimeout)
        delegate.resetActivity(totalBytes: totalBytes)
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await operation() }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: UInt64(min(1, timeout) * 1_000_000_000))
                    if let stall = delegate.stall(timeout: timeout, responseTimeout: responseTimeout, health: self.configuration.uploadConnectionHealth, retryState: retryState) {
                        self.configuration.onDiagnostic?("upload stalled: \(stall.reason), bytes=\(delegate.bytesSent)")
                        throw MattermostError.uploadStalled(stall.kind)
                    }
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// `GET /files/{file_id}/info`.
    public func fileInfo(id: String) async throws -> FileInfo {
        try await send(APIRequest(.get, apiPath("files", id, "info")))
    }
}

struct UploadActivity {
    private(set) var bytesSent: Int64 = 0
    private(set) var totalBytes: Int64
    private(set) var lastProgressAt: TimeInterval

    init(now: TimeInterval, totalBytes: Int64 = .max) {
        self.lastProgressAt = now
        self.totalBytes = totalBytes
    }

    var bodySent: Bool { bytesSent >= totalBytes }

    func exhaustedResponseAllowance(elapsedRequest: TimeInterval, allowance: TimeInterval) -> Bool {
        return self.bodySent && elapsedRequest >= allowance
    }

    mutating func record(bytesSent: Int64, now: TimeInterval, sentBodyBytes: Int64 = 0) {
        if bytesSent != self.bytesSent || sentBodyBytes > 0 {
            self.bytesSent = bytesSent
            self.lastProgressAt = now
        }
    }

    func isStalled(now: TimeInterval, timeout: TimeInterval) -> Bool {
        return !bodySent && now - lastProgressAt >= timeout
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let handler: (@Sendable (UploadProgress) -> Void)?
    private let diagnostic: (@Sendable (String) -> Void)?
    private let activity = Locked(UploadActivity(now: ProcessInfo.processInfo.systemUptime))

    init(_ handler: (@Sendable (UploadProgress) -> Void)?, diagnostic: (@Sendable (String) -> Void)? = nil) {
        self.handler = handler
        self.diagnostic = diagnostic
    }

    var bytesSent: Int64 { activity.current.bytesSent }
    func exhaustedResponseAllowance(elapsedRequest: TimeInterval, allowance: TimeInterval) -> Bool {
        return activity.current.exhaustedResponseAllowance(elapsedRequest: elapsedRequest, allowance: allowance)
    }
    func resetActivity(totalBytes: Int64) { activity.set(UploadActivity(now: ProcessInfo.processInfo.systemUptime, totalBytes: totalBytes)) }
    func stall(timeout: TimeInterval, responseTimeout: TimeInterval, health: UploadConnectionHealth, retryState: UploadRetryState) -> (reason: String, kind: UploadStall)? {
        let activity = self.activity.current
        let now = ProcessInfo.processInfo.systemUptime
        if activity.isStalled(now: now, timeout: timeout) {
            return ("no body progress for \(timeout)s", .bodyProgress)
        }
        if activity.bodySent, now - activity.lastProgressAt >= responseTimeout {
            return ("response wait exhausted \(responseTimeout)s", .responseWait)
        }
        if activity.bodySent, let evidence = health.evidence(after: activity.lastProgressAt), retryState.claimEvidenceRestart() {
            return (evidence.reason + " after last upload progress (single restart)", .connectionReplaced(evidence.reason))
        }
        return nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let previous = activity.current
        activity.withLock { $0.record(bytesSent: totalBytesSent, now: ProcessInfo.processInfo.systemUptime, sentBodyBytes: bytesSent) }
        if totalBytesSent < previous.bytesSent { diagnostic?("upload body restarted bytes=\(totalBytesSent)") }
        if !previous.bodySent && activity.current.bodySent { diagnostic?("upload body sent bytes=\(totalBytesSent); waiting for response") }
        handler?(UploadProgress(bytesSent: totalBytesSent, totalBytes: totalBytesExpectedToSend))
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
