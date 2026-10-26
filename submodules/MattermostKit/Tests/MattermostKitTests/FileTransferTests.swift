import XCTest
@testable import MattermostKit

final class FileTransferTests: StubbedClientTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MattermostKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try super.tearDownWithError()
    }

    // MARK: Multipart

    func testMultipartBodyShape() throws {
        var form = MultipartFormData(boundary: "BOUNDARY")
        form.addField(name: "channel_id", value: "c1")
        form.addField(name: "client_ids", value: "client-1")
        form.addFile(name: "files", fileName: "notes \"v2\".txt", mimeType: "text/plain", content: .data(Data("hello world".utf8)))
        let body = String(decoding: try form.encodedData(), as: UTF8.self)
        let expected = [
            "--BOUNDARY",
            "Content-Disposition: form-data; name=\"channel_id\"",
            "",
            "c1",
            "--BOUNDARY",
            "Content-Disposition: form-data; name=\"client_ids\"",
            "",
            "client-1",
            "--BOUNDARY",
            "Content-Disposition: form-data; name=\"files\"; filename=\"notes %22v2%22.txt\"",
            "Content-Type: text/plain",
            "",
            "hello world",
            "--BOUNDARY--",
            "",
        ].joined(separator: "\r\n")
        XCTAssertEqual(body, expected)
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=BOUNDARY")
        XCTAssertFalse(form.hasFileContent)
    }

    func testMultipartStreamsFileToDisk() throws {
        let source = temporaryDirectory.appendingPathComponent("source.bin")
        let payload = Data((0..<(3 << 20)).map { UInt8($0 % 251) })
        try payload.write(to: source)
        var form = MultipartFormData(boundary: "B")
        form.addFile(name: "files", fileName: "source.bin", mimeType: "application/octet-stream", content: .file(source))
        XCTAssertTrue(form.hasFileContent)

        let destination = temporaryDirectory.appendingPathComponent("body")
        let written = try form.writeBody(to: destination)
        let body = try Data(contentsOf: destination)
        XCTAssertEqual(Int64(body.count), written)
        XCTAssertEqual(body, try form.encodedData())
        XCTAssertNotNil(body.range(of: payload))
    }

    // MARK: Upload

    /// Splits a multipart body into (headers, content) pairs.
    private func parts(of body: Data, boundary: String) -> [(headers: String, content: String)] {
        let text = String(decoding: body, as: UTF8.self)
        return text.components(separatedBy: "--\(boundary)")
            .dropFirst()
            .filter { !$0.hasPrefix("--") }
            .map { chunk in
                // Drop the leading and trailing CRLF ("\r\n" is a single Character).
                let trimmed = String(chunk.dropFirst().dropLast())
                let pieces = trimmed.components(separatedBy: "\r\n\r\n")
                return (pieces[0], pieces.dropFirst().joined(separator: "\r\n\r\n"))
            }
    }

    func testUploadSendsMultipartAndDecodesResponse() async throws {
        StubURLProtocol.respond(with: .json(Fixtures.fileUploadResponse, status: 201))
        let progress = Locked<[UploadProgress]>([])
        let response = try await makeClient().uploadFiles(
            [
                FileUpload(clientId: "client-1", fileName: "notes.txt", mimeType: "text/plain", content: .data(Data("hello world".utf8))),
                FileUpload(clientId: "client-2", fileName: "photo.jpg", mimeType: "image/jpeg", content: .data(Data([0xFF, 0xD8, 0xFF]))),
            ],
            channelId: "c1",
            progress: { value in progress.withLock { $0.append(value) } }
        )
        XCTAssertEqual(response.clientIds, ["client-1", "client-2"])
        XCTAssertEqual(response.fileInfos.count, 2)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v4/files")
        XCTAssertEqual(request.header("Authorization"), "Bearer tok3n")
        let contentType = try XCTUnwrap(request.header("Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))

        let body = try XCTUnwrap(request.body)
        let parts = parts(of: body, boundary: boundary)
        XCTAssertEqual(parts.map(\.headers), [
            "Content-Disposition: form-data; name=\"channel_id\"",
            "Content-Disposition: form-data; name=\"client_ids\"",
            "Content-Disposition: form-data; name=\"files\"; filename=\"notes.txt\"\r\nContent-Type: text/plain",
            "Content-Disposition: form-data; name=\"client_ids\"",
            "Content-Disposition: form-data; name=\"files\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg",
        ])
        XCTAssertEqual(parts[0].content, "c1")
        XCTAssertEqual(parts[1].content, "client-1")
        XCTAssertEqual(parts[2].content, "hello world")
        XCTAssertEqual(parts[3].content, "client-2")

        let final = try XCTUnwrap(progress.current.last)
        XCTAssertEqual(final.fractionCompleted, 1)
        XCTAssertEqual(final.totalBytes, Int64(body.count))
    }

    func testUploadFromFile() async throws {
        let source = temporaryDirectory.appendingPathComponent("doc.pdf")
        try Data("%PDF-1.4 test".utf8).write(to: source)
        StubURLProtocol.respond(with: .json(Fixtures.fileUploadResponse, status: 201))
        _ = try await makeClient().uploadFiles([FileUpload(clientId: "c-1", fileName: "doc.pdf", mimeType: "application/pdf", content: .file(source))], channelId: "c1")
        let body = try XCTUnwrap(StubURLProtocol.lastRequest?.body)
        XCTAssertNotNil(body.range(of: Data("%PDF-1.4 test".utf8)))
        XCTAssertNotNil(body.range(of: Data("filename=\"doc.pdf\"".utf8)))
    }

    func testUploadErrorIsMapped() async {
        StubURLProtocol.respond(with: .json(#"{"id":"api.file.upload_file.too_large_detailed.app_error","message":"Too large","status_code":413}"#, status: 413))
        let error = await expectMattermostError {
            try await self.makeClient().uploadFiles([FileUpload(fileName: "a", content: .data(Data([1])))], channelId: "c1")
        }
        XCTAssertEqual(error?.statusCode, 413)
        XCTAssertEqual(error?.appError?.id, "api.file.upload_file.too_large_detailed.app_error")
    }

    func testUploadCancellation() async {
        var slow = StubResponse.json(Fixtures.fileUploadResponse)
        slow.delay = 5
        StubURLProtocol.respond(with: slow)
        let client = makeClient()
        let task = Task {
            try await client.uploadFiles([FileUpload(fileName: "a", content: .data(Data(repeating: 1, count: 1024)))], channelId: "c1")
        }
        await waitUntil { StubURLProtocol.lastRequest != nil }
        task.cancel()
        let started = Date()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? MattermostError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    // MARK: Download

    func testResourcePaths() throws {
        let client = makeClient()
        func url(_ resource: MattermostResource) throws -> String {
            try XCTUnwrap(client.urlRequest(for: resource).url?.absoluteString)
        }
        XCTAssertEqual(try url(.file(id: "f1")), "https://chat.example.com/api/v4/files/f1")
        XCTAssertEqual(try url(.fileThumbnail(id: "f1")), "https://chat.example.com/api/v4/files/f1/thumbnail")
        XCTAssertEqual(try url(.filePreview(id: "f1")), "https://chat.example.com/api/v4/files/f1/preview")
        XCTAssertEqual(try url(.userImage(userId: "u1", lastPictureUpdate: 1_700_000_600_000)), "https://chat.example.com/api/v4/users/u1/image?_=1700000600000")
        XCTAssertEqual(try url(.userImage(userId: "u1")), "https://chat.example.com/api/v4/users/u1/image")
        XCTAssertEqual(try url(.emojiImage(emojiId: "e1")), "https://chat.example.com/api/v4/emoji/e1/image")
        XCTAssertEqual(try client.urlRequest(for: .file(id: "f1")).value(forHTTPHeaderField: "Authorization"), "Bearer tok3n")
    }

    func testDataDownload() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        StubURLProtocol.respond(with: StubResponse(statusCode: 200, headers: ["Content-Type": "image/png"], body: png))
        let data = try await makeClient().data(for: .fileThumbnail(id: "f1"))
        XCTAssertEqual(data, png)
        XCTAssertEqual(StubURLProtocol.lastRequest?.path, "/api/v4/files/f1/thumbnail")
        XCTAssertNil(StubURLProtocol.lastRequest?.header("Accept"))
    }

    func testDownloadToFileReplacesExisting() async throws {
        let destination = temporaryDirectory.appendingPathComponent("avatar.png")
        try Data("old".utf8).write(to: destination)
        StubURLProtocol.respond(with: StubResponse(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data("new image".utf8)))
        let response = try await makeClient().download(.userImage(userId: "u1"), to: destination)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new image".utf8))
    }

    func testDownloadErrorDoesNotWriteFile() async {
        let destination = temporaryDirectory.appendingPathComponent("missing.bin")
        StubURLProtocol.respond(with: .json(#"{"id":"app.file_info.get.app_error","message":"Not found","status_code":404}"#, status: 404))
        let error = await expectMattermostError { try await self.makeClient().download(.file(id: "nope"), to: destination) }
        XCTAssertEqual(error?.appError?.id, "app.file_info.get.app_error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
