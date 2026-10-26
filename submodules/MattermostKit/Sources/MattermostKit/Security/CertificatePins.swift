import Foundation
import CryptoKit
import Security

/// Certificate pins per host (Phase 4G): SHA-256 digests of a certificate's SubjectPublicKeyInfo, the form
/// HPKP, OkHttp and TrustKit use (`sha256/<base64>`). A host with pins accepts a TLS connection only when the
/// system trusts the chain **and** some certificate in it (leaf, intermediate or root) has a pinned key. A host
/// without pins is evaluated by the system alone.
///
/// The pins come from managed app configuration (`MattermostManagedConfiguration.certificatePinsKey`). Accepted
/// forms, so an EMM console's string, string-list or dictionary fields all work:
/// - a string of entries separated by spaces, commas, semicolons or newlines;
/// - a list of such strings;
/// - a dictionary from host to a pin string or a list of pin strings.
///
/// An entry is `host=pin`; the pin is base64 (optionally prefixed with `sha256/`) of a 32-byte digest. The host
/// may be written as a URL (`https://chat.example.com:8443`); scheme, port and path are ignored. A host whose
/// entries are all malformed is kept with no valid pin, so connections to it fail (the configuration meant to
/// pin it) instead of silently falling back to the system's evaluation.
public struct MattermostCertificatePins: Equatable, Sendable, Codable {
    /// Lowercased host → base64 digests (re-encoded canonically). An empty set means "pinned, nothing valid".
    public private(set) var pinsByHost: [String: Set<String>]
    /// Entries that could not be read, for diagnostics (never contains a valid pin).
    public private(set) var problems: [String]

    public init(pinsByHost: [String: Set<String>] = [:], problems: [String] = []) {
        var normalized: [String: Set<String>] = [:]
        for (host, pins) in pinsByHost {
            guard let host = MattermostCertificatePins.normalizedHost(host) else {
                continue
            }
            normalized[host, default: []].formUnion(pins.compactMap(MattermostCertificatePins.normalizedPin))
        }
        self.pinsByHost = normalized
        self.problems = problems
    }

    public static let empty = MattermostCertificatePins()

    public var isEmpty: Bool {
        return self.pinsByHost.isEmpty
    }

    /// The pins of `host`; nil when the host is not pinned.
    public func pins(forHost host: String) -> Set<String>? {
        guard let host = MattermostCertificatePins.normalizedHost(host) else {
            return nil
        }
        return self.pinsByHost[host]
    }

    // MARK: Parsing

    /// Reads a managed configuration value (see the type's documentation); nil and unreadable values give no pins.
    public static func parse(_ value: Any?) -> MattermostCertificatePins {
        var pinsByHost: [String: Set<String>] = [:]
        var problems: [String] = []

        func add(host rawHost: String, pin rawPin: String) {
            guard let host = self.normalizedHost(rawHost) else {
                problems.append("no host in \"\(rawHost)=…\"")
                return
            }
            var pins = pinsByHost[host] ?? []
            if let pin = self.normalizedPin(rawPin) {
                pins.insert(pin)
            } else {
                problems.append("\(host): not a base64 SHA-256 digest")
            }
            pinsByHost[host] = pins
        }

        func addEntries(_ text: String) {
            for entry in self.entries(text) {
                guard let separator = entry.firstIndex(of: "=") else {
                    problems.append("not host=pin: \(entry.prefix(64))")
                    continue
                }
                let host = String(entry[..<separator])
                // Base64 may end in "=": the first "=" separates host and pin.
                let pin = String(entry[entry.index(after: separator)...])
                add(host: host, pin: pin)
            }
        }

        switch value {
        case let text as String:
            addEntries(text)
        case let list as [Any]:
            for item in list {
                if let text = item as? String {
                    addEntries(text)
                }
            }
        case let dictionary as [String: Any]:
            for (host, item) in dictionary {
                var pins: [String] = []
                if let text = item as? String {
                    pins = self.entries(text)
                } else if let list = item as? [Any] {
                    pins = list.compactMap { $0 as? String }.flatMap(self.entries)
                }
                if pins.isEmpty {
                    problems.append("\(host): no pins")
                    if let normalized = self.normalizedHost(host) {
                        pinsByHost[normalized] = pinsByHost[normalized] ?? []
                    }
                }
                for pin in pins {
                    add(host: host, pin: pin)
                }
            }
        default:
            break
        }
        return MattermostCertificatePins(pinsByHost: pinsByHost, problems: problems)
    }

