import Foundation
import Darwin

/// A stable inode shared by launcher processes of this user. Never unlink it:
/// unlinking would let another process lock a different inode at the same path.
final class LauncherLock {
    static var defaultURL: URL {
        URL(fileURLWithPath: "/tmp/com.sc61561.project-mcp-\(getuid()).lock")
    }
    private var descriptor: Int32
    init(url: URL = LauncherLock.defaultURL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw RuntimeError.launcherLocked }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(fd); throw RuntimeError.launcherLocked
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw RuntimeError.launcherLocked }
        descriptor = fd
    }
    func release() {
        guard descriptor >= 0 else { return }
        // close releases the advisory lock; O_CLOEXEC prevents children holding it.
        close(descriptor); descriptor = -1
    }
    deinit { release() }
}
