import XCTest
import AppKit
import ProjectMCPCore
@testable import ProjectMCPApp

@MainActor final class AppControllerTests: XCTestCase {
    private func makeApp() -> (AppController, SettingsStore, TestCredentials, UserDefaults, String) {
        let name = "ProjectMCPAppTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let settings = SettingsStore(defaults: defaults)
        let backend = TestCredentials()
        let app = AppController(settingsStore: settings, credentialStore: CredentialStore(backend: backend), runtime: RuntimeController(conflictDetector: { false }))
        return (app, settings, backend, defaults, name)
    }

    func testIncompleteConfigurationCannotPersistCredential() async throws {
        let (app, store, key, defaults, name) = makeApp()
        defer { defaults.removePersistentDomain(forName: name) }
        app.settings = ConnectionSettings(tunnelID: "tunnel_test", organizationID: "", rememberKey: true)
        app.apiKey = "fake-key"
        app.showSettings = true
        app.saveSettings()
        XCTAssertTrue(app.showSettings)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertNil(try store.load())
        XCTAssertEqual(key.writes, 0)
    }

    func testRestoreWithoutRememberNeverReadsKeychain() async throws {
        let (app, store, key, defaults, name) = makeApp()
        defer { defaults.removePersistentDomain(forName: name) }
        try store.save(ConnectionSettings(tunnelID: "tunnel_test", organizationID: "org-test", rememberKey: false))
        app.restore()
        XCTAssertEqual(key.reads, 0)
        XCTAssertEqual(app.apiKey, "")
        XCTAssertTrue(app.showSettings)
    }

    func testFailedCredentialSaveDoesNotPersistOrCloseSettings() async throws {
        let (app, store, key, defaults, name) = makeApp()
        defer { defaults.removePersistentDomain(forName: name) }
        key.denied = true
        app.settings = ConnectionSettings(tunnelID: "tunnel_test", organizationID: "org-test", rememberKey: true)
        app.apiKey = "fake-key"
        app.showSettings = true
        app.saveSettings()
        XCTAssertTrue(app.showSettings)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertNil(try store.load())
    }

    func testRememberOffRemovesStoredKeyAndSavesOnlyNonSecretSettings() async throws {
        let (app, store, key, defaults, name) = makeApp()
        defer { defaults.removePersistentDomain(forName: name) }
        key.value = "old-fake-key"
        app.settings = ConnectionSettings(tunnelID: "tunnel_test", organizationID: "org-test", rememberKey: false)
        app.apiKey = "session-fake-key"
        app.showSettings = true
        app.saveSettings()
        XCTAssertNil(key.value)
        XCTAssertFalse(app.showSettings)
        XCTAssertEqual(try store.load(), app.settings)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(app.settings), as: UTF8.self).contains("session-fake-key"))
    }

    func testFailedDraftSaveKeepsCommittedPreferenceAndProjectSelectionOnlyChangesProject() async throws {
        let (app, store, key, defaults, name) = makeApp()
        defer { defaults.removePersistentDomain(forName: name) }
        let committed = ConnectionSettings(projectPath: "/tmp/old", tunnelID: "tunnel_original", organizationID: "org-original", rememberKey: true)
        app.settings = committed
        try store.save(committed)
        key.value = "fake-stored-key"
        key.denied = true
        let draft = ConnectionSettings(projectPath: "/tmp/old", tunnelID: "tunnel_unsaved", organizationID: "org-unsaved", rememberKey: false)
        app.saveSettings(candidate: draft, key: "fake-draft-key")
        XCTAssertEqual(app.settings, committed)
        XCTAssertEqual(try store.load(), committed)
        XCTAssertEqual(key.value, "fake-stored-key")
        app.applyProjectSelection(URL(fileURLWithPath: "/tmp/new"))
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.projectPath, "/tmp/new")
        XCTAssertTrue(saved.rememberKey)
        XCTAssertEqual(saved.tunnelID, "tunnel_original")
        app.applyProjectSelection(nil)
        XCTAssertEqual(try store.load(), saved)
    }

    func testWindowCloseDelegateInstallsWithoutGlassBackground() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let behavior = WindowBehaviorView()
        window.contentView = behavior
        XCTAssertTrue(window.delegate is WindowCloseDelegate)
        // Programmatic windows default to releasedWhenClosed; under ARC that over-releases on close.
        XCTAssertFalse(window.isReleasedWhenClosed)
        window.close()
    }

    func testWindowRetainsNativeDraggableTitleBar() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = WindowBehaviorView()
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.titlebarAppearsTransparent)
        window.close()
    }
}

private final class TestCredentials: CredentialBackend {
    var value: String?
    var reads = 0
    var writes = 0
    var denied = false
    func read() throws -> String? { reads += 1; return value }
    func save(_ key: String) throws { if denied { throw CredentialError.accessDenied }; writes += 1; value = key }
    func delete() throws { if denied { throw CredentialError.accessDenied }; value = nil }
}