    private static func entries(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        return text.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    static func normalizedHost(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.contains("://") {
            guard let parsed = URLComponents(string: host)?.host else {
                return nil
            }
            host = parsed
        } else if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        if host.hasPrefix("[") {
            // [IPv6]:port
            if let end = host.firstIndex(of: "]") {
                host = String(host[host.index(after: host.startIndex) ..< end])
            }
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host.isEmpty ? nil : host
    }

    static func normalizedPin(_ text: String) -> String? {
        var pin = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pin.lowercased().hasPrefix("sha256/") {
            pin = String(pin.dropFirst("sha256/".count))
        }
        // Accept base64url as well.
        pin = pin.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while pin.count % 4 != 0 {
            pin.append("=")
        }
        guard let data = Data(base64Encoded: pin), data.count == 32 else {
            return nil
        }
        return data.base64EncodedString()
    }

    // MARK: Certificates

    /// Base64 SHA-256 of the certificate's SubjectPublicKeyInfo (its DER encoding, as in the certificate).
    public static func spkiSHA256(certificate: SecCertificate) -> String? {
        let der = SecCertificateCopyData(certificate) as Data
        return self.spkiSHA256(certificateDER: der)
    }

    public static func spkiSHA256(certificateDER der: Data) -> String? {
        guard let spki = self.subjectPublicKeyInfo(certificateDER: der) else {
            return nil
        }
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// The DER encoding of the SubjectPublicKeyInfo of an X.509 certificate (the seventh field of
    /// TBSCertificate, counting the optional version), read with a minimal DER reader. Nil when the data is not
    /// a certificate.
    static func subjectPublicKeyInfo(certificateDER der: Data) -> Data? {
        let bytes = [UInt8](der)
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        guard let certificate = DERElement.read(bytes, at: 0), certificate.tag == 0x30 else {
            return nil
        }
        // TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, … }
        guard let tbs = DERElement.read(bytes, at: certificate.contentStart), tbs.tag == 0x30 else {
            return nil
        }
        var offset = tbs.contentStart
        var fields: [DERElement] = []
        while offset < tbs.end, fields.count < 7 {
            guard let element = DERElement.read(bytes, at: offset), element.end <= tbs.end else {
                return nil
            }
            fields.append(element)
            offset = element.end
        }
        if let first = fields.first, first.tag == 0xA0 {
            fields.removeFirst()
        }
        // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo
        guard fields.count >= 6, fields[5].tag == 0x30 else {
            return nil
        }
        let spki = fields[5]
        return Data(bytes[spki.start ..< spki.end])
    }
}

/// One DER TLV: its tag and where it and its content are.
private struct DERElement {
    let tag: UInt8
    let start: Int
    let contentStart: Int
    let end: Int

    static func read(_ bytes: [UInt8], at start: Int) -> DERElement? {
        var offset = start
        guard offset < bytes.count else {
            return nil
        }
        let tag = bytes[offset]
        offset += 1
        // Multi-byte tags don't occur in the fields read here.
        guard tag & 0x1F != 0x1F, offset < bytes.count else {
            return nil
        }
        let first = bytes[offset]
        offset += 1
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count >= 1, count <= 4, offset + count <= bytes.count else {
                return nil
            }
            for _ in 0 ..< count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard length >= 0, offset + length <= bytes.count else {
            return nil
        }
        return DERElement(tag: tag, start: start, contentStart: offset, end: offset + length)
    }
}
