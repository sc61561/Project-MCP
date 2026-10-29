import Foundation
import Combine

public enum RuntimeState: Equatable, Sendable {
    case idle, starting, ready, stopping, failed(String)
    public var isRunning: Bool {
        switch self { case .starting, .ready, .stopping: return true; case .idle, .failed: return false }
    }
}

@MainActor public final class RuntimeController: ObservableObject {
    @Published public private(set) var state: RuntimeState = .idle
    public let diagnostics: DiagnosticBuffer
    private let supervisorURL: URL?
    private let startupTimeout: TimeInterval
    private let lockURL: URL?
    private var sessionLock: LauncherLock?
    private let conflictDetector: () -> Bool
    private var generation = UUID()
    private var runner: ProcessRunner?
    private var ownedRun: OwnedRun?
    private var startTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var runDirectory: URL?

    public init(supervisorURL: URL? = nil, startupTimeout: TimeInterval = 30, lockURL: URL? = nil, diagnostics: DiagnosticBuffer = DiagnosticBuffer(), conflictDetector: @escaping () -> Bool = TunnelConflictDetector.hasConflict) {
        self.supervisorURL = supervisorURL; self.startupTimeout = startupTimeout
        self.lockURL = lockURL
        self.diagnostics = diagnostics; self.conflictDetector = conflictDetector
    }

    /// Errors are presented through state and the sanitized diagnostic buffer.
    public func start(settings: ConnectionSettings, apiKey: String, resourcesURL: URL) async {
        guard !state.isRunning else { return }
        // A failed monitor may still be finishing its cleanup; await it before retry.
        if let old = monitorTask { await old.value; monitorTask = nil }
        guard !state.isRunning else { return }
        state = .starting
        let token = UUID(); generation = token
        diagnostics.configure(secrets: [apiKey], paths: [settings.projectPath, resourcesURL.path])
        let task = Task { await performStart(settings: settings, apiKey: apiKey, resourcesURL: resourcesURL, token: token) }
        startTask = task
        await task.value
    }

    private func performStart(settings: ConnectionSettings, apiKey: String, resourcesURL: URL, token: UUID) async {
        let deadline = Date().addingTimeInterval(startupTimeout)
        var localRun: OwnedRun?
        var localRunner: ProcessRunner?
        var localLock: LauncherLock?
        var directory: URL?
        do {
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !apiKey.contains("\0"),
                  !settings.tunnelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !settings.organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeError.invalidConfiguration }
            let exclusive = try LauncherLock(url: lockURL ?? LauncherLock.defaultURL)
            localLock = exclusive; sessionLock = exclusive
            guard !conflictDetector() else { throw RuntimeError.conflict }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("project-mcp-\(token.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = temp; runDirectory = temp
            let helper = supervisorURL ?? resourcesURL.deletingLastPathComponent().appendingPathComponent("MacOS/ProjectMCPSupervisor")
            let runner = ProcessRunner(supervisorURL: helper); self.runner = runner; localRunner = runner
            let configuration = LaunchConfiguration(runtimeURL: resourcesURL.appendingPathComponent("runtime/tunnel-client"), serverDirectoryURL: resourcesURL.appendingPathComponent("server"), projectPath: settings.projectPath, tunnelID: settings.tunnelID, organizationID: settings.organizationID, healthURLFile: temp.appendingPathComponent("health-url"), id: token)
            try await RuntimePreflight(runner: runner).check(configuration: configuration)
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            guard Date() < deadline else { throw RuntimeError.timeout }
            // Recheck after preflight, narrowing the race with an external client.
            guard !conflictDetector() else { throw RuntimeError.conflict }
            let run = try runner.launch(configuration, apiKey: apiKey)
            localRun = run; ownedRun = run
            logTask = Task { [weak self] in
                for await event in run.events {
                    guard let self, self.generation == token else { continue }
                    if let message = event.message { self.diagnostics.append(message) }
                }
            }
            let health = HealthClient()
            var endpoint: URL?
            while Date() < deadline {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                guard run.exitResult == nil else { throw RuntimeError.exited }
                endpoint = try HealthEndpoint.read(configuration.healthURLFile)
                if let endpoint, run.processGroupID != nil, await health.ready(endpoint) {
                    try Task.checkCancellation()
                    guard generation == token, run.exitResult == nil else { throw RuntimeError.exited }
                    state = .ready
                    monitorTask = Task { [weak self] in
                        await self?.monitor(run: run, runner: runner, endpoint: endpoint, health: health, token: token, directory: temp)
                    }
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw RuntimeError.timeout
        } catch {
            if let run = localRun, let runner = localRunner { await runner.stop(run) }
            if let directory { try? FileManager.default.removeItem(at: directory) }
            localLock?.release()
            guard generation == token else { return }
            sessionLock = nil
            ownedRun = nil; runner = nil; runDirectory = nil
            if error is CancellationError { state = .idle }
            else {
                let message = error is RuntimeError ? error.localizedDescription : "本地运行失败，请查看诊断"
                diagnostics.append(error.localizedDescription)
                state = .failed(message)
            }
        }
    }

    private func monitor(run: OwnedRun, runner: ProcessRunner, endpoint: URL, health: HealthClient, token: UUID, directory: URL) async {
        var failures = 0
        while generation == token && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard generation == token && !Task.isCancelled else { return }
            let responseReady = await health.ready(endpoint)
            let ready = run.exitResult == nil && responseReady
            failures = ready ? 0 : failures + 1
            if run.exitResult != nil || failures >= 3 {
                let message = RuntimeError.exited.localizedDescription
                diagnostics.append(message)
                state = .stopping
                await runner.stop(run)
                try? FileManager.default.removeItem(at: directory)
                guard generation == token else { return }
                sessionLock?.release(); sessionLock = nil
                ownedRun = nil; self.runner = nil; runDirectory = nil
                state = .failed(message)
                return
            }
        }
    }

    public func stop() async {
        if let stopTask { await stopTask.value; return }
        generation = UUID()
        state = .stopping
        let starting = startTask
        let monitoring = monitorTask
        starting?.cancel(); monitoring?.cancel(); logTask?.cancel()
        let task = Task {
            if let run = ownedRun, let runner { await runner.stop(run) }
            await starting?.value
            await monitoring?.value
            if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
            sessionLock?.release(); sessionLock = nil
            ownedRun = nil; runner = nil; runDirectory = nil
            startTask = nil; monitorTask = nil; logTask = nil
            stopTask = nil
            state = .idle
        }
        stopTask = task
        await task.value
    }
}
