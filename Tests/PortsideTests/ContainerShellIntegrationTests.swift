import XCTest
@testable import Portside

/// Shell integration inside a container (#25), against real containers: the
/// injection hosts get, typed once a local `docker exec` has attached. Skips
/// without a working `docker` (CI has none; OrbStack or Docker Desktop do).
@MainActor
final class ContainerShellIntegrationTests: XCTestCase {
    private var names: [String] = []

    private func docker(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["docker"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func container(_ image: String) throws -> String {
        try XCTSkipUnless(docker(["info"]).0 == 0, "no working docker")
        let name = "portside-it-\(UUID().uuidString.prefix(8))"
        let (status, out) = docker(["run", "-d", "--rm", "--name", name, image, "sleep", "300"])
        try XCTSkipUnless(status == 0, "couldn't start \(image): \(out)")
        names.append(name)
        return name
    }

    override func tearDown() async throws {
        for name in names { _ = docker(["rm", "-f", name]) }
    }

    private func session(_ name: String, shell: String, inject: Bool) throws -> (SessionManager, TerminalSession) {
        let sessions = SessionManager()
        sessions.localShell = ("/bin/zsh", ["-f"])
        var settings = TerminalSettings()
        settings.injectShellIntegration = inject
        sessions.terminalSettings = settings
        sessions.capturesCommandOutput = true
        var entry = SessionEntry(name: "box", hostname: "", kind: .container)
        entry.container = ContainerTarget(engine: .docker, name: name, shell: shell)
        sessions.connect(to: entry)
        return (sessions, try XCTUnwrap(sessions.tabs.last?.leaves.first))
    }

    private func screen(_ s: TerminalSession) -> String { AgentController.screenLines(s.terminalView.getTerminal()) }

    func testABashContainerGetsCommandRecording() async throws {
        let name = try container("bash:5.2")
        let (sessions, pane) = try session(name, shell: "bash", inject: true)
        defer { sessions.tabs.forEach(sessions.closeTab) }

        for _ in 0..<300 where !pane.terminalView.sawShellIntegration { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(pane.terminalView.sawShellIntegration, "no command marker from inside the container\n\(screen(pane))")

        pane.sendText("echo inside-$((6*7))\r")
        var recorded: CommandOutputCapture.Command?
        for _ in 0..<100 {
            recorded = pane.terminalView.outputCapture?.completed.last { $0.command.contains("inside-") }
            if recorded != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let command = try XCTUnwrap(recorded, screen(pane))
        XCTAssertEqual(command.output, "inside-42")
        XCTAssertEqual(command.exitCode, 0)
    }

    /// `ash` has no hook to use: the injected text does nothing there, and
    /// leaves no error behind.
    func testAnAshContainerIsLeftAsItWas() async throws {
        let name = try container("alpine:3.20")
        let (sessions, pane) = try session(name, shell: "sh", inject: true)
        defer { sessions.tabs.forEach(sessions.closeTab) }
        for _ in 0..<100 where pane.execStage() != .attached { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 3_000_000_000)   // the injection, if any, has been typed
        pane.sendText("echo still-$((6*7))\r")
        for _ in 0..<100 where !screen(pane).contains("still-42") { try await Task.sleep(nanoseconds: 100_000_000) }
        let text = screen(pane)
        XCTAssertTrue(text.contains("still-42"), text)
        for complaint in ["not found", "syntax error", "unexpected"] {
            XCTAssertFalse(text.lowercased().contains(complaint), "\(complaint)\n\(text)")
        }
    }

    /// With the setting off, nothing is typed into the container.
    func testNothingIsInjectedWhenTheSettingIsOff() async throws {
        let name = try container("bash:5.2")
        let (sessions, pane) = try session(name, shell: "bash", inject: false)
        defer { sessions.tabs.forEach(sessions.closeTab) }
        for _ in 0..<100 where pane.execStage() != .attached { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(pane.terminalView.sawShellIntegration)
    }

    /// The same through `kubectl exec` into a pod, against the fixture cluster
    /// (`Scripts/k8s-fixture`, context `orbstack`). Skips without it.
    func testABashPodGetsCommandRecording() async throws {
        let kubectl = ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        try XCTSkipIf(kubectl == nil, "no kubectl")
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: kubectl!)
        probe.arguments = ["--context=orbstack", "-n", "portside-fixture", "get", "pod", "bashbox", "--request-timeout=5s"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        try XCTSkipUnless(probe.terminationStatus == 0, "no fixture cluster with the bashbox pod")

        let sessions = SessionManager()
        sessions.localShell = ("/bin/zsh", ["-f"])
        var settings = TerminalSettings()
        settings.injectShellIntegration = true
        sessions.terminalSettings = settings
        sessions.capturesCommandOutput = true
        var target = KubernetesTarget()
        target.context = "orbstack"
        target.namespace = "portside-fixture"
        target.pod = "bashbox"
        target.shell = "bash"
        var entry = SessionEntry(name: "pod", hostname: "", kind: .kubernetes)
        entry.kubernetes = target
        sessions.connect(to: entry)
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)
        defer { sessions.tabs.forEach(sessions.closeTab) }

        for _ in 0..<300 where !pane.terminalView.sawShellIntegration { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(pane.terminalView.sawShellIntegration, "no command marker from inside the pod\n\(screen(pane))")
        pane.sendText("echo pod-$((6*7))\r")
        var recorded: CommandOutputCapture.Command?
        for _ in 0..<100 {
            recorded = pane.terminalView.outputCapture?.completed.last { $0.command.contains("pod-") }
            if recorded != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(try XCTUnwrap(recorded, screen(pane)).output, "pod-42")
    }

    /// The lines are POSIX: typed into fish they'd only make errors.
    func testOnlySHFamilyShellsGetTheInjection() {
        for ok in ["sh", "bash", "/bin/bash", "/usr/bin/zsh", "ash", "dash", "ksh"] {
            XCTAssertTrue(ShellIntegrationInjection.acceptsInjection(shell: ok), ok)
        }
        for no in ["fish", "/usr/bin/fish", "csh", "tcsh", "nu", "pwsh"] {
            XCTAssertFalse(ShellIntegrationInjection.acceptsInjection(shell: no), no)
        }
    }

    /// A container that exits part-way through the injection leaves the
    /// Mac's own shell in front; it must not get the rest.
    func testAContainerThatExitsMidInjectionLeavesTheLocalShellAlone() async throws {
        let name = try container("bash:5.2")
        let (sessions, pane) = try session(name, shell: "bash", inject: true)
        defer { sessions.tabs.forEach(sessions.closeTab) }
        for _ in 0..<100 where pane.execStage() != .attached { try await Task.sleep(nanoseconds: 100_000_000) }
        // Settle (0.5 s) plus a couple of paced lines, then the container goes.
        try await Task.sleep(nanoseconds: 800_000_000)
        _ = docker(["rm", "-f", name])
        for _ in 0..<100 where pane.execStage() == .attached { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 3_000_000_000)   // anything still queued has had its chance

        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        pane.sendText(" typeset -f __portside_preexec >/dev/null 2>&1 && echo yes > '\(marker.path)' || echo no > '\(marker.path)'\r")
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        let answer = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(answer, "no", "the Mac's own shell got the container's integration")
    }
}
