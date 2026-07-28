import Foundation
import XCTest
@testable import Portside

/// `SSHControl.controlDir` used to be a single fixed `/tmp` path shared by
/// every account on the machine, created (or trusted as-is) with no check on
/// what was actually already there — a symlink, a directory some other user
/// owns, anything. `verifiedOwnDirectory` is the gate that replaced blind
/// trust; these exercise it directly against real filesystem entries.
final class SSHControlTests: XCTestCase {

    func testNonexistentPathIsConsideredSafeToCreate() {
        let path = tempPath("does-not-exist-\(UUID().uuidString)")
        XCTAssertTrue(SSHControl.verifiedOwnDirectory(path))
    }

    func testOwnDirectoryWithCorrectModePasses() throws {
        let path = tempPath("owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(SSHControl.verifiedOwnDirectory(path))
    }

    func testDirectoryWithLooserPermissionsFails() throws {
        let path = tempPath("loose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(SSHControl.verifiedOwnDirectory(path),
                       "group/other-readable should never be trusted for a control socket directory")
    }

    func testASymlinkWherePlainDirectoryIsExpectedFails() throws {
        let real = tempPath("real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try? FileManager.default.removeItem(atPath: real) }

        let link = tempPath("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: link) }

        XCTAssertFalse(SSHControl.verifiedOwnDirectory(link),
                       "a symlink must be judged by what it is, not what it resolves to")
    }

    func testAPlainFileWherADirectoryIsExpectedFails() throws {
        let path = tempPath("file-\(UUID().uuidString)")
        try "not a directory".write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(SSHControl.verifiedOwnDirectory(path))
    }

    func testControlDirIsScopedToTheCurrentUser() {
        XCTAssertTrue(SSHControl.controlDir.contains("-\(getuid())"),
                     "the control directory must not be a single name shared by every local account")
    }

    private func tempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(name).path
    }
}
