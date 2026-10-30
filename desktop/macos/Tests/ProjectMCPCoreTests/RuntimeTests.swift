import XCTest
import Foundation
import Darwin
@testable import ProjectMCPCore

final class LaunchAndHealthTests: XCTestCase {
    func testLaunchKeepsProjectAndSecretOutOfArgumentsAndJSON() throws {
        let config = LaunchConfiguration(runtimeURL: URL(fileURLWithPath: "/tmp/应用, a/runtime/tunnel-client"), serverDirectoryURL: URL(fileURLWithPath: "/tmp/应用, a/server"), projectPath: "/tmp/项目, a", tunnelID: "fake-tunnel", organizationID: "fake-org", healthURLFile: URL(fileURLWithPath: "/tmp/run/health"))
        let args = config.tunnelArguments
        XCTAssertTrue(args.contains("command=./project-mcp-server,channel=main"))
        XCTAssertTrue(args.contains("127.0.0.1:0"))
        XCTAssertFalse(args.joined().contains("项目"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(config), as: UTF8.self).contains("apiKey"))
        let env = config.environment(apiKey: "fake-key")
        XCTAssertEqual(env["PROJECT_ROOT"], "/tmp/项目, a")
        XCTAssertEqual(env["CONTROL_PLANE_API_KEY"], "fake-key")
        XCTAssertNil(env["OPENAI_API_KEY"])
    }
    func testHealthRejectsRemoteURLsCredentialsRedirectTargetsAndDefaultPort() throws {
        for raw in ["https://example.com", "http://localhost:1234", "http://127.0.0.1:8080", "http://127.0.0.1:1@evil.test:90", "file:///tmp/health", "http://127.0.0.1:1234/evil", "http://127.0.0.1:1234?key=x", "http://[::ffff:192.0.2.1]:1000"] {
            XCTAssertThrowsError(try HealthEndpoint.parse(raw), raw)
        }
        XCTAssertEqual(try HealthEndpoint.parse("http://127.0.0.1:43210\n").port, 43210)
        XCTAssertEqual(try HealthEndpoint.parse("http://[::1]:43211").path, "/readyz")
    }
    func testHealthFileEmptyDuringWriteAndSymlinkRejection() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let file = fixture.runDirectory.appendingPathComponent("health")
        try Data().write(to: file)
        XCTAssertNil(try HealthEndpoint.read(file))
        let link = fixture.runDirectory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try HealthEndpoint.read(link))
    }
}

