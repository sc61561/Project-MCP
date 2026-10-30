import Foundation

public final class DiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var secrets: [String]
    private var paths: [String]
    public init(secrets: [String] = [], paths: [String] = []) {
        self.secrets = secrets.filter { !$0.isEmpty }
        self.paths = paths.filter { !$0.isEmpty }
    }
    /// Re-sanitize existing entries as well, before a new run can produce output.
    public func configure(secrets: [String], paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        self.secrets = secrets.filter { !$0.isEmpty }
        self.paths = paths.filter { !$0.isEmpty }
        lines = lines.map { redact($0) }
    }
    public func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        // Bound work before regex matching. Oversized input may split a secret, so omit it entirely.
        let input = line.utf8.count > 65536 ? "[超长日志已省略]" : redact(line)
        for part in input.components(separatedBy: .newlines) { lines.append(String(part.prefix(2048))) }
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }
    public func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    public func redactedSummary() -> String { snapshot().joined(separator: "\n") }
    private func redact(_ input: String) -> String {
        var result = input
        for value in (secrets + paths).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: value, with: "[已隐藏]")
        }
        let patterns = [
            #"(?i)(authorization[\"']?\s*[:=]\s*[\"']?)(?:bearer\s+|basic\s+)?[^\s\"',;}]+"#,
            #"(?i)((?:[a-z_]*token|api[_-]?key|secret|password)[\"']?\s*[:=]\s*[\"']?)[^\s\"',;}]+"#,
            #"(?i)\bBearer\s+[^\s\"',;}]+"#,
            #"\bsk-[A-Za-z0-9_-]+"#,
            #"/(?:Users|Volumes|private|tmp|home)/[^\n\"']*"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[已隐藏]", options: .regularExpression)
        }
        return result
    }
}
