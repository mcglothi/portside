import Foundation
import XCTest
@testable import Portside

/// Importing a real `~/.ssh/config` off disk.
///
/// Written for the line-ending bug, and kept because there was no coverage of
/// this path at all: `importEntries` reads a file the user did not necessarily
/// write on this machine.
final class SSHConfigImporterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-sshconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func importing(_ contents: String) throws -> [SessionEntry] {
        let url = directory.appendingPathComponent("config")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return SSHConfigImporter.importEntries(from: url)
    }

    private static let config = """
    Host web-01
        HostName web01.example.internal
        User deploy

    Host db-01
        HostName db01.example.internal
        User postgres
    """

    func testAnLFConfigImportsEveryHost() throws {
        let entries = try importing(Self.config)
        XCTAssertEqual(entries.map(\.name), ["db-01", "web-01"])
        XCTAssertEqual(entries.first { $0.name == "web-01" }?.hostname,
                       "web01.example.internal")
        XCTAssertEqual(entries.first { $0.name == "web-01" }?.user, "deploy")
    }

    /// **The bug.** `\r\n` is a single Swift `Character`, so splitting on `"\n"`
    /// found no separator and handed the parser the entire file as one line.
    /// Because `\r\n` also counts as whitespace, the first `Host` keyword then
    /// swallowed everything after it as the hostname — one absurd entry instead
    /// of the real ones. A config written on Windows, or edited through one, is
    /// an ordinary thing to be handed.
    func testACRLFConfigImportsIdenticallyToAnLFOne() throws {
        let crlf = Self.config.replacingOccurrences(of: "\n", with: "\r\n")
        let entries = try importing(crlf)

        XCTAssertEqual(entries.map(\.name), ["db-01", "web-01"],
                       "a CRLF config must import the same hosts as an LF one")
        XCTAssertEqual(entries.first { $0.name == "web-01" }?.hostname,
                       "web01.example.internal",
                       "a stray carriage return must not survive into the hostname")
        XCTAssertEqual(entries.first { $0.name == "db-01" }?.user, "postgres")
    }

    /// The failure shape worth naming: not "no hosts", but *one* host carrying
    /// the rest of the file.
    func testACRLFConfigDoesNotProduceOneGiantEntry() throws {
        let crlf = Self.config.replacingOccurrences(of: "\n", with: "\r\n")
        let entries = try importing(crlf)

        XCTAssertGreaterThan(entries.count, 1, "the whole file collapsed into one entry")
        for entry in entries {
            XCTAssertFalse(entry.name.contains("HostName"),
                           "an entry swallowed the rest of the file: \(entry.name)")
            XCTAssertFalse(entry.hostname.contains(" "),
                           "hostname contains whitespace: \(entry.hostname)")
            XCTAssertFalse(entry.hostname.contains("\r"),
                           "a carriage return survived into \(entry.name)'s hostname")
        }
    }

    /// **Deliberately not tolerant.** OpenSSH reads this file with `getline`:
    /// LF is the physical delimiter, and CRLF works only because the trailing CR
    /// is whitespace. A lone CR is not a directive boundary to ssh, so treating
    /// it as one here would show a host that ssh will never resolve — worse than
    /// not importing it. This pins the divergence we chose *not* to introduce.
    func testALoneCarriageReturnIsNotADirectiveBoundary() throws {
        let cr = Self.config.replacingOccurrences(of: "\n", with: "\r")
        let entries = try importing(cr)
        XCTAssertNotEqual(entries.map(\.name), ["db-01", "web-01"],
                          "importing lone-CR lines invents hosts ssh cannot resolve")
    }

    /// Same reasoning for the other characters `Character.isNewline` covers.
    /// A form feed inside a config is not a new directive to ssh.
    func testExoticUnicodeSeparatorsAreNotDirectiveBoundaries() throws {
        let text = "Host real-01\n    HostName real01.example.internal\u{000C}Host phantom-01\n"
        let names = try importing(text).map(\.name)
        XCTAssertEqual(names, ["real-01"], "a form feed invented a host: \(names)")
    }

    func testCommentsAndBlankLinesAreIgnored() throws {
        let entries = try importing("""
        # a comment\r
        \r
        Host only-01\r
            HostName only01.example.internal\r
        """)
        XCTAssertEqual(entries.map(\.name), ["only-01"])
        XCTAssertEqual(entries.first?.hostname, "only01.example.internal")
    }

    func testAMissingFileImportsNothingRatherThanFailing() {
        let absent = directory.appendingPathComponent("does-not-exist")
        XCTAssertTrue(SSHConfigImporter.importEntries(from: absent).isEmpty)
    }
}
