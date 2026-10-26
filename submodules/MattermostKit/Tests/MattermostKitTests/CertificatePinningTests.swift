import Foundation
import Security
import XCTest
@testable import MattermostKit

/// Certificate pins (Phase 4G): parsing the managed value, reading a certificate's SubjectPublicKeyInfo, and the
/// trust decision for a chain. The certificates are generated for each run with `/usr/bin/openssl` (a test CA and
/// a leaf for `test.relay.invalid`) in a temporary directory; nothing is committed. The expected pins are
/// computed by openssl itself, the way an administrator would (`openssl x509 -pubkey | openssl pkey -pubin
/// -outform der | openssl dgst -sha256 -binary | base64`).
final class CertificatePinningTests: XCTestCase {
    private static let host = "test.relay.invalid"

    private struct TestPKI {
        let caDER: Data
        let leafDER: Data
        let otherDER: Data
        let ecDER: Data
        let v1DER: Data
        let caPin: String
        let leafPin: String
        let otherPin: String
        let ecPin: String
        let v1Pin: String
    }

    private static var pkiResult: Result<TestPKI, Error>?

    private func pki() throws -> TestPKI {
        if CertificatePinningTests.pkiResult == nil {
            CertificatePinningTests.pkiResult = Result { try CertificatePinningTests.makePKI() }
        }
        return try CertificatePinningTests.pkiResult!.get()
    }

