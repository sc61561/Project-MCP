import Foundation
import Darwin

public enum HealthEndpoint {
    /// Accept numeric loopback only. No DNS, userinfo, query, fragment or arbitrary endpoint.
    public static func parse(_ raw: String) throws -> URL {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "http", ["127.0.0.1", "::1", "[::1]"].contains(parts.host ?? ""),
              let port = parts.port, port > 0, port <= 65535, port != 8080,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw RuntimeError.health }
        parts.path = "/readyz"
        guard let url = parts.url else { throw RuntimeError.health }
        return url
    }
    public static func read(_ file: URL) throws -> URL? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw RuntimeError.health
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 4096 else { throw RuntimeError.health }
        if info.st_size == 0 { return nil }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count <= 4096, let raw = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw RuntimeError.health }
        return try parse(raw)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class HealthClient: @unchecked Sendable {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        config.connectionProxyDictionary = [:]
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func ready(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
            request.httpMethod = "GET"
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url else { return false }
            var body: [UInt8] = []
            for try await byte in bytes {
                if body.count >= 128 { bytes.task.cancel(); return false }
                body.append(byte)
            }
            return String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ready"
        } catch { return false }
    }
}
