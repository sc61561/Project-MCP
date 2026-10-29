import XCTest
@testable import ProjectMCPCore

final class SettingsAndDiagnosticsTests: XCTestCase {
    func testSettingsRoundTripNeverPersistsKey() throws {
        let name = "ProjectMCPTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(try store.load())
        let settings = ConnectionSettings(projectPath: "/tmp/项目, folder", tunnelID: "test-tunnel", organizationID: "test-org", rememberKey: false)
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(encoded.lowercased().contains("apikey"))
        XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]).keys), ["projectPath", "tunnelID", "organizationID", "rememberKey"])
    }

    func testCredentialErrorsPropagateAndRememberOffDeletesOnlyCredential() throws {
        let backend = MemoryCredentials()
        let store = CredentialStore(backend: backend)
        try store.save("fake-secret")
        XCTAssertEqual(try store.read(), "fake-secret")
        try store.update(key: "session-only", remember: false)
        XCTAssertNil(try store.read())
        backend.denied = true
        XCTAssertThrowsError(try store.update(key: "fake-secret", remember: true))
        XCTAssertNil(backend.value)
    }

    func testDiagnosticsBoundLinesAndRedactBeforeTruncating() {
        let buffer = DiagnosticBuffer(secrets: ["fake-key-123"], paths: ["/tmp/项目, folder"])
        buffer.append("Authorization: Bearer abcdef token=hidden api_key=other /Users/person/Private File /tmp/项目, folder fake-key-123")
        let summary = buffer.redactedSummary()
        for value in ["abcdef", "hidden", "other", "person", "项目", "fake-key-123"] {
            XCTAssertFalse(summary.contains(value), value)
        }
        for n in 0..<250 { buffer.append("\(n) " + String(repeating: "中", count: 3000)) }
        XCTAssertEqual(buffer.snapshot().count, 200)
        XCTAssertTrue(buffer.snapshot().allSatisfy { $0.count <= 2048 })
        XCTAssertTrue(buffer.snapshot().first!.hasPrefix("50 "))
    }

    func testRedactsJSONCredentialsAndMultilineInput() {
        let buffer = DiagnosticBuffer()
        buffer.append("{\"Authorization\":\"Bearer fake-json\",\"access_token\":\"fake-token\",\"apiKey\":\"fake-key\"}\nline2")
        XCTAssertEqual(buffer.snapshot().count, 2)
        for value in ["fake-json", "fake-token", "fake-key"] { XCTAssertFalse(buffer.redactedSummary().contains(value)) }
    }
}

final class MemoryCredentials: CredentialBackend {
    var value: String?
    var denied = false
    func read() throws -> String? { if denied { throw CredentialError.accessDenied }; return value }
    func save(_ key: String) throws { if denied { throw CredentialError.accessDenied }; value = key }
    func delete() throws { if denied { throw CredentialError.accessDenied }; value = nil }
}
