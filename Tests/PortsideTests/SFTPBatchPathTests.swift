import XCTest
@testable import Portside

/// `sftp -b` reads newline-delimited commands, so a path is only safe to
/// interpolate into one if it cannot introduce a line break. Quoting handles
/// the argument; these are the characters quoting cannot save.
final class SFTPBatchPathTests: XCTestCase {
    private func rejects(_ path: String, _ message: String) {
        XCTAssertThrowsError(try SFTPClient.validateBatchPath(path), message)
    }

    private func accepts(_ path: String, _ message: String) {
        XCTAssertNoThrow(try SFTPClient.validateBatchPath(path), message)
    }

    func testLineFeedIsRejected() {
        // The forged-command case: this would have split into `rm ...` on its
        // own batch line.
        rejects("/home/ops/notes\nrm -r important", "LF splits the batch")
    }

    func testCarriageReturnIsRejected() {
        rejects("/home/ops/notes\rrm -r important", "CR splits the batch")
    }

    func testNulIsRejected() {
        rejects("/home/ops/notes\u{0}truncated", "NUL truncates the command")
    }

    func testControlCharacterAnywhereInThePathIsRejected() {
        rejects("\n/leading", "a leading break counts")
        rejects("/trailing\n", "a trailing break counts")
    }

    func testOrdinaryAwkwardNamesStillWork() {
        // Rejection has to stay narrow: these are legal, common, and already
        // handled correctly by quoting.
        accepts("/home/ops/my notes.txt", "spaces are fine")
        accepts("/home/ops/say \"hi\".txt", "quotes are escaped, not rejected")
        accepts("/home/ops/back\\slash", "backslashes are escaped, not rejected")
        accepts("/home/ops/naïve-ünïcode-日本語.txt", "non-ASCII is fine")
        accepts("/home/ops/semi;colon && amp", "shell metacharacters never reach a shell")
        accepts("", "an empty path is the caller's problem, not a control character")
    }

    func testTabIsAllowed() {
        // Ugly but harmless: tab is not a batch delimiter, and `ls -la`
        // parsing already tolerates it.
        accepts("/home/ops/tab\there", "tab does not delimit batch commands")
    }
}
