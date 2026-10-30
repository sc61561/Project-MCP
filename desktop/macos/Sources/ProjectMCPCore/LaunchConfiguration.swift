import Foundation
import Darwin

public enum RuntimeError: Error, LocalizedError {
    case invalidConfiguration, missingResources, conflict, launcherLocked, unsupportedRuntime, preflight, health, timeout, exited
    case system(Int32)
    case reported(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请检查项目目录与连接设置"
        case .missingResources: return "应用运行文件缺失，请重新安装"
        case .conflict: return "已有其他 Tunnel 客户端，请先自行停止"
        case .launcherLocked: return "已有 Project MCP 实例正在运行，请先停止"
        case .unsupportedRuntime: return "Tunnel 版本不支持独立健康检查"
        case .preflight: return "本地服务预检失败"
        case .health: return "本地健康检查失败"
        case .timeout: return "启动超时，请检查网络与连接设置"
        case .exited: return "连接已退出，请检查密钥与网络后重试"
        case .system(let code): return "无法启动本地进程（\(code)）"
        case .reported(let message): return message
        }
    }
}

/// The first supervisor control frame. Intentionally has no credential field.
public struct LaunchConfiguration: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case tunnel, preflight }
    public var id: UUID
    public var runtimeURL: URL
    public var serverDirectoryURL: URL
    public var projectPath: String
    public var tunnelID: String
    public var organizationID: String
    public var healthURLFile: URL
    public var mode: Mode
    public init(runtimeURL: URL, serverDirectoryURL: URL, projectPath: String, tunnelID: String, organizationID: String, healthURLFile: URL, mode: Mode = .tunnel, id: UUID = UUID()) {
        self.id = id; self.runtimeURL = runtimeURL; self.serverDirectoryURL = serverDirectoryURL
        self.projectPath = projectPath; self.tunnelID = tunnelID; self.organizationID = organizationID
        self.healthURLFile = healthURLFile; self.mode = mode
    }
    public var tunnelArguments: [String] {
        ["run", "--control-plane.api-key", "env:CONTROL_PLANE_API_KEY",
         "--control-plane.tunnel-id", tunnelID, "--control-plane.organization-id", organizationID,
         "--mcp.command", "command=./project-mcp-server,channel=main",
         "--health.listen-addr", "127.0.0.1:0", "--health.url-file", healthURLFile.path,
         "--log.level", "info", "--log.file", "stdout"]
    }
    public func environment(apiKey: String? = nil) -> [String: String] {
        let temp = healthURLFile.deletingLastPathComponent().path
        var env = ["PATH": "/usr/bin:/bin", "HOME": temp, "TMPDIR": temp,
                   "XDG_CONFIG_HOME": temp, "LANG": "en_US.UTF-8", "PROJECT_ROOT": projectPath,
                   "PYTHONUNBUFFERED": "1", "PYTHONNOUSERSITE": "1"]
        if let apiKey { env["CONTROL_PLANE_API_KEY"] = apiKey }
        return env
    }
    public func validate() throws {
        let strings = [projectPath, tunnelID, organizationID, runtimeURL.path, serverDirectoryURL.path, healthURLFile.path]
        guard strings.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count < 16384 }),
              projectPath.hasPrefix("/"), runtimeURL.isFileURL, serverDirectoryURL.isFileURL,
              healthURLFile.isFileURL, !tunnelID.hasPrefix("-"), !organizationID.hasPrefix("-") else { throw RuntimeError.invalidConfiguration }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory), isDirectory.boolValue,
              access(projectPath, R_OK | X_OK) == 0 else { throw RuntimeError.invalidConfiguration }
        for path in [runtimeURL.path, serverDirectoryURL.appendingPathComponent("project-mcp-server").path] {
            guard FileManager.default.isExecutableFile(atPath: path) else { throw RuntimeError.missingResources }
        }
    }
}

public struct SupervisorEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case spawned, log, preflightPassed, failure, exited }
    public let id: UUID
    public let kind: Kind
    public var pid: Int32?
    public var message: String?
    public var status: Int32?
    public init(id: UUID, kind: Kind, pid: Int32? = nil, message: String? = nil, status: Int32? = nil) {
        self.id = id; self.kind = kind; self.pid = pid; self.message = message; self.status = status
    }
}

public struct StopCommand: Codable {
    public var stop = true
    public var graceSeconds: Double
    public init(graceSeconds: Double = 5) { self.graceSeconds = graceSeconds }
}

/// Only executable identity and owner are inspected; argv and environment are never read.
public enum TunnelConflictDetector {
    public static func hasConflict() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(max(0, min(Int(actual), pids.count))) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
                  info.pbi_uid == getuid() else { continue }
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if URL(fileURLWithPath: String(cString: path)).lastPathComponent == "tunnel-client" { return true }
        }
        return false
    }
}
