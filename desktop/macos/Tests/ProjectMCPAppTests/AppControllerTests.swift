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
        app.settings = ConnectionSettings(tunnelID: "", organizationID: "", rememberKey: true)
        app.apiKey = "fake-key"
        app.showSettings = true
        app.saveSettings()
        XCTAssertTrue(app.showSettings)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertNil(try store.load())
        XCTAssertEqual(key.writes, 0)
    }

    func testConfigurationCanBeSavedWithoutOrganization() async throws {
        let (app, store, _, defaults, name) = makeApp()
        defer { defaults.removePersistentDomain(forName: name) }
        app.showSettings = true
        app.saveSettings(candidate: ConnectionSettings(tunnelID: "tunnel_test"), key: "fake-key")
        XCTAssertFalse(app.showSettings)
        XCTAssertEqual(try store.load()?.organizationID, "")
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

    func testFirstLaunchDoesNotOpenSettings() async {
        let (app, _, key, defaults, name) = makeApp()
        defer { defaults.removePersistentDomain(forName: name) }
        app.restore()
        XCTAssertFalse(app.showSettings)
        XCTAssertEqual(key.reads, 0)
    }

    func testLateKeychainReadDoesNotReplaceNewlySavedKey() async throws {
        let name = "ProjectMCPAppTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        try store.save(ConnectionSettings(tunnelID: "tunnel_old", rememberKey: true))
        let backend = DelayedCredentials(readValue: "old-fake-key")
        let app = AppController(settingsStore: store, credentialStore: CredentialStore(backend: backend), runtime: RuntimeController(conflictDetector: { false }))
        app.restore()
        let started = await Task.detached { backend.waitForStart() }.value
        XCTAssertTrue(started)
        app.saveSettings(candidate: ConnectionSettings(tunnelID: "tunnel_new"), key: "new-fake-key")
        XCTAssertEqual(app.apiKey, "new-fake-key")
        backend.finishRead.signal()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(app.apiKey, "new-fake-key")
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

    func testWindowCloseCanMinimizeInsteadOfClosing() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = WindowCloseDelegate(minimizeOnClose: { true })
        XCTAssertFalse(delegate.windowShouldClose(window))
        window.close()
    }

    func testCloseButtonMinimizesTheActualWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let behavior = WindowBehaviorView()
        behavior.closeHandler = WindowCloseDelegate(minimizeOnClose: { true })
        window.contentView = behavior
        window.makeKeyAndOrderFront(nil)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        button.performClick(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(window.isMiniaturized)
        window.close()
    }

    func testWindowCloseCanUseNormalCloseWhenIdle() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = WindowCloseDelegate(minimizeOnClose: { false })
        XCTAssertTrue(delegate.windowShouldClose(window))
        window.close()
    }

    func testWindowRetainsNativeDraggableTitleBar() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = WindowBehaviorView()
        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(window.isOpaque)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
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

private final class DelayedCredentials: CredentialBackend, @unchecked Sendable {
    let readStarted = DispatchSemaphore(value: 0)
    let finishRead = DispatchSemaphore(value: 0)
    let readValue: String?
    init(readValue: String? = nil) { self.readValue = readValue }
    func waitForStart() -> Bool { readStarted.wait(timeout: .now() + 2) == .success }
    func read() throws -> String? {
        readStarted.signal()
        _ = finishRead.wait(timeout: .now() + 2)
        return readValue
    }
    func save(_ key: String) throws {}
    func delete() throws {}
}
