import Foundation
import XCTest
@testable import Portside

/// Inventory metadata is untrusted — libraries are importable from portable
/// JSON and MobaXterm files — and Kubernetes enumeration crosses a shell on
/// both the local (`sh -lc`) and remote (`ssh host <cmd>`) paths. These are the
/// values a crafted library would carry.
final class ShellQuotingTests: XCTestCase {

    /// Runs the quoted string through a real shell and reports what the command
    /// actually received, which is the only convincing check.
    private func roundTrip(_ value: String) -> String? {
        let command = "printf '%s' \(ShellQuoting.quote(value))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    func testOrdinaryValuesSurviveVerbatim() {
        for value in ["default", "kube-system", "prod-cluster", "a.b/c:d_e", "team=platform"] {
            XCTAssertEqual(roundTrip(value), value, "mangled: \(value)")
        }
    }

    func testCommandSeparatorsAreNeutralised() {
        // The headline case: a namespace of `default; rm -rf ~` must arrive as
        // text, not run.
        let hostile = "default; echo PWNED"
        XCTAssertEqual(roundTrip(hostile), hostile)
    }

    func testSubstitutionsAreNotExpanded() {
        for value in ["$(whoami)", "`whoami`", "${HOME}", "$HOME"] {
            XCTAssertEqual(roundTrip(value), value, "expanded: \(value)")
        }
    }

    func testQuotesAndBackslashesSurvive() {
        for value in ["it's", "\"quoted\"", "back\\slash", "'", "''", "a'b\"c\\d"] {
            XCTAssertEqual(roundTrip(value), value, "mangled: \(value)")
        }
    }

    func testPipesRedirectsAndGlobsAreInert() {
        for value in ["a | b", "a > /tmp/x", "a && b", "a || b", "*", "~", "a\nb"] {
            XCTAssertEqual(roundTrip(value), value, "mangled: \(value)")
        }
    }

    func testEmptyValueStaysAnEmptyArgument() {
        XCTAssertEqual(ShellQuoting.quote(""), "''")
        XCTAssertEqual(roundTrip(""), "")
    }

    // MARK: - Command assembly

    /// Executes the generated command against a stub `kubectl` that echoes its
    /// arguments. Substring-matching the command string proves nothing — the
    /// separator legitimately appears *inside* the quotes — so the only real
    /// question is whether a shell executes it or passes it along as text.
    func testKubernetesCommandCannotInjectWhenActuallyRun() throws {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: bin) }
        let stub = bin.appendingPathComponent("kubectl")
        try "#!/bin/sh\nprintf 'ARG:%s\\n' \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        var entry = SessionEntry(name: "cluster")
        entry.kind = .kubernetes
        entry.kubernetes = KubernetesTarget(context: "ctx; echo PWNED", namespace: "ns$(id)")
        let command = try XCTUnwrap(ContainerLister.enumerationCommand(for: entry))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": bin.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        XCTAssertFalse(output.contains("\nPWNED"), "the injected command executed")
        XCTAssertFalse(output.hasPrefix("PWNED"), "the injected command executed")
        XCTAssertTrue(output.contains("ARG:--context=ctx; echo PWNED"),
                      "the value should reach kubectl intact, as one argument")
        XCTAssertTrue(output.contains("ARG:--namespace=ns$(id)"),
                      "command substitution must not be expanded")
    }

    func testFlagsUseEqualsFormSoLeadingDashesCannotBecomeFlags() {
        // `--namespace -o=json` would be two arguments; `--namespace=-o=json`
        // is one, and kubectl reads it as a (bogus) namespace rather than a flag.
        var entry = SessionEntry(name: "cluster")
        entry.kind = .kubernetes
        entry.kubernetes = KubernetesTarget(context: "-x", namespace: "-o=json")

        let parts = ContainerLister.enumerationArguments(for: entry)
        XCTAssertEqual(parts?.filter { $0.hasPrefix("--context=") }.count, 1)
        XCTAssertEqual(parts?.filter { $0.hasPrefix("--namespace=") }.count, 1)
        XCTAssertFalse(parts?.contains("-o=json") ?? true,
                       "the value must never stand alone as its own argument")
    }

    func testPlainHostsHaveNoEnumerationCommand() {
        XCTAssertNil(ContainerLister.enumerationCommand(for: SessionEntry(name: "web")))
    }
}