final class SupervisorTests: XCTestCase {
    func testClosedSupervisorControlPipeCannotTerminateGUIWithSIGPIPE() async throws {
        let oldSignal = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, oldSignal) }
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let closed = fixture.root.appendingPathComponent("closed-control")
        try FileManager.default.copyItem(at: fixture.server.appendingPathComponent("project-mcp-server"), to: closed)
        let runner = ProcessRunner(supervisorURL: closed)
        let run = try runner.launch(fixture.configuration(), apiKey: "fake-key")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(run.exitResult)
        await runner.stop(run)
        XCTAssertNotNil(run.exitResult)
    }
    func testPreflightOnlyInitializesPingsAndListsThreeTools() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runner = ProcessRunner(supervisorURL: fixture.supervisorURL)
        try await RuntimePreflight(runner: runner).check(configuration: fixture.configuration())
        let calls = try String(contentsOf: fixture.server.appendingPathComponent("calls"))
        XCTAssertEqual(calls.components(separatedBy: .newlines).filter { !$0.isEmpty }, ["initialize", "notifications/initialized", "ping", "tools/list"])
    }
    func testRuntimeHelpMayBeLongAndWrittenToStderr() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.server.appendingPathComponent("help-stderr"))
        try await RuntimePreflight(runner: ProcessRunner(supervisorURL: fixture.supervisorURL)).check(configuration: fixture.configuration())
    }
    func testOldRuntimeIsRejectedBeforeServerPreflight() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.server.appendingPathComponent("help-old"))
        do {
            try await RuntimePreflight(runner: ProcessRunner(supervisorURL: fixture.supervisorURL)).check(configuration: fixture.configuration())
            XCTFail("Missing health flags must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("版本")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.server.appendingPathComponent("calls").path))
    }
    func testFragmentedAndUnterminatedOversizedLogsStayBoundedAndRedacted() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runner = ProcessRunner(supervisorURL: fixture.supervisorURL)
        let run = try runner.launch(fixture.configuration(tunnelID: "noisy"), apiKey: "fake-key")
        let logs = Task { () -> [String] in
            var messages: [String] = []
            for await event in run.events { if event.kind == .log, let message = event.message { messages.append(message) } }
            return messages
        }
        _ = try await fixture.waitForPIDs()
        for _ in 0..<40 {
            if run.processGroupID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(run.processGroupID, "Spawn event must arrive while child is alive")
        try await Task.sleep(nanoseconds: 200_000_000)
        await runner.stop(run)
        let messages = await logs.value
        XCTAssertTrue(messages.contains { $0.contains("split log") })
        XCTAssertTrue(messages.contains { $0.contains("超长日志") })
        XCTAssertTrue(messages.allSatisfy { $0.count <= 2048 && !$0.contains("fake-key") })
    }

    func testConflictDetectionRecognizesOnlyExecutableAndNeverStopsIt() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runner = ProcessRunner(supervisorURL: fixture.supervisorURL)
        let run = try runner.launch(fixture.configuration(), apiKey: "fake-key")
        let pids = try await fixture.waitForPIDs(run: run)
        XCTAssertTrue(TunnelConflictDetector.hasConflict())
        XCTAssertEqual(kill(pids[0], 0), 0)
        await runner.stop(run)
    }

    func testStopCleansOwnedDescendantsAndLeavesUnrelatedProcessAlive() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["60"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let runner = ProcessRunner(supervisorURL: fixture.supervisorURL)
        let run = try runner.launch(fixture.configuration(tunnelID: "stubborn"), apiKey: "fake-key")
        let pids = try await fixture.waitForPIDs(run: run)
        await runner.stop(run, graceSeconds: 0.15)
        XCTAssertNotNil(run.exitResult)
        try await assertEventuallyDead(pids)
        XCTAssertTrue(unrelated.isRunning)
        await runner.stop(run)
        unrelated.terminate()
        for _ in 0..<100 {
            if !unrelated.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(unrelated.isRunning)
    }

    func testGUIEOFAndSupervisorSignalCleanOwnedGroup() async throws {
        for useSignal in [false, true] {
            let fixture = try RuntimeFixture()
            defer { fixture.remove() }
            let runner = ProcessRunner(supervisorURL: fixture.supervisorURL)
            let run = try runner.launch(fixture.configuration(), apiKey: "fake-key")
            let pids = try await fixture.waitForPIDs(run: run)
            if useSignal { kill(run.pid, SIGTERM) } else { run.closeControl() }
            await run.waitForExit()
            try await assertEventuallyDead(pids)
        }
    }

    func testSupervisorEscapesBlockedSignalMaskOfLaunchingThread() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runner = ProcessRunner(supervisorURL: fixture.supervisorURL)
        // A blocked SIGTERM on the calling thread must not be inherited by the
        // supervisor, otherwise the signal stays pending and the stop hangs.
        let run = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OwnedRun, Error>) in
            DispatchQueue.global(qos: .utility).async {
                var blocked = sigset_t()
                sigemptyset(&blocked)
                sigaddset(&blocked, SIGTERM)
                var previous = sigset_t()
                pthread_sigmask(SIG_BLOCK, &blocked, &previous)
                defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
                do { continuation.resume(returning: try runner.launch(fixture.configuration(), apiKey: "fake-key")) }
                catch { continuation.resume(throwing: error) }
            }
        }
        let pids = try await fixture.waitForPIDs(run: run)
        kill(run.pid, SIGTERM)
        for _ in 0..<100 {
            if run.exitResult != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(run.exitResult, 0)
        if run.exitResult == nil { run.closeControl(); await run.waitForExit() }
        try await assertEventuallyDead(pids)
    }

    func testNormalLeaderExitStillCleansChildAndLogsCannotForgeEvents() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runner = ProcessRunner(supervisorURL: fixture.supervisorURL)
        let run = try runner.launch(fixture.configuration(tunnelID: "exit"), apiKey: "fake-key")
        let pids = try await fixture.waitForPIDs(run: run)
        var events: [SupervisorEvent] = []
        for await event in run.events { events.append(event) }
        await run.waitForExit()
        try await assertEventuallyDead(pids)
        XCTAssertTrue(events.contains { $0.kind == .log && ($0.message?.contains("spoof") ?? false) })
        XCTAssertFalse(events.contains { $0.kind == .preflightPassed })
    }
}

