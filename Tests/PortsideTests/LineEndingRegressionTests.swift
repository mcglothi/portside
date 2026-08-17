import Foundation
import XCTest
@testable import Portside

/// Direct coverage for the two line-ending sites the CRLF fix touched but did
/// not originally test.
///
/// Both were flagged in review as "the implementation mirrors something that is
/// tested, so it is probably fine". Probably fine is what this whole class of
/// bug looks like from the outside: `\r\n` is a single Swift `Character`, so
/// `split(separator: "\n")` finds nothing in CRLF text and quietly reports one
/// line where there are several. Neither site is worth trusting to a mirror.
final class LineEndingRegressionTests: XCTestCase {

    // MARK: - PublicKeyLocator

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-lineendings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let firstKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIRSTKEYBLOB tim@newton"
    private static let secondKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADSECONDKEYBLOB tim@oldmac"

    private func writeKeyFile(_ contents: String) throws -> String {
        let url = directory.appendingPathComponent("id_test.pub")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// **The one that mattered.** A `.pub` holding two keys with CRLF endings
    /// was read as a single line, so `key.line` carried *both* keys — and
    /// `key.line` is what gets appended to a remote `authorized_keys`. One file
    /// could smuggle a second key into a distribution.
    func testAMultiKeyCRLFPubFileYieldsOnlyTheFirstKey() async throws {
        let path = try writeKeyFile("\(Self.firstKey)\r\n\(Self.secondKey)\r\n")
        let loaded = await PublicKeyLocator.load(path: path, fingerprinter: { _ in nil })
        let key = try XCTUnwrap(loaded)

        XCTAssertEqual(key.line, Self.firstKey)
        XCTAssertFalse(key.line.contains("SECONDKEYBLOB"),
                       "a second key rode along inside the line that gets installed")
        XCTAssertEqual(key.blob, "AAAAC3NzaC1lZDI1NTE5AAAAIFIRSTKEYBLOB")
        XCTAssertFalse(key.comment.contains("\r"), "a carriage return survived into the comment")
    }

    func testACRLFAndAnLFPubFileParseIdentically() async throws {
        let lfPath = try writeKeyFile("\(Self.firstKey)\n\(Self.secondKey)\n")
        let lfLoaded = await PublicKeyLocator.load(path: lfPath, fingerprinter: { _ in nil })
        let lf = try XCTUnwrap(lfLoaded)

        let crlfPath = try writeKeyFile("\(Self.firstKey)\r\n\(Self.secondKey)\r\n")
        let crlfLoaded = await PublicKeyLocator.load(path: crlfPath, fingerprinter: { _ in nil })
        let crlf = try XCTUnwrap(crlfLoaded)

        XCTAssertEqual(lf.line, crlf.line)
        XCTAssertEqual(lf.blob, crlf.blob)
        XCTAssertEqual(lf.comment, crlf.comment)
    }

    /// `discover` walks a directory and has the same read; a CRLF file there
    /// must not be skipped or mangled either.
    func testDiscoverReadsACRLFPubFile() async throws {
        _ = try writeKeyFile("\(Self.firstKey)\r\n")
        let found = await PublicKeyLocator.discover(in: directory.path,
                                                    fingerprinter: { _ in nil })
        XCTAssertEqual(found.map(\.line), [Self.firstKey])
    }

    // MARK: - The broadcast confirmation's preview

    /// The preview is the text a user reads before agreeing to run something on
    /// every pane. A CRLF paste previewed as one run-on line, so what they were
    /// asked to check did not resemble what would run.
    @MainActor
    func testThePreviewSplitsCRLFIntoSeparateLines() {
        let preview = SessionManager.previewLines(of: "cd /var/log\r\nrm -rf ./*\r\n")
        XCTAssertTrue(preview.contains("cd /var/log"), "got: \(preview)")
        XCTAssertTrue(preview.contains("rm -rf ./*"), "got: \(preview)")
        XCTAssertFalse(preview.contains("cd /var/logrm"),
                       "the commands ran together on one line: \(preview)")
        XCTAssertFalse(preview.contains("\r"), "a carriage return survived into the preview")
    }

    /// Line endings must not change what the user is shown.
    @MainActor
    func testThePreviewIsTheSameWhateverTheLineEndings() {
        let lf = SessionManager.previewLines(of: "one\ntwo\nthree")
        let crlf = SessionManager.previewLines(of: "one\r\ntwo\r\nthree")
        XCTAssertEqual(lf, crlf)
    }

    /// The preview agrees with the gate that decided to show it — if it showed
    /// fewer boundaries than the count in the dialog, the two would contradict
    /// each other in front of the user.
    @MainActor
    func testThePreviewAgreesWithTheReviewLineCount() {
        let text = "alpha\r\nbravo\r\ncharlie"
        guard case .confirm(let lines, _) = BroadcastPasteReview.review(text: text,
                                                                       targetCount: 3) else {
            return XCTFail("three commands must be confirmed")
        }
        let preview = SessionManager.previewLines(of: text)
        for command in ["alpha", "bravo", "charlie"] {
            XCTAssertTrue(preview.contains(command), "\(command) missing from: \(preview)")
        }
        XCTAssertEqual(lines, 3)
    }
}
