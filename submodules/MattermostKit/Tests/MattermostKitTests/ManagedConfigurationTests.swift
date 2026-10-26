import Foundation
import XCTest
@testable import MattermostKit

/// Managed app configuration (Phase 4G): Mattermost's EMM keys as an MDM delivers them (all strings in
/// Mattermost's documentation; plists from other consoles carry booleans and numbers).
final class ManagedConfigurationTests: XCTestCase {
    func testNoConfiguration() {
        let configuration = MattermostManagedConfiguration(dictionary: nil)
        XCTAssertEqual(configuration, .none)
        XCTAssertFalse(configuration.isManaged)
        XCTAssertTrue(configuration.allowOtherServers)
        XCTAssertNil(configuration.restrictedServerURL)
        XCTAssertTrue(configuration.allowsServer(URL(string: "https://anything.example.com")!))
    }

    func testMattermostStringValues() {
        let configuration = MattermostManagedConfiguration(dictionary: [
            "serverUrl": " https://Chat.Example.com/ ",
            "serverName": "Example Chat",
            "allowOtherServers": "false",
            "username": "alice",
            "inAppPinCode": "true",
            "blurApplicationScreen": "TRUE",
            "copyAndPasteProtection": "true",
            "jailbreakDetection": "false",
            "vendor": "Example Corp",
            "useVPN": "true",
            "timeoutVPN": "30000",
            "somethingElse": "x"
        ])
        XCTAssertTrue(configuration.isManaged)
        XCTAssertEqual(configuration.serverURL, "https://Chat.Example.com/")
        XCTAssertEqual(configuration.managedServerURL?.absoluteString, "https://chat.example.com")
        XCTAssertEqual(configuration.serverName, "Example Chat")
        XCTAssertFalse(configuration.allowOtherServers)
        XCTAssertEqual(configuration.username, "alice")
        XCTAssertTrue(configuration.inAppPinCode)
        XCTAssertTrue(configuration.blurApplicationScreen)
        XCTAssertTrue(configuration.copyAndPasteProtection)
        XCTAssertFalse(configuration.jailbreakDetection)
        XCTAssertEqual(configuration.vendor, "Example Corp")
        XCTAssertEqual(configuration.ignoredKeys, ["somethingElse", "timeoutVPN", "useVPN"])
    }

    func testBooleanAndNumberValues() {
        let configuration = MattermostManagedConfiguration(dictionary: [
            "allowOtherServers": false,
            "inAppPinCode": NSNumber(value: 1),
            "blurApplicationScreen": "yes",
            "copyAndPasteProtection": "maybe",
            "serverUrl": "chat.example.com"
        ])
        XCTAssertFalse(configuration.allowOtherServers)
        XCTAssertTrue(configuration.inAppPinCode)
        XCTAssertTrue(configuration.blurApplicationScreen)
        XCTAssertFalse(configuration.copyAndPasteProtection, "unreadable: the default")
        XCTAssertEqual(configuration.managedServerURL?.absoluteString, "https://chat.example.com")
    }

    func testEmptyStringsAreUnset() {
        let configuration = MattermostManagedConfiguration(dictionary: ["serverUrl": "", "username": "  ", "allowOtherServers": ""])
        XCTAssertNil(configuration.serverURL)
        XCTAssertNil(configuration.username)
        XCTAssertTrue(configuration.allowOtherServers)
        XCTAssertFalse(configuration.isManaged)
    }

    func testServerRestriction() {
        let configuration = MattermostManagedConfiguration(dictionary: ["serverUrl": "https://chat.example.com/mattermost", "allowOtherServers": "false"])
        XCTAssertEqual(configuration.restrictedServerURL?.absoluteString, "https://chat.example.com/mattermost")
        XCTAssertTrue(configuration.allowsServer(URL(string: "https://CHAT.example.com:443/mattermost/")!))
        XCTAssertTrue(configuration.allowsServer("chat.example.com/mattermost"))
        XCTAssertFalse(configuration.allowsServer(URL(string: "https://chat.example.com")!), "another path is another server")
        XCTAssertFalse(configuration.allowsServer(URL(string: "https://chat.example.com:8443/mattermost")!))
        XCTAssertFalse(configuration.allowsServer(URL(string: "https://evil.example.com/mattermost")!))
        XCTAssertFalse(configuration.allowsServer("not a server"))
    }

    func testRestrictionNeedsAServer() {
        let configuration = MattermostManagedConfiguration(dictionary: ["allowOtherServers": "false"])
        XCTAssertNil(configuration.restrictedServerURL)
        XCTAssertTrue(configuration.allowsServer(URL(string: "https://anything.example.com")!))
    }

    func testOtherServersAllowedByDefault() {
        let configuration = MattermostManagedConfiguration(dictionary: ["serverUrl": "https://chat.example.com"])
        XCTAssertNil(configuration.restrictedServerURL)
        XCTAssertTrue(configuration.allowsServer(URL(string: "https://other.example.com")!))
        XCTAssertTrue(configuration.isManagedServer(URL(string: "https://chat.example.com/")!))
        XCTAssertFalse(configuration.isManagedServer(URL(string: "https://other.example.com")!))
    }

    func testLocalHTTPServerComparesWithoutScheme() {
        // A debug build's local server: the login may settle on http:// for a managed address without a scheme.
        let configuration = MattermostManagedConfiguration(dictionary: ["serverUrl": "localhost:8065", "allowOtherServers": "false"])
        XCTAssertTrue(configuration.allowsServer(URL(string: "http://localhost:8065")!))
        XCTAssertFalse(configuration.allowsServer(URL(string: "http://127.0.0.1:8065")!))
        XCTAssertTrue(MattermostManagedConfiguration.isSameServer(URL(string: "http://example.com")!, URL(string: "http://example.com:80")!))
        XCTAssertFalse(MattermostManagedConfiguration.isSameServer(URL(string: "http://example.com")!, URL(string: "https://example.com")!), "default ports differ")
    }

    func testCertificatePins() {
        let pin = Data(repeating: 7, count: 32).base64EncodedString()
        let configuration = MattermostManagedConfiguration(dictionary: ["relayCertificatePins": ["chat.example.com=sha256/\(pin)"]])
        XCTAssertTrue(configuration.isManaged)
        XCTAssertEqual(configuration.certificatePins.pins(forHost: "chat.example.com"), [pin])
    }

    func testSharedCopyKeepsOnlyWhatExtensionsUse() throws {
        let pin = Data(repeating: 9, count: 32).base64EncodedString()
        let configuration = MattermostManagedConfiguration(dictionary: [
            "serverUrl": "https://chat.example.com",
            "allowOtherServers": "false",
            "username": "alice",
            "inAppPinCode": "true",
            "vendor": "Example Corp",
            "relayCertificatePins": "chat.example.com=\(pin)"
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-managed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try configuration.writeShared(directory: directory)
        let shared = try XCTUnwrap(MattermostManagedConfiguration.readShared(directory: directory))
        XCTAssertEqual(shared.certificatePins, configuration.certificatePins)
        XCTAssertEqual(shared.restrictedServerURL, configuration.restrictedServerURL)
        XCTAssertNil(shared.username)
        XCTAssertNil(shared.vendor)
        XCTAssertFalse(shared.inAppPinCode)

        // Unmanaged again: the copy is removed.
        try MattermostManagedConfiguration.none.writeShared(directory: directory)
        XCTAssertNil(MattermostManagedConfiguration.readShared(directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MattermostManagedConfiguration.sharedFileName).path))
    }
}