@MainActor final class RuntimeControllerTests: XCTestCase {
    func testCompetingControllersRefuseAndReleaseLockAfterStopOrFailure() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let lockURL = fixture.root.appendingPathComponent("launcher.lock")
        let first = RuntimeController(supervisorURL: fixture.supervisorURL, lockURL: lockURL, conflictDetector: { false })
        let second = RuntimeController(supervisorURL: fixture.supervisorURL, lockURL: lockURL, conflictDetector: { false })
        await first.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources)
        XCTAssertEqual(first.state, .ready)
        let pids = try await fixture.waitForPIDs()
        await second.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources)
        guard case .failed = second.state else { return XCTFail("Second launcher must refuse") }
        XCTAssertEqual(first.state, .ready)
        XCTAssertEqual(kill(pids[0], 0), 0)
        await first.stop()
        await second.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources)
        XCTAssertEqual(second.state, .ready)
        await second.stop()
        try Data().write(to: fixture.server.appendingPathComponent("fail-preflight"))
        await first.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources)
        guard case .failed = first.state else { return XCTFail("Preflight should fail") }
        try FileManager.default.removeItem(at: fixture.server.appendingPathComponent("fail-preflight"))
        await second.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources)
        XCTAssertEqual(second.state, .ready)
        await second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path), "Shared lock inode must never be unlinked")
    }
    func testReadyDuplicateStartStopAndRetry() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let controller = RuntimeController(supervisorURL: fixture.supervisorURL, lockURL: fixture.root.appendingPathComponent("launcher.lock"), conflictDetector: { false })
        let settings = fixture.settings()
        async let first: Void = controller.start(settings: settings, apiKey: "fake-key", resourcesURL: fixture.resources)
        async let duplicate: Void = controller.start(settings: settings, apiKey: "fake-key", resourcesURL: fixture.resources)
        _ = await (first, duplicate)
        XCTAssertEqual(controller.state, .ready)
        let pids = try await fixture.waitForPIDs()
        await controller.stop()
        XCTAssertEqual(controller.state, .idle)
        try await assertEventuallyDead(pids)
        try FileManager.default.removeItem(at: fixture.server.appendingPathComponent("pids"))
        await controller.start(settings: settings, apiKey: "fake-key", resourcesURL: fixture.resources)
        XCTAssertEqual(controller.state, .ready)
        await controller.stop()
    }
    func testPreflightFailureAndConflictNeverLaunchTunnel() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let conflict = RuntimeController(supervisorURL: fixture.supervisorURL, lockURL: fixture.root.appendingPathComponent("launcher.lock"), conflictDetector: { true })
        await conflict.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources)
        guard case .failed = conflict.state else { return XCTFail("Conflict must fail") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.server.appendingPathComponent("calls").path))
        try Data().write(to: fixture.server.appendingPathComponent("fail-preflight"))
        let controller = RuntimeController(supervisorURL: fixture.supervisorURL, lockURL: fixture.root.appendingPathComponent("launcher.lock"), conflictDetector: { false })
        await controller.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources)
        guard case .failed = controller.state else { return XCTFail("Preflight must fail") }
    }
    func testHealthTimeoutAndNetworkLossNeverLeaveReady() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let controller = RuntimeController(supervisorURL: fixture.supervisorURL, startupTimeout: 1, lockURL: fixture.root.appendingPathComponent("launcher.lock"), conflictDetector: { false })
        await controller.start(settings: fixture.settings(tunnelID: "unready"), apiKey: "fake-key", resourcesURL: fixture.resources)
        guard case .failed = controller.state else { return XCTFail("Timeout must fail") }
        await controller.start(settings: fixture.settings(tunnelID: "loss"), apiKey: "fake-key", resourcesURL: fixture.resources)
        XCTAssertEqual(controller.state, .ready)
        for _ in 0..<80 {
            if case .failed = controller.state { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard case .failed = controller.state else { return XCTFail("Lost readiness must fail") }
        XCTAssertFalse(controller.diagnostics.redactedSummary().contains("fake-key"))
        await controller.stop()
    }
    func testStopDuringPreflightThenRestartIgnoresStaleCompletion() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.server.appendingPathComponent("slow-preflight"))
        let controller = RuntimeController(supervisorURL: fixture.supervisorURL, lockURL: fixture.root.appendingPathComponent("launcher.lock"), conflictDetector: { false })
        let start = Task { await controller.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources) }
        try await Task.sleep(nanoseconds: 200_000_000)
        await controller.stop()
        await start.value
        XCTAssertEqual(controller.state, .idle)
        try FileManager.default.removeItem(at: fixture.server.appendingPathComponent("slow-preflight"))
        await controller.start(settings: fixture.settings(), apiKey: "fake-key", resourcesURL: fixture.resources)
        XCTAssertEqual(controller.state, .ready)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.state, .ready)
        await controller.stop()
    }
    func testUserStopDuringFailureCleanupEndsIdleAndConcurrentStopsWait() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let controller = RuntimeController(supervisorURL: fixture.supervisorURL, lockURL: fixture.root.appendingPathComponent("launcher.lock"), conflictDetector: { false })
        await controller.start(settings: fixture.settings(tunnelID: "loss-stubborn"), apiKey: "fake-key", resourcesURL: fixture.resources)
        XCTAssertEqual(controller.state, .ready)
        let pids = try await fixture.waitForPIDs()
        for _ in 0..<100 {
            if controller.state == .stopping { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(controller.state, .stopping)
        async let one: Void = controller.stop()
        async let two: Void = controller.stop()
        _ = await (one, two)
        XCTAssertEqual(controller.state, .idle)
        try await assertEventuallyDead(pids)
    }
}