    private static func makePKI() throws -> TestPKI {
        let openssl = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: openssl) else {
            throw XCTSkip("no \(openssl)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-pin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = """
        [req]
        distinguished_name = dn
        [dn]
        [v3_ca]
        basicConstraints = critical, CA:TRUE
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        [v3_leaf]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = DNS:\(host)
        """
        try config.write(to: directory.appendingPathComponent("openssl.cnf"), atomically: true, encoding: .utf8)
        let script = """
        set -e
        O=\(openssl)
        $O req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 -sha256 -subj "/CN=Relay Test CA" -config openssl.cnf -extensions v3_ca 2>/dev/null
        for name in leaf other; do
          $O req -newkey rsa:2048 -nodes -keyout $name.key -out $name.csr -sha256 -subj "/CN=\(host)" -config openssl.cnf 2>/dev/null
          $O x509 -req -in $name.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out $name.pem -days 30 -sha256 -extfile openssl.cnf -extensions v3_leaf 2>/dev/null
        done
        $O ecparam -name prime256v1 -genkey -noout -out ec.key
        $O req -new -x509 -key ec.key -out ec.pem -days 30 -sha256 -subj "/CN=ec.\(host)" -config openssl.cnf 2>/dev/null
        $O req -newkey rsa:2048 -nodes -keyout v1.key -out v1.csr -sha256 -subj "/CN=v1.\(host)" -config openssl.cnf 2>/dev/null
        $O x509 -req -in v1.csr -signkey v1.key -out v1.pem -days 30 -sha256 2>/dev/null
        for name in ca leaf other ec v1; do
          $O x509 -in $name.pem -outform der -out $name.der
          $O x509 -in $name.pem -pubkey -noout | $O pkey -pubin -outform der | $O dgst -sha256 -binary | base64 > $name.pin
        done
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("openssl could not generate the test certificates (status \(process.terminationStatus))")
        }
        func der(_ name: String) throws -> Data {
            return try Data(contentsOf: directory.appendingPathComponent("\(name).der"))
        }
        func pin(_ name: String) throws -> String {
            return try String(contentsOf: directory.appendingPathComponent("\(name).pin"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return TestPKI(caDER: try der("ca"), leafDER: try der("leaf"), otherDER: try der("other"), ecDER: try der("ec"), v1DER: try der("v1"), caPin: try pin("ca"), leafPin: try pin("leaf"), otherPin: try pin("other"), ecPin: try pin("ec"), v1Pin: try pin("v1"))
    }

    private func certificate(_ der: Data) throws -> SecCertificate {
        return try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }

    /// A server trust for `host` with the leaf (and the CA as intermediate), trusting only `anchors`.
    private func trust(chain: [Data], anchors: [Data], host: String = CertificatePinningTests.host) throws -> SecTrust {
        let certificates = try chain.map { try self.certificate($0) }
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
        let result = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(result, try anchors.map { try self.certificate($0) } as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(result, true), errSecSuccess)
        return result
    }

    // MARK: SubjectPublicKeyInfo

    func testSPKIDigestMatchesOpenSSL() throws {
        let pki = try self.pki()
        XCTAssertEqual(MattermostCertificatePins.spkiSHA256(certificateDER: pki.caDER), pki.caPin)
        XCTAssertEqual(MattermostCertificatePins.spkiSHA256(certificateDER: pki.leafDER), pki.leafPin)
        XCTAssertEqual(MattermostCertificatePins.spkiSHA256(certificateDER: pki.ecDER), pki.ecPin, "EC P-256 key")
        XCTAssertEqual(MattermostCertificatePins.spkiSHA256(certificateDER: pki.v1DER), pki.v1Pin, "X.509 v1: no version field")
        XCTAssertEqual(MattermostCertificatePins.spkiSHA256(certificate: try self.certificate(pki.leafDER)), pki.leafPin)
        XCTAssertNotEqual(pki.leafPin, pki.otherPin)
    }

    func testSPKIOfGarbageIsNil() {
        XCTAssertNil(MattermostCertificatePins.spkiSHA256(certificateDER: Data()))
        XCTAssertNil(MattermostCertificatePins.spkiSHA256(certificateDER: Data([0x30, 0x82, 0xFF, 0xFF, 0x30])))
        XCTAssertNil(MattermostCertificatePins.spkiSHA256(certificateDER: Data("not a certificate".utf8)))
    }

    // MARK: Trust decisions

    func testUnpinnedHostIsLeftToTheSystem() throws {
        let pki = try self.pki()
        let policy = MattermostServerTrust(pins: MattermostCertificatePins.parse("other.example.com=\(pki.leafPin)"))
        XCTAssertEqual(policy.evaluate(try self.trust(chain: [pki.leafDER, pki.caDER], anchors: [pki.caDER]), host: CertificatePinningTests.host), .systemDefault)
        XCTAssertEqual(MattermostServerTrust().evaluate(try self.trust(chain: [pki.leafDER, pki.caDER], anchors: [pki.caDER]), host: CertificatePinningTests.host), .systemDefault, "no pins at all")
    }

    func testLeafPinAccepts() throws {
        let pki = try self.pki()
        let policy = MattermostServerTrust(pins: MattermostCertificatePins.parse("\(CertificatePinningTests.host)=sha256/\(pki.leafPin)"))
        XCTAssertEqual(policy.evaluate(try self.trust(chain: [pki.leafDER, pki.caDER], anchors: [pki.caDER]), host: CertificatePinningTests.host), .accept)
        XCTAssertFalse(policy.wasRecentlyRejected(host: CertificatePinningTests.host))
    }

    func testCAPinAcceptsAnyLeafItIssued() throws {
        let pki = try self.pki()
        let policy = MattermostServerTrust(pins: MattermostCertificatePins.parse("\(CertificatePinningTests.host)=\(pki.caPin)"))
        XCTAssertEqual(policy.evaluate(try self.trust(chain: [pki.leafDER, pki.caDER], anchors: [pki.caDER]), host: CertificatePinningTests.host), .accept)
        XCTAssertEqual(policy.evaluate(try self.trust(chain: [pki.otherDER, pki.caDER], anchors: [pki.caDER]), host: CertificatePinningTests.host), .accept)
    }

    func testWrongPinRejects() throws {
        let pki = try self.pki()
        // The server presents the "other" leaf; only "leaf" is pinned (a replaced or intercepted certificate).
        let policy = MattermostServerTrust(pins: MattermostCertificatePins.parse("\(CertificatePinningTests.host)=\(pki.leafPin)"))
        XCTAssertEqual(policy.evaluate(try self.trust(chain: [pki.otherDER, pki.caDER], anchors: [pki.caDER]), host: CertificatePinningTests.host), .reject)
        XCTAssertTrue(policy.wasRecentlyRejected(host: CertificatePinningTests.host.uppercased()))
        XCTAssertFalse(policy.wasRecentlyRejected(host: "other.example.com"))
        // New pins forget earlier rejections.
        policy.setPins(.empty)
        XCTAssertFalse(policy.wasRecentlyRejected(host: CertificatePinningTests.host))
    }

    func testMatchingPinOnAnUntrustedChainRejects() throws {
        let pki = try self.pki()
        let policy = MattermostServerTrust(pins: MattermostCertificatePins.parse("\(CertificatePinningTests.host)=\(pki.leafPin)"))
        // The test CA is not an anchor: the system doesn't trust the chain, so the pin alone doesn't help.
        XCTAssertEqual(policy.evaluate(try self.trust(chain: [pki.leafDER, pki.caDER], anchors: [pki.ecDER]), host: CertificatePinningTests.host), .reject)
        // Wrong host name for the certificate.
        XCTAssertEqual(policy.evaluate(try self.trust(chain: [pki.leafDER, pki.caDER], anchors: [pki.caDER], host: "elsewhere.relay.invalid"), host: CertificatePinningTests.host), .reject)
    }

    func testHostWithOnlyMalformedPinsFailsClosed() throws {
        let pki = try self.pki()
        let pins = MattermostCertificatePins.parse("\(CertificatePinningTests.host)=notbase64!! \(CertificatePinningTests.host)=AAAA")
        XCTAssertEqual(pins.pins(forHost: CertificatePinningTests.host), [])
        XCTAssertEqual(pins.problems.count, 2)
        let policy = MattermostServerTrust(pins: pins)
        XCTAssertEqual(policy.evaluate(try self.trust(chain: [pki.leafDER, pki.caDER], anchors: [pki.caDER]), host: CertificatePinningTests.host), .reject)
    }

    func testPinMismatchError() {
        let error = MattermostServerTrust.pinMismatchError(host: "chat.example.com")
        XCTAssertEqual(error.code, .serverCertificateUntrusted)
        XCTAssertEqual(error.mattermostPinMismatchHost, "chat.example.com")
        XCTAssertNil(URLError(.serverCertificateUntrusted).mattermostPinMismatchHost)
    }

    // MARK: Parsing

    private let pinA = Data(repeating: 0xA1, count: 32).base64EncodedString()
    private let pinB = Data(repeating: 0xB2, count: 32).base64EncodedString()

    func testParseStringForms() {
        let pins = MattermostCertificatePins.parse("Chat.Example.com=sha256/\(pinA), chat.example.com=\(pinB);files.example.com=\(pinA)\nhttps://other.example.com:8443/path=\(pinB)")
        XCTAssertEqual(pins.pins(forHost: "chat.example.com"), [pinA, pinB])
        XCTAssertEqual(pins.pins(forHost: "CHAT.EXAMPLE.COM."), [pinA, pinB])
        XCTAssertEqual(pins.pins(forHost: "files.example.com"), [pinA])
        XCTAssertEqual(pins.pins(forHost: "other.example.com"), [pinB])
        XCTAssertNil(pins.pins(forHost: "example.com"))
        XCTAssertTrue(pins.problems.isEmpty)
    }

    func testParseListAndDictionary() {
        let list = MattermostCertificatePins.parse(["chat.example.com=\(pinA)", "chat.example.com:443=\(pinB)"])
        XCTAssertEqual(list.pins(forHost: "chat.example.com"), [pinA, pinB])

        let dictionary = MattermostCertificatePins.parse(["chat.example.com": [pinA, "sha256/\(pinB)"], "files.example.com": "\(pinB)", "empty.example.com": ""] as [String: Any])
        XCTAssertEqual(dictionary.pins(forHost: "chat.example.com"), [pinA, pinB])
        XCTAssertEqual(dictionary.pins(forHost: "files.example.com"), [pinB])
        XCTAssertEqual(dictionary.pins(forHost: "empty.example.com"), [], "listed without pins: pinned, fails closed")
    }

    func testParseBase64URLAndUnpadded() {
        let digest = Data((0 ..< 32).map { UInt8($0 * 7 & 0xFF) | 0x80 })
        let standard = digest.base64EncodedString()
        let url = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(MattermostCertificatePins.parse("chat.example.com=\(url)").pins(forHost: "chat.example.com"), [standard])
    }

    func testParseProblems() {
        let pins = MattermostCertificatePins.parse("justtext =\(pinA) chat.example.com=\(Data(repeating: 1, count: 20).base64EncodedString())")
        XCTAssertEqual(pins.problems.count, 3)
        XCTAssertEqual(pins.pins(forHost: "chat.example.com"), [])
        XCTAssertTrue(MattermostCertificatePins.parse(nil).isEmpty)
        XCTAssertTrue(MattermostCertificatePins.parse(42).isEmpty)
        XCTAssertTrue(MattermostCertificatePins.parse("").isEmpty)
    }

    func testCodableRoundTrip() throws {
        let pins = MattermostCertificatePins.parse("chat.example.com=\(pinA) files.example.com=\(pinB)")
        let decoded = try JSONDecoder().decode(MattermostCertificatePins.self, from: JSONEncoder().encode(pins))
        XCTAssertEqual(decoded, pins)
    }

    // MARK: Sessions

    func testDefaultSessionsApplyThePinsAndRenew() {
        let before = MattermostURLSession.current
        XCTAssertTrue(before.delegate is MattermostServerTrustDelegate)
        let client = MattermostClient(serverURL: URL(string: "https://chat.example.com")!)
        XCTAssertTrue(client.session === before)
        // New pins: a new session (no kept-alive connection or TLS session opened under the old pins is reused).
        MattermostURLSession.renew()
        XCTAssertFalse(MattermostURLSession.current === before)
        XCTAssertTrue(client.session === MattermostURLSession.current, "clients follow the renewed session")
        XCTAssertTrue(MattermostURLSession.current.delegate is MattermostServerTrustDelegate)
    }
}
