import Foundation
import XCTest
@testable import Portside

/// The bash snippet, run in a real interactive bash with the OSC 133 records
/// it writes decoded — what the timeline and an agent's `last` would see.
///
/// The structural tests in `ShellIntegrationTests` couldn't have caught issue
/// #24: on RHEL, `/etc/bashrc` adds a title `printf` to `PROMPT_COMMAND`, the
/// DEBUG trap fired for it, and every command an agent ran came back labelled
/// as that printf. Only running bash shows what bash does.
///
/// This is macOS's bash 3.2, the oldest the snippet has to work on; the fix
/// was also checked by hand on 4.4 (RHEL 8) and 5.3.
final class ShellIntegrationBashTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-bash-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// RHEL's own `PROMPT_COMMAND`, as `/etc/bashrc` sets it for xterm.
    private let rhelPromptCommand = #"PROMPT_COMMAND='printf "\033]0;%s@%s:%s\007" "${USER}" "${HOSTNAME%%.*}" "${PWD/#$HOME/\~}"'"#

    /// Runs `input` line by line through an interactive bash whose rc file is
    /// `rc`, and returns each record as (command, exit code).
    private func records(rc: String, input: String) throws -> [(String, String)] {
        let rcURL = dir.appendingPathComponent("bashrc")
        try rc.write(to: rcURL, atomically: true, encoding: .utf8)
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["--rcfile", rcURL.path, "-i"]
        bash.environment = ["HOME": dir.path, "TERM": "xterm", "PATH": "/usr/bin:/bin", "USER": "test"]
        let stdin = Pipe(), stdout = Pipe()
        bash.standardInput = stdin
        bash.standardOutput = stdout
        bash.standardError = FileHandle.nullDevice
        try bash.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        bash.waitUntilExit()

        var out: [(String, String)] = []
        var pending: String?
        let marker = try Regex(#"\x1B\]133;([ED]);([^\x07]*)\x07"#, as: (Substring, Substring, Substring).self)
        for m in String(decoding: data, as: UTF8.self).matches(of: marker) {
            if m.1 == "E" {
                pending = Data(base64Encoded: String(m.2)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            } else if let command = pending {
                out.append((command, String(m.2)))
                pending = nil
            }
        }
        if let pending { out.append((pending, "unfinished")) }
        return out
    }

    private func assertRecords(_ actual: [(String, String)], _ expected: [(String, String)],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map { "\($0.0) => \($0.1)" }, expected.map { "\($0.0) => \($0.1)" },
                       file: file, line: line)
    }

    func testCommandsAreLabelledAsTypedWhenPromptCommandHasSeveralEntries() throws {
        let rc = rhelPromptCommand + "\n" + ShellIntegrationSnippet.bash.text
        assertRecords(try records(rc: rc, input: "hostname >/dev/null\nls /nope 2>/dev/null\n"),
                      [("hostname >/dev/null", "0"), ("ls /nope 2>/dev/null", "1")])
    }

    /// The whole line is the label, not its first simple command.
    func testAPipelineOrListIsRecordedWhole() throws {
        let rc = rhelPromptCommand + "\n" + ShellIntegrationSnippet.bash.text
        assertRecords(try records(rc: rc, input: "echo a | wc -l >/dev/null; false\nfor i in 1 2; do :; done\n"),
                      [("echo a | wc -l >/dev/null; false", "1"), ("for i in 1 2; do :; done", "0")])
    }

    /// Nothing that wasn't typed at a prompt: not an empty Return, not
    /// PROMPT_COMMAND itself, not a line in the rc file after the snippet.
    func testOnlyTypedCommandsMakeRecords() throws {
        let rc = rhelPromptCommand + "\n" + ShellIntegrationSnippet.bash.text + "\nPATH=$PATH:/opt/x\nhistory -a\n"
        assertRecords(try records(rc: rc, input: "\n\ntrue\n\n"), [("true", "0")])
    }

    /// With `set -T` the DEBUG trap is inherited by functions, so it fires on
    /// `__portside_precmd`'s own first line after an empty Return. If the
    /// empty-Return check returns still armed, that line — `local
    /// __portside_ret=$?` — is recorded as a command.
    func testAnEmptyReturnRecordsNothingUnderSetT() throws {
        let rc = "set -T\n" + ShellIntegrationSnippet.bash.text
        assertRecords(try records(rc: rc, input: "\n\ntrue\n\n"), [("true", "0")])
    }

    /// History skipping a line (a leading space under ignorespace, history
    /// off) must not label it as the previous command. The fallback is
    /// `BASH_COMMAND`, which is bash's own reprint of the command — hence
    /// `> /dev/null` with a space where the line as typed had none.
    func testALineHistorySkippedStillGetsItsOwnLabel() throws {
        let rc = "HISTCONTROL=ignoreboth\n" + ShellIntegrationSnippet.bash.text
        assertRecords(try records(rc: rc, input: "echo one >/dev/null\n echo two >/dev/null\n"),
                      [("echo one >/dev/null", "0"), ("echo two > /dev/null", "0")])
        let off = ShellIntegrationSnippet.bash.text + "\nset +o history\n"
        assertRecords(try records(rc: off, input: "echo a >/dev/null\nfalse\n"),
                      [("echo a > /dev/null", "0"), ("false", "1")])
    }

    /// The upgrade: a host with v3 in its `.bashrc` gets the installer's repair
    /// and v4 appended. v3's trap, still live while the file loads, used to
    /// record v4's first line as a command at every login.
    func testUpgradingFromV3LeavesNoPhantomRecord() throws {
        let rcURL = dir.appendingPathComponent("existing")
        try (rhelPromptCommand + "\n" + Self.v3).write(to: rcURL, atomically: true, encoding: .utf8)
        let repair = Process()
        repair.executableURL = URL(fileURLWithPath: "/bin/sh")
        repair.arguments = ["-c", "f='\(rcURL.path)'\n" + ShellIntegrationSnippet.bash.repairCommand]
        try repair.run()
        repair.waitUntilExit()
        let upgraded = try String(contentsOf: rcURL, encoding: .utf8) + "\n" + ShellIntegrationSnippet.bash.text

        XCTAssertFalse(upgraded.contains("trap '__portside_preexec' DEBUG"), "v3's trap was commented out")
        assertRecords(try records(rc: upgraded, input: "hostname >/dev/null\nfalse\n"),
                      [("hostname >/dev/null", "0"), ("false", "1")])
    }

    /// v3 as installed on hosts before 0.32, verbatim.
    static let v3 = #"""
        # Portside shell integration v3 (https://github.com/mcglothi/portside)
        # __portside_integration_v3 -- version marker; the installer greps for this
        # Reports the working directory (OSC 7) so the SFTP pane can follow `cd`,
        # and command boundaries (OSC 133) so commands can be timestamped.
        #
        # Interactive shells only. bash reads this file for NON-interactive
        # remote shells as well, and the DEBUG trap below fires there too --
        # its OSC 133 output then lands in whatever binary protocol is using
        # the channel. sftp reports that as "Received message too long", with
        # a length that decodes back to the escape's own first four bytes.
        case "$-" in
          *i*)
            __portside_preexec() {
              [ -n "$COMP_LINE" ] && return              # tab completion, not a command
              [ "$BASH_COMMAND" = "$PROMPT_COMMAND" ] && return
              [ -n "$__portside_running" ] && return     # DEBUG fires per simple command
              __portside_running=1
              printf '\033]133;C\007'
              printf '\033]133;E;%s\007' "$(printf '%s' "$BASH_COMMAND" | base64 | tr -d '\n')"
            }
            __portside_precmd() {
              local __portside_ret=$?
              if [ -n "$__portside_running" ]; then
                printf '\033]133;D;%s\007' "$__portside_ret"
                unset __portside_running
              fi
              printf '\033]7;file://%s%s\033\\' "${HOSTNAME:-$(hostname)}" "$PWD"
              printf '\033]133;A\007'
            }
            case "$PROMPT_COMMAND" in
              *__portside_precmd*) ;;
              *) PROMPT_COMMAND="__portside_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
            esac
            trap '__portside_preexec' DEBUG
            ;;
          *)
            # Repairs a v2 block sitting earlier in this file, which set that
            # trap unconditionally. Appending this version is not enough on
            # its own -- v2's trap is already armed by the time we get here,
            # so it has to be disarmed. Only ever clears Portside's own trap.
            case "$(trap -p DEBUG 2>/dev/null)" in
              *__portside_preexec*) trap - DEBUG ;;
            esac
            ;;
        esac
        """#
}
