import Foundation
import Darwin

public final class OwnedRun: @unchecked Sendable {
    public let id: UUID
    /// PID of the supervisor. Only that supervisor may signal its child process group.
    public let pid: Int32
    public let createdAt = Date()
    public let events: AsyncStream<SupervisorEvent>
    private let continuation: AsyncStream<SupervisorEvent>.Continuation
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    private var closed = false
    private var group: Int32?
    private var result: Int32?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var processGroupID: Int32? { lock.lock(); defer { lock.unlock() }; return group }
    public var exitResult: Int32? { lock.lock(); defer { lock.unlock() }; return result }

    fileprivate init(id: UUID, process: Process, input: FileHandle) {
        self.id = id; self.process = process; self.pid = process.processIdentifier; self.input = input
        var sink: AsyncStream<SupervisorEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { sink = $0 }
        continuation = sink
    }
    fileprivate func receive(_ event: SupervisorEvent) {
        guard event.id == id else { return }
        if event.kind == .spawned { lock.lock(); group = event.pid; lock.unlock() }
        continuation.yield(event)
    }
    fileprivate func finish(_ status: Int32) {
        lock.lock(); result = status; let pending = waiters; waiters.removeAll(); lock.unlock()
        closeControl(); continuation.finish()
        for waiter in pending { waiter.resume() }
    }
    fileprivate func requestStop(graceSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if var data = try? JSONEncoder().encode(StopCommand(graceSeconds: graceSeconds)) {
            data.append(10); try? input.write(contentsOf: data)
        }
        try? input.close(); closed = true
    }
    /// Closing this writer is also how GUI termination is communicated to the supervisor.
    public func closeControl() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try? input.close(); closed = true
    }
    public func waitForExit() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if result != nil { lock.unlock(); waiter.resume() }
            else { waiters.append(waiter); lock.unlock() }
        }
    }
}

public final class ProcessRunner: @unchecked Sendable {
    private let supervisorURL: URL
    private let lock = NSLock()
    private var runs: [UUID: OwnedRun] = [:]
    public init(supervisorURL: URL) { self.supervisorURL = supervisorURL }
    deinit { for run in runs.values { run.closeControl() } }

    public func launch(_ configuration: LaunchConfiguration, apiKey: String = "") throws -> OwnedRun {
        try configuration.validate()
        let process = Process(), control = Pipe(), output = Pipe()
        // The peer may exit between the ownership check and a stop/config write.
        // Suppress SIGPIPE on this descriptor only, returning EPIPE as an error.
        guard fcntl(control.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw RuntimeError.system(errno) }
        process.executableURL = supervisorURL
        process.arguments = []
        process.currentDirectoryURL = configuration.serverDirectoryURL
        process.environment = configuration.environment(apiKey: configuration.mode == .tunnel ? apiKey : nil)
        process.standardInput = control
        process.standardOutput = output
        // No unframed output is trusted, retained, or printed by the UI.
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? control.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let run = OwnedRun(id: configuration.id, process: process, input: control.fileHandleForWriting)
        lock.lock(); runs[run.id] = run; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            var discarding = false
            while true {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let chunk = bytes.prefix(count)
                for byte in chunk {
                    if byte == 10 {
                        if !discarding, let event = try? JSONDecoder().decode(SupervisorEvent.self, from: buffer) { run.receive(event) }
                        buffer.removeAll(keepingCapacity: true); discarding = false
                    } else if buffer.count < 32768 && !discarding { buffer.append(byte) }
                    else { buffer.removeAll(keepingCapacity: true); discarding = true }
                }
            }
            try? output.fileHandleForReading.close()
            process.waitUntilExit()
            run.finish(process.terminationStatus)
            self?.remove(run.id)
        }
        do {
            var frame = try JSONEncoder().encode(configuration); frame.append(10)
            try control.fileHandleForWriting.write(contentsOf: frame)
        } catch { run.closeControl(); throw error }
        return run
    }
    private func remove(_ id: UUID) { lock.lock(); runs.removeValue(forKey: id); lock.unlock() }
    private func owns(_ run: OwnedRun) -> Bool { lock.lock(); defer { lock.unlock() }; return runs[run.id] === run }
    public func stop(_ run: OwnedRun, graceSeconds: Double = 5) async {
        if owns(run) { run.requestStop(graceSeconds: graceSeconds.isFinite ? min(5, max(0, graceSeconds)) : 5) }
        await run.waitForExit()
    }
}

public final class RuntimePreflight: @unchecked Sendable {
    private let runner: ProcessRunner
    public init(runner: ProcessRunner) { self.runner = runner }
    public func check(configuration: LaunchConfiguration) async throws {
        var config = configuration; config.id = UUID(); config.mode = .preflight
        let run = try runner.launch(config)
        let deadline = Date().addingTimeInterval(30)
        // Reader remains independent so a stuck child cannot stall cancellation or timeout.
        let success = Task { () -> (Bool, String?) in
            var passed = false
            var failure: String?
            for await event in run.events {
                if event.kind == .preflightPassed { passed = true }
                if event.kind == .failure { failure = event.message }
            }
            return (passed, failure)
        }
        while run.exitResult == nil && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if Task.isCancelled || run.exitResult == nil { await runner.stop(run) }
        let (passed, failure) = await success.value
        if let failure { throw RuntimeError.reported(failure) }
        guard !Task.isCancelled, passed, run.exitResult == 0 else { throw RuntimeError.preflight }
    }
}
