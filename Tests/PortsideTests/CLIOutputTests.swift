import XCTest
@testable import Portside

/// What `portside` prints for a person: the real binary, in a pty (via
/// `script`, since it prints JSON whenever stdout isn't a terminal), against
/// a stub socket answering in the shapes Portside sends.
final class CLIOutputTests: XCTestCase {
    private var socketPath: String!
    private var server: AgentServer!

    override func setUpWithError() throws {
        socketPath = "/tmp/pscli-\(UUID().uuidString.prefix(8)).sock"
        server = AgentServer(socketPath: socketPath) { request, _ in
            let row: (String, String) -> JSONValue = { host, text in
                .object(["host": .string(host), "pane": .string(UUID().uuidString), "text": .string(text),
                         "commands": .array([.object(["command": .string("uptime"), "exitCode": .number(0),
                                                      "finished": .bool(true), "output": .string(text)])])])
            }
            // A tab, even of one pane, answers with a list.
            return AgentProtocol.Response(id: request.id, result: .object([
                "untrusted": .bool(true),
                "panes": .array([row("web1", "hello-from-web1"), row("web2", "hello-from-web2")]),
            ]))
        }
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func human(_ args: [String]) throws -> String {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("portside-cli")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", binary.path] + args + ["--socket", socketPath]
        let out = Pipe()
        process.standardOutput = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testScreenOfATabShowsEachPane() throws {
        let out = try human(["screen", "tab"])
        XCTAssertTrue(out.contains("web1") && out.contains("hello-from-web1"), out)
        XCTAssertTrue(out.contains("web2") && out.contains("hello-from-web2"), out)
    }

    func testLastOfATabShowsEachPanesCommands() throws {
        let out = try human(["last", "tab"])
        XCTAssertTrue(out.contains("uptime"), out)
        XCTAssertTrue(out.contains("hello-from-web2"), out)
    }
}
