import Foundation
import AppKit
import Combine
import ProjectMCPCore

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()
    @Published var settings = ConnectionSettings()
    @Published var apiKey = ""
    @Published var showSettings = false
    @Published var errorMessage: String?
    private let settingsStore: SettingsStore
    private let credentialStore: CredentialStore
    let runtime: RuntimeController
    private var subscriptions = Set<AnyCancellable>()
    private var restored = false
    private var credentialRevision = 0

    init(settingsStore: SettingsStore = SettingsStore(),
         credentialStore: CredentialStore = CredentialStore(),
         runtime: RuntimeController? = nil) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.runtime = runtime ?? RuntimeController()
        self.runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.objectWillChange.send()
            }.store(in: &subscriptions)
    }

    var projectName: String {
        settings.projectPath.isEmpty ? "选择项目" : URL(fileURLWithPath: settings.projectPath).lastPathComponent
    }
    var isRunning: Bool {
        switch runtime.state { case .starting, .ready, .stopping: return true; default: return false }
    }
    var isBusy: Bool {
        switch runtime.state { case .starting, .stopping: return true; default: return false }
    }
    var isReady: Bool { runtime.state == .ready }
    var statusText: String {
        if let errorMessage { return errorMessage }
        switch runtime.state {
        case .idle: return "未启动"
        case .starting: return "启动中"
        case .ready: return "本地就绪"
        case .stopping: return "停止中"
        case .failed(let message): return message
        }
    }
    var logs: String { runtime.diagnostics.redactedSummary() }

    func restore() {
        guard !restored else { return }
        restored = true
        do {
            guard let saved = try settingsStore.load() else { return }
            settings = saved
            if saved.rememberKey {
                // Keychain access may show an authorization prompt; read it off
                // the main thread so the window stays responsive and sized.
                let store = credentialStore
                let revision = credentialRevision
                Task.detached { [weak self] in
                    let key = try? store.read()
                    await self?.finishRestoringKey(key, revision: revision)
                }
                return
            }
            presentSettingsIfNeeded()
        } catch { errorMessage = error.localizedDescription; showSettings = true }
    }

    private func finishRestoringKey(_ key: String?, revision: Int) {
        guard revision == credentialRevision else { return }
        if let key { apiKey = key }
        presentSettingsIfNeeded()
    }

    private func presentSettingsIfNeeded() {
        guard settings.tunnelID.isEmpty || apiKey.isEmpty else { return }
        showSettings = true
    }

    func chooseProject() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择项目"
        panel.message = ""
        guard panel.runModal() == .OK else { return }
        applyProjectSelection(panel.url)
    }

    func applyProjectSelection(_ url: URL?) {
        guard !isRunning, let url else { return }
        var committed = settings
        committed.projectPath = url.path
        do {
            try settingsStore.save(committed)
            settings = committed
            errorMessage = nil
        } catch { errorMessage = "项目设置保存失败" }
    }

    func saveSettings(candidate: ConnectionSettings? = nil, key: String? = nil) {
        guard !isRunning else { return }
        var next = candidate ?? settings
        let nextKey = (key ?? apiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        next.tunnelID = next.tunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
        next.organizationID = next.organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next.tunnelID.hasPrefix("tunnel_"), !nextKey.isEmpty else {
            errorMessage = "请填写完整连接信息"; return
        }
        do {
            try credentialStore.update(key: nextKey, remember: next.rememberKey)
            try settingsStore.save(next)
            credentialRevision += 1
            settings = next
            apiKey = nextKey
            errorMessage = nil
            showSettings = false
        } catch { errorMessage = "连接设置保存失败" }
    }

    func toggleConnection() async {
        if isRunning { await stop(); return }
        guard !settings.projectPath.isEmpty else { chooseProject(); return }
        guard !apiKey.isEmpty, settings.tunnelID.hasPrefix("tunnel_") else {
            errorMessage = "请配置连接"; showSettings = true; return
        }
        errorMessage = nil
        guard let resources = Bundle.main.resourceURL else { errorMessage = "运行环境缺失"; return }
        await runtime.start(settings: settings, apiKey: apiKey, resourcesURL: resources)
    }

    func stop() async { await runtime.stop(); errorMessage = nil }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(runtime.diagnostics.redactedSummary(), forType: .string)
    }

}
