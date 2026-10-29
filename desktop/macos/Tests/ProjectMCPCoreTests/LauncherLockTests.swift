import XCTest
import Darwin
@testable import ProjectMCPCore

final class LauncherLockTests: XCTestCase {
    func testOtherProcessLockRefusesThenProcessDeathReleasesIt() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("launcher.lock")
        let marker = fixture.root.appendingPathComponent("locked")
        let helper = fixture.root.appendingPathComponent("lock-holder")
        try FileManager.default.copyItem(at: fixture.server.appendingPathComponent("project-mcp-server"), to: helper)
        let process = Process()
        process.executableURL = helper; process.arguments = [url.path, marker.path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertThrowsError(try LauncherLock(url: url))
        XCTAssertTrue(process.isRunning)
        process.terminate()
        for _ in 0..<100 {
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let acquired = try LauncherLock(url: url)
        XCTAssertThrowsError(try LauncherLock(url: url))
        acquired.release()
        let again = try LauncherLock(url: url)
        again.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testLockRejectsSymlinkAndDoesNotChangeDestination() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target")
        let link = fixture.root.appendingPathComponent("launcher.lock")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try LauncherLock(url: link))
        XCTAssertEqual(try String(contentsOf: target), "preserve")
    }
}
