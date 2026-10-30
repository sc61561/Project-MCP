import Foundation
import Darwin

public final class OwnedRun: @unchecked Sendable {
    public let id: UUID
    /// PID of the supervisor. Only that supervisor may signal its child process group.
    public let pid: Int32
    public let createdAt = Date()
    public let events: AsyncStream<SupervisorEvent>
    private let continuation: AsyncStream<SupervisorEvent>.Continuation
    fileprivate let input: FileHandle
    private let lock = NSLock()
    private var closed = false
    private var group: Int32?
    private var result: Int32?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var processGroupID: Int32? { lock.lock(); defer { lock.unlock() }; return group }
    public var exitResult: Int32? { lock.lock(); defer { lock.unlock() }; return result }

    fileprivate init(id: UUID, pid: Int32, input: FileHandle) {
        self.id = id; self.pid = pid; self.input = input
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
        var controlPipe: [Int32] = [0, 0]
        var outputPipe: [Int32] = [0, 0]
        guard pipe(&controlPipe) == 0 else { throw RuntimeError.system(errno) }
        guard pipe(&outputPipe) == 0 else {
            close(controlPipe[0]); close(controlPipe[1])
            throw RuntimeError.system(errno)
        }
        // The peer may exit between the ownership check and a stop/config write.
        // Suppress SIGPIPE on this descriptor only, returning EPIPE as an error.
        guard fcntl(controlPipe[1], F_SETNOSIGPIPE, 1) == 0 else {
            for fd in controlPipe + outputPipe { close(fd) }
            throw RuntimeError.system(errno)
        }
        let nullFD = open("/dev/null", O_WRONLY)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        // A blocked signal mask on whichever executor thread calls launch would be
        // inherited by the supervisor, leaving SIGTERM pending forever. Give it a
        // clean mask and default dispositions; the supervisor installs its own.
        var signalMask = sigset_t()
        var defaultSignals = sigset_t()
        sigemptyset(&signalMask)
        sigemptyset(&defaultSignals)
        for signalNumber in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaultSignals, signalNumber) }
        let environment = configuration.environment(apiKey: configuration.mode == .tunnel ? apiKey : nil)
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(supervisorURL.path), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv + envp { if let pointer { free(pointer) } }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let setup = [
            posix_spawn_file_actions_adddup2(&actions, controlPipe[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO),
            nullFD >= 0 ? posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO) : 0,
            posix_spawn_file_actions_addchdir_np(&actions, configuration.serverDirectoryURL.path),
            posix_spawnattr_setsigmask(&attributes, &signalMask),
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        ]
        if let error = setup.first(where: { $0 != 0 }) {
            for fd in controlPipe + outputPipe { close(fd) }
            if nullFD >= 0 { close(nullFD) }
            throw RuntimeError.system(error)
        }
        // Spawn and reap the supervisor directly so the child gets an explicit
        // signal mask/dispositions; Foundation's Process exposes no spawn attributes.
        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, supervisorURL.path, &actions, &attributes, &argv, &envp)
        guard spawnStatus == 0 else {
            for fd in controlPipe + outputPipe { close(fd) }
            if nullFD >= 0 { close(nullFD) }
            throw RuntimeError.system(spawnStatus)
        }
        close(controlPipe[0]); close(outputPipe[1])
        if nullFD >= 0 { close(nullFD) }
        let run = OwnedRun(id: configuration.id, pid: pid,
                           input: FileHandle(fileDescriptor: controlPipe[1], closeOnDealloc: true))
        lock.lock(); runs[run.id] = run; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            var discarding = false
            while true {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(outputPipe[0], &bytes, bytes.count)
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
            close(outputPipe[0])
            var waitStatus: Int32 = 0
            while waitpid(pid, &waitStatus, 0) < 0 {
                if errno == EINTR { continue }
                break
            }
            // Decode the wait status directly; the W* macros are unavailable to Swift.
            let signalBits = waitStatus & 0x7f
            let code: Int32
            if signalBits == 0 { code = (waitStatus >> 8) & 0xff }
            else if signalBits != 0x7f { code = 128 + signalBits }
            else { code = -1 }
            run.finish(code)
            self?.remove(run.id)
        }
        do {
            var frame = try JSONEncoder().encode(configuration); frame.append(10)
            try run.input.write(contentsOf: frame)
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