func assertEventuallyDead(_ pids: [pid_t], file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<100 {
        if pids.allSatisfy({ kill($0, 0) != 0 }) { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Owned children still alive: \(pids.filter { kill($0, 0) == 0 })", file: file, line: line)
}

final class RuntimeFixture {
    let root: URL
    let resources: URL
    let server: URL
    let runDirectory: URL
    let supervisorURL: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Project MCP 测试, \(UUID())")
        resources = root.appendingPathComponent("Contents/Resources")
        server = resources.appendingPathComponent("server")
        runDirectory = root.appendingPathComponent("run")
        supervisorURL = Bundle(for: SupervisorTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ProjectMCPSupervisor")
        for dir in [server, resources.appendingPathComponent("runtime"), runDirectory, root.appendingPathComponent("项目, folder")] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [Bundle.module.url(forResource: "fixture", withExtension: "c", subdirectory: "Fixtures")!.path, "-o", server.appendingPathComponent("project-mcp-server").path]
        try compile.run(); compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { throw NSError(domain: "FixtureCompiler", code: 1) }
        try FileManager.default.copyItem(at: server.appendingPathComponent("project-mcp-server"), to: resources.appendingPathComponent("runtime/tunnel-client"))
    }
    func settings(tunnelID: String = "ready") -> ConnectionSettings {
        ConnectionSettings(projectPath: root.appendingPathComponent("项目, folder").path, tunnelID: tunnelID, organizationID: "fake-org")
    }
    func configuration(tunnelID: String = "ready") -> LaunchConfiguration {
        LaunchConfiguration(runtimeURL: resources.appendingPathComponent("runtime/tunnel-client"), serverDirectoryURL: server, projectPath: settings().projectPath, tunnelID: tunnelID, organizationID: "fake-org", healthURLFile: runDirectory.appendingPathComponent("health"))
    }
    func waitForPIDs(run: OwnedRun? = nil) async throws -> [pid_t] {
        // Controller owns a unique run directory; the fixture also records under its server cwd.
        for _ in 0..<100 {
            for url in [runDirectory.appendingPathComponent("pids"), server.appendingPathComponent("pids")] {
                if let value = try? String(contentsOf: url), value.split(separator: " ").count >= 2 {
                    return value.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        var messages: [String] = []
        if let run, run.exitResult != nil {
            for await event in run.events { messages.append("\(event.kind): \(event.message ?? "") status=\(event.status ?? -1)") }
        }
        throw NSError(domain: "MissingFixturePIDs", code: 1, userInfo: [NSLocalizedDescriptionKey: messages.joined(separator: "\n")])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
