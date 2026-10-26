import Foundation

/// A `multipart/form-data` body. Parts are written in order; file parts can be
/// streamed from disk so large uploads are never fully loaded into memory.
struct MultipartFormData {
    enum Content {
        case data(Data)
        case file(URL)
    }

    enum Part {
        case field(name: String, value: String)
        case file(name: String, fileName: String, mimeType: String, content: Content)
    }

    let boundary: String
    private(set) var parts: [Part] = []

    init(boundary: String = "MattermostKit-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Whether any part is backed by a file on disk.
    var hasFileContent: Bool {
        parts.contains { part in
            if case .file(_, _, _, .file) = part { return true }
            return false
        }
    }

    mutating func addField(name: String, value: String) {
        parts.append(.field(name: name, value: value))
    }

    mutating func addFile(name: String, fileName: String, mimeType: String, content: Content) {
        parts.append(.file(name: name, fileName: fileName, mimeType: mimeType, content: content))
    }

    /// The whole body in memory.
    func encodedData() throws -> Data {
        var data = Data()
        try write { data.append($0) }
        return data
    }

    /// Streams the body into a file. Returns the number of bytes written.
    @discardableResult
    func writeBody(to url: URL) throws -> Int64 {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written: Int64 = 0
        try write { chunk in
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
        }
        return written
    }

    private func write(_ sink: (Data) throws -> Void) throws {
        for part in parts {
            switch part {
            case let .field(name, value):
                try sink(Data("--\(boundary)\r\n".utf8))
                try sink(Data("Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n".utf8))
                try sink(Data(value.utf8))
                try sink(Data("\r\n".utf8))
            case let .file(name, fileName, mimeType, content):
                try sink(Data("--\(boundary)\r\n".utf8))
                try sink(Data("Content-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(fileName))\"\r\n".utf8))
                try sink(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
                switch content {
                case .data(let data):
                    try sink(data)
                case .file(let url):
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                        try sink(chunk)
                    }
                }
                try sink(Data("\r\n".utf8))
            }
        }
        try sink(Data("--\(boundary)--\r\n".utf8))
    }

    /// Quoted-string escaping for header parameters (as browsers do).
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}
