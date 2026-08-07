import Foundation
import XCTest
@testable import Portside

/// Covers the injected form of the shell integration — the one that is typed
/// at a live prompt rather than appended to a host's rc file.
final class ShellIntegrationInjectionTests: XCTestCase {

    // MARK: - Payload derivation

    /// The payload must stay derived from the snippet, not restated. These
    /// assertions are about *identity with the source*, so that editing the
    /// snippet cannot leave an injected variant behind reporting something
    /// different.
    func testPayloadKeepsEveryNonCommentLineOfTheSnippet() {
        for snippet in ShellIntegrationSnippet.allCases {
            let payload = ShellIntegrationInjection.payload(for: snippet)
            let expected = snippet.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }

            let actual = payload
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            XCTAssertEqual(actual, expected,
                           "\(snippet.label): injected payload diverged from the snippet")
        }
    }

    func testPayloadDropsCommentsAndBlankLines() {
        for snippet in ShellIntegrationSnippet.allCases {
            let payload = ShellIntegrationInjection.payload(for: snippet)
            for line in payload.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                XCTAssertFalse(trimmed.isEmpty, "\(snippet.label): blank line survived")
                XCTAssertFalse(trimmed.hasPrefix("#"), "\(snippet.label): comment survived: \(trimmed)")
            }
        }
    }

    /// Comment stripping must not touch the shell itself. The functions and
    /// hook registrations are what make OSC 7 fire; if any of them went missing
    /// the session would connect and simply never report a directory.
    func testPayloadRetainsTheWorkingParts() {
        let bash = ShellIntegrationInjection.payload(for: .bash)
        XCTAssertTrue(bash.contains("__portside_precmd"))
        XCTAssertTrue(bash.contains("PROMPT_COMMAND"))
        XCTAssertTrue(bash.contains("033]7;file://"), "OSC 7 reporting must survive")
        XCTAssertTrue(bash.contains("trap '__portside_preexec' DEBUG"))

        let zsh = ShellIntegrationInjection.payload(for: .zsh)
        XCTAssertTrue(zsh.contains("add-zsh-hook precmd __portside_osc7"))
        XCTAssertTrue(zsh.contains("add-zsh-hook preexec __portside_preexec"))
        XCTAssertTrue(zsh.contains("033]7;file://"), "OSC 7 reporting must survive")
    }

    /// A `#` inside a string or expansion is not a comment. Nothing in the
    /// snippet relies on this today, which is the point of locking it: the
    /// stripper must not become something that would eat one if it appeared.
    func testStrippingOnlyRemovesWholeCommentLines() {
        for snippet in ShellIntegrationSnippet.allCases {
            let sourceLines = snippet.text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let inlineHashes = sourceLines.filter { $0.contains("#") }
            let payload = ShellIntegrationInjection.payload(for: snippet)
            for line in inlineHashes {
                XCTAssertTrue(payload.contains(line),
                              "\(snippet.label): line with an inline # was dropped: \(line)")
            }
        }
    }

    // MARK: - The command

    func testCommandRoundTripsThroughBase64() throws {
        for snippet in ShellIntegrationSnippet.allCases {
            let encoded = ShellIntegrationInjection.encoded(snippet)
            let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertEqual(String(decoding: decoded, as: UTF8.self),
                           ShellIntegrationInjection.payload(for: snippet))
        }
    }

    func testCommandCarriesBothShellsBehindTheirOwnGuards() {
        let command = ShellIntegrationInjection.command
        XCTAssertTrue(command.contains("[ -n \"$BASH_VERSION\" ]"))
        XCTAssertTrue(command.contains("[ -n \"$ZSH_VERSION\" ]"))
        XCTAssertTrue(command.contains(ShellIntegrationInjection.encoded(.bash)))
        XCTAssertTrue(command.contains(ShellIntegrationInjection.encoded(.zsh)))
    }

    /// A shell that is neither bash nor zsh must do nothing at all, rather than
    /// eval an empty string or a half-selected payload.
    func testCommandGuardsTheEvalOnHavingSelectedAPayload() {
        XCTAssertTrue(ShellIntegrationInjection.command.contains("[ -n \"$__p\" ] && eval"))
    }

    func testCommandIsASingleLine() {
        XCTAssertFalse(ShellIntegrationInjection.command.contains("\n"),
                       "a newline would submit the line early and run a fragment")
    }

    /// Leading space so hosts with `HISTCONTROL=ignorespace` / `histignorespace`
    /// keep it out of history.
    func testCommandStartsWithASpace() {
        XCTAssertTrue(ShellIntegrationInjection.command.hasPrefix(" "))
    }

    func testCommandCleansUpItsScratchVariable() {
        XCTAssertTrue(ShellIntegrationInjection.command.hasSuffix("unset __p"))
    }

    /// The single quotes around each payload are what keep the shell from
    /// expanding it, so base64's alphabet must never contain one. It doesn't —
    /// this is a regression guard on the encoding, not on base64 itself.
    func testEncodedPayloadsCannotBreakOutOfTheirQuoting() {
        for snippet in ShellIntegrationSnippet.allCases {
            XCTAssertFalse(ShellIntegrationInjection.encoded(snippet).contains("'"),
                           "\(snippet.label): a quote in the payload would end the string early")
        }
    }

    // MARK: - The size ceiling

    /// Holds the encoded line to a tty-sized budget.
    ///
    /// Worth an assertion because base64 amplifies: three bytes added to the
    /// snippet become four here, so the line grows faster than the thing being
    /// edited, and the snippet is edited far more often than this file. The
    /// budget is Linux's 4096-byte canonical buffer — a real bash and zsh on a
    /// Darwin pty were both measured accepting the current 2.3 KB line intact,
    /// so this is headroom rather than a cliff we are near.
    func testCommandFitsTheCanonicalBudget() {
        let size = ShellIntegrationInjection.commandByteCount
        XCTAssertTrue(
            ShellIntegrationInjection.fitsCanonicalBuffer(ShellIntegrationInjection.canonicalBudget),
            "injected line is \(size) bytes, over the \(ShellIntegrationInjection.canonicalBudget)-byte "
            + "budget — shrink the snippet or send it in chunks.")
    }
}

/// Covers when the injection is offered at all.
@MainActor
final class ShellIntegrationInjectionGatingTests: XCTestCase {

    private func manager(injecting: Bool) -> SessionManager {
        let m = SessionManager()
        var t = TerminalSettings()
        t.injectShellIntegration = injecting
        m.terminalSettings = t
        return m
    }

    private func entry(_ kind: SessionKind) -> SessionEntry {
        var e = SessionEntry(name: "h")
        e.kind = kind
        e.hostname = "example.internal"
        return e
    }

    func testOffByDefault() {
        XCTAssertFalse(TerminalSettings().injectShellIntegration)
        XCTAssertFalse(manager(injecting: false).shouldInjectShellIntegration(for: entry(.host)))
    }

    func testInjectsIntoSSHHostsWhenEnabled() {
        XCTAssertTrue(manager(injecting: true).shouldInjectShellIntegration(for: entry(.host)))
    }

    /// Serial and telnet have no shell; container and kubernetes sessions open
    /// a *local* shell, so integrating there would report this Mac's directory.
    func testNeverInjectsIntoNonSSHTransports() {
        let m = manager(injecting: true)
        for kind in [SessionKind.serial, .telnet, .container, .kubernetes] {
            XCTAssertFalse(m.shouldInjectShellIntegration(for: entry(kind)),
                           "\(kind) must not have the integration typed into it")
        }
    }
}
