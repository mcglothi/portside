import Foundation
import XCTest
@testable import Portside

/// `ContainerTarget.execCommand` / `KubernetesTarget.execCommand` are typed
/// straight into a live shell by `SessionManager.postConnect` once a session
/// connects — and both structs decode from imported, untrusted libraries.
/// These reproduce the 2026-07-27 audit's crafted-import findings against a
/// real shell rather than asserting on the string shape.
final class ExecCommandInjectionTests: XCTestCase {

    /// Runs a generated exec command the same way `postConnect` effectively
    /// does — as text typed at a shell prompt — and reports what actually ran.
    private func run(_ command: String) -> String {
        let marker = "PWNED-\(UUID().uuidString)"
        let script = command.replacingOccurrences(of: "PWNED_MARKER", with: marker)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return output.contains(marker) ? marker : output
    }

    func testCrafted_ContainerName_CannotEscapeIntoTheHostShell() throws {
        var target = ContainerTarget()
        target.name = "web; touch /tmp/PWNED_MARKER #"
        let command = try XCTUnwrap(target.execCommand)
        XCTAssertFalse(run(command).hasPrefix("PWNED-"),
                       "crafted container name executed a second command")
    }

    func testCrafted_ContainerUser_CannotEscape() throws {
        var target = ContainerTarget()
        target.name = "web"
        target.user = "root; touch /tmp/PWNED_MARKER #"
        let command = try XCTUnwrap(target.execCommand)
        XCTAssertFalse(run(command).hasPrefix("PWNED-"),
                       "crafted -u value executed a second command")
    }

    func testCrafted_ContainerName_LookingLikeAFlagIsRejected() {
        var target = ContainerTarget()
        target.name = "--privileged"
        XCTAssertNil(target.execCommand, "a name that looks like a flag must not build a command")
    }

    func testCrafted_KubernetesNamespace_CannotEscapeIntoTheHostShell() throws {
        var target = KubernetesTarget()
        target.pod = "web"
        target.namespace = "default; touch /tmp/PWNED_MARKER #"
        let command = try XCTUnwrap(target.execCommand)
        XCTAssertFalse(run(command).hasPrefix("PWNED-"),
                       "crafted namespace executed a second command")
    }

    func testCrafted_KubernetesContext_SubstitutionNotExpanded() throws {
        var target = KubernetesTarget()
        target.pod = "web"
        target.context = "$(touch /tmp/PWNED_MARKER)"
        let command = try XCTUnwrap(target.execCommand)
        XCTAssertFalse(run(command).hasPrefix("PWNED-"),
                       "command substitution in context ran")
    }

    func testCrafted_PodName_LookingLikeAFlagIsRejected() {
        var target = KubernetesTarget()
        target.pod = "-oProxyCommand=touch"
        XCTAssertNil(target.execCommand, "a pod name that looks like a flag must not build a command")
    }

    func testImportedContainerJSON_QuotesTheHostileFields() throws {
        let json = """
        {"name": "web-01", "kind": "container",
         "container": {"engine": "docker", "name": "x`touch /tmp/PWNED_MARKER`", "shell": "sh", "user": ""}}
        """
        let entry = try JSONDecoder().decode(SessionEntry.self, from: Data(json.utf8))
        let command = try XCTUnwrap(entry.postConnectCommand)
        XCTAssertFalse(run(command).hasPrefix("PWNED-"),
                       "backticks in an imported container name executed")
    }

    func testImportedKubernetesJSON_QuotesTheHostileFields() throws {
        let json = """
        {"name": "cluster", "kind": "kubernetes",
         "kubernetes": {"context": "", "namespace": "ns'; touch /tmp/PWNED_MARKER; echo '",
                        "pod": "web", "container": "", "shell": "sh"}}
        """
        let entry = try JSONDecoder().decode(SessionEntry.self, from: Data(json.utf8))
        let command = try XCTUnwrap(entry.postConnectCommand)
        XCTAssertFalse(run(command).hasPrefix("PWNED-"),
                       "quote-breakout in an imported namespace executed")
    }

    func testStrippingControlCharacters_RemovesEscapeAndOtherC0Bytes() {
        let hostile = "web\u{1B}]0;pwned\u{07}\u{01}"
        XCTAssertEqual(hostile.strippingControlCharacters, "web]0;pwned")
    }

    func testStrippingControlCharacters_KeepsTabs() {
        XCTAssertEqual("a\tb".strippingControlCharacters, "a\tb")
    }
}
