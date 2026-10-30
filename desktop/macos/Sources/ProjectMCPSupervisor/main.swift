import Foundation
import Darwin
import ProjectMCPCore

// This helper is the sole authority that signals owned child groups. Its stdin is
// the GUI control pipe, and is never inherited by a child.
var terminating: Int32 = 0
signal(SIGTERM) { _ in terminating = 1 }
signal(SIGINT) { _ in terminating = 1 }
signal(SIGHUP) { _ in terminating = 1 }
signal(SIGPIPE, SIG_IGN)

func emit(_ event: SupervisorEvent) {
    guard var data = try? JSONEncoder().encode(event) else { return }
    data.append(10)
    try? FileHandle.standardOutput.write(contentsOf: data)
}

func nonblocking(_ fd: Int32) { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

struct LineReader {
    var bytes = Data()
    var dropping = false
    let limit: Int
    mutating func consume(_ data: Data, line: (Data) throws -> Void) rethrows {
        for byte in data {
            if byte == 10 {
                if !dropping { try line(bytes) }
                else { try line(Data("[超长日志已省略]".utf8)) }
                bytes.removeAll(keepingCapacity: true); dropping = false
            } else if bytes.count < limit && !dropping { bytes.append(byte) }
            else { bytes.removeAll(keepingCapacity: true); dropping = true }
        }
    }
}

struct Stopped: Error {}

final class Supervisor {
    let config: LaunchConfiguration
    let diagnostics: DiagnosticBuffer
    var control = LineReader(limit: 4096)
    var grace: Double = 5
    var child: pid_t = 0
    var childInput: Int32 = -1
    var output: Int32 = -1
    var errors: Int32 = -1

    init(_ config: LaunchConfiguration) {
        self.config = config
        diagnostics = DiagnosticBuffer(secrets: [ProcessInfo.processInfo.environment["CONTROL_PLANE_API_KEY"] ?? ""], paths: [config.projectPath, config.serverDirectoryURL.path, config.healthURLFile.deletingLastPathComponent().path])
    }
    func log(_ data: Data) {
        diagnostics.append(String(decoding: data, as: UTF8.self))
        emit(SupervisorEvent(id: config.id, kind: .log, message: diagnostics.snapshot().last ?? ""))
    }
    func checkControl() throws {
        if terminating != 0 { throw Stopped() }
        var data = [UInt8](repeating: 0, count: 4096)
        let n = read(STDIN_FILENO, &data, data.count)
        if n == 0 { throw Stopped() }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            throw Stopped()
        }
        try control.consume(Data(data.prefix(n))) { data in
            if let stop = try? JSONDecoder().decode(StopCommand.self, from: data), stop.stop, stop.graceSeconds.isFinite {
                grace = min(5, max(0, stop.graceSeconds))
            }
            throw Stopped()
        }
    }

    func spawn(executable: URL, arguments: [String], interactive: Bool, includeKey: Bool = false) throws {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0], inPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw RuntimeError.system(errno) }
        guard pipe(&errPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); throw RuntimeError.system(errno) }
        guard pipe(&inPipe) == 0 else { for fd in outPipe + errPipe { close(fd) }; throw RuntimeError.system(errno) }
        defer { close(outPipe[1]); close(errPipe[1]); close(inPipe[0]) }
        let null = open("/dev/null", O_RDONLY)
        defer { if null >= 0 { close(null) } }
        var actions: posix_spawn_file_actions_t?
        var attrs: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attrs)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
        var empty = sigset_t(), defaults = sigset_t()
        sigemptyset(&empty); sigemptyset(&defaults)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
        let setup = [
            posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attrs, 0),
            posix_spawnattr_setsigmask(&attrs, &empty), posix_spawnattr_setsigdefault(&attrs, &defaults),
            posix_spawn_file_actions_addchdir_np(&actions, config.serverDirectoryURL.path),
            posix_spawn_file_actions_adddup2(&actions, interactive ? inPipe[0] : null, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        ]
        if let error = setup.first(where: { $0 != 0 }) {
            for fd in [outPipe[0], errPipe[0], inPipe[1]] { close(fd) }
            throw RuntimeError.system(error)
        }
        let args = ([executable.path] + arguments).map { strdup($0) }
        let env = config.environment(apiKey: includeKey ? ProcessInfo.processInfo.environment["CONTROL_PLANE_API_KEY"] : nil).map { strdup("\($0.key)=\($0.value)") }
        defer { for p in args + env { free(p) } }
        var argv = args + [nil], envp = env + [nil]
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attrs, &argv, &envp)
        guard status == 0 else {
            for fd in [outPipe[0], errPipe[0], inPipe[1]] { close(fd) }
            throw RuntimeError.system(status)
        }
        child = pid; output = outPipe[0]; errors = errPipe[0]
        childInput = interactive ? inPipe[1] : -1
        if !interactive { close(inPipe[1]) }
        nonblocking(output); nonblocking(errors)
        emit(SupervisorEvent(id: config.id, kind: .spawned, pid: pid))
    }

    // WNOWAIT pins the leader's PID until cleanup has signalled the whole group,
    // including when the leader exits before descendants. Never signal a reaped PID.
    func exitStatus() -> Int32? {
        var info = siginfo_t()
        guard child > 0, waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == child else { return nil }
        return info.si_status
    }
    func hasLiveGroupMembers() -> Bool {
        var pids = [Int32](repeating: 0, count: 4096)
        let size = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(child), $0.baseAddress, Int32($0.count)) }
        if size <= 0 { return kill(-child, 0) == 0 && exitStatus() == nil }
        for pid in pids.prefix(min(pids.count, Int(size) / MemoryLayout<Int32>.size)) where pid > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0, info.pbi_status != 5 { return true }
        }
        return false
    }
    func cleanup() {
        guard child > 0 else { return }
        if childInput >= 0 { close(childInput); childInput = -1 }
        kill(-child, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline && hasLiveGroupMembers() { usleep(20_000) }
        if hasLiveGroupMembers() { kill(-child, SIGKILL) }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        child = 0
        for fd in [output, errors] where fd >= 0 { close(fd) }
        output = -1; errors = -1
    }
    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try data.withUnsafeBytes { bytes in
            guard write(childInput, bytes.baseAddress, bytes.count) == bytes.count else { throw RuntimeError.preflight }
        }
    }
    func pump(deadline: Date? = nil, onError: ((Data) -> Void)? = nil, onOutput: (Data) throws -> Void) throws -> Int32 {
        var stdout = LineReader(limit: config.mode == .preflight ? 65536 : 8192)
        var stderr = LineReader(limit: 8192)
        while true {
            try checkControl()
            if let deadline, Date() >= deadline { throw RuntimeError.timeout }
            var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0), pollfd(fd: output, events: Int16(POLLIN | POLLHUP), revents: 0), pollfd(fd: errors, events: Int16(POLLIN | POLLHUP), revents: 0)]
            _ = poll(&fds, nfds_t(fds.count), 50)
            for (fd, isStdout) in [(output, true), (errors, false)] where fd >= 0 {
                // Limit bytes per iteration so a noisy child cannot starve stop/EOF.
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &bytes, bytes.count)
                if count > 0 {
                    if isStdout { try stdout.consume(Data(bytes.prefix(count)), line: onOutput) }
                    else { stderr.consume(Data(bytes.prefix(count)), line: onError ?? log) }
                }
            }
            if let status = exitStatus() {
                // A short-lived process can exit with several pipe buffers unread.
                // Drain a bounded tail without waiting for descendants to close FDs.
                for (fd, isStdout) in [(output, true), (errors, false)] where fd >= 0 {
                    for _ in 0..<64 {
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        let count = read(fd, &bytes, bytes.count)
                        if count <= 0 { break }
                        if isStdout { try stdout.consume(Data(bytes.prefix(count)), line: onOutput) }
                        else { stderr.consume(Data(bytes.prefix(count)), line: onError ?? log) }
                    }
                }
                if !stdout.bytes.isEmpty && !stdout.dropping { try onOutput(stdout.bytes) }
                if !stderr.bytes.isEmpty && !stderr.dropping { (onError ?? log)(stderr.bytes) }
                return status
            }
        }
    }
    func preflight() throws {
        let deadline = Date().addingTimeInterval(25)
        try spawn(executable: config.runtimeURL, arguments: ["run", "--help"], interactive: false)
        var help = Data()
        let helpStatus = try pump(deadline: deadline, onError: { data in
            if help.count + data.count < 65536 { help.append(data); help.append(10) }
        }) { data in
            if help.count + data.count < 65536 { help.append(data); help.append(10) }
        }
        cleanup()
        let text = String(decoding: help, as: UTF8.self)
        guard helpStatus == 0, text.contains("--health.listen-addr"), text.contains("--health.url-file") else { throw RuntimeError.unsupportedRuntime }
        try spawn(executable: config.serverDirectoryURL.appendingPathComponent("project-mcp-server"), arguments: [], interactive: true)
        var expected = 1
        var passed = false
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "ProjectMCPPreflight", "version": "1.0"]]])
        struct Complete: Error {}
        do {
            _ = try pump(deadline: deadline) { data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["jsonrpc"] as? String == "2.0" else { throw RuntimeError.preflight }
                guard let id = object["id"] as? Int else { return } // Server notifications are permitted.
                guard id == expected, object["error"] == nil, let result = object["result"] as? [String: Any] else { throw RuntimeError.preflight }
                switch expected {
                case 1:
                    guard result["protocolVersion"] as? String == "2024-11-05", result["serverInfo"] is [String: Any], result["capabilities"] is [String: Any] else { throw RuntimeError.preflight }
                    try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
                    expected = 2
                    try send(["jsonrpc": "2.0", "id": 2, "method": "ping"])
                case 2:
                    expected = 3
                    try send(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
                default:
                    guard let tools = result["tools"] as? [[String: Any]], tools.count == 3,
                          Set(tools.compactMap { $0["name"] as? String }) == Set(["list_files", "read_file", "search_files"]), result["nextCursor"] == nil else { throw RuntimeError.preflight }
                    passed = true; throw Complete()
                }
            }
        } catch is Complete {}
        cleanup()
        guard passed else { throw RuntimeError.preflight }
        emit(SupervisorEvent(id: config.id, kind: .preflightPassed))
    }
    func run() -> Int32 {
        defer { cleanup() }
        do {
            try config.validate()
            if config.mode == .preflight { try preflight(); return 0 }
            try spawn(executable: config.runtimeURL, arguments: config.tunnelArguments, interactive: false, includeKey: true)
            let status = try pump(onOutput: log)
            cleanup()
            emit(SupervisorEvent(id: config.id, kind: .exited, status: status))
            return status == 0 ? 0 : 1
        } catch is Stopped { return 0 }
        catch {
            emit(SupervisorEvent(id: config.id, kind: .failure, message: error.localizedDescription))
            return 1
        }
    }
}

nonblocking(STDIN_FILENO)
var first = Data()
let deadline = Date().addingTimeInterval(5)
var configuration: LaunchConfiguration?
while Date() < deadline && terminating == 0 && configuration == nil {
    // Read one byte to leave any stop frame after the launch frame in the pipe.
    var byte: UInt8 = 0
    let count = read(STDIN_FILENO, &byte, 1)
    if count == 0 { exit(0) }
    if count == 1 {
        if byte == 10 { configuration = try? JSONDecoder().decode(LaunchConfiguration.self, from: first); if configuration == nil { exit(1) } }
        else { first.append(byte); if first.count > 65536 { exit(1) } }
    } else { usleep(1000) }
}
guard let configuration else { exit(1) }
exit(Supervisor(configuration).run())
