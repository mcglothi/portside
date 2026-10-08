import XCTest
@testable import Portside

/// `portside mcp`, run as the real binary against a stub socket: what an MCP
/// client sends, and what reaches the app. The app-side rules are covered by
/// `AgentAccessTests`; this pins the translation in between.
final class MCPServerTests: XCTestCase {
    private var socketPath: String!
    private var server: AgentServer!
    private let received = Received()

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AgentProtocol.Request] = []
        func add(_ r: AgentProtocol.Request) { lock.withLock { items.append(r) } }
        var all: [AgentProtocol.Request] { lock.withLock { items } }
    }

    override func setUpWithError() throws {
        socketPath = "/tmp/psmcp-\(UUID().uuidString.prefix(8)).sock"
        let received = self.received
        server = AgentServer(socketPath: socketPath) { request, _ in
            received.add(request)
            if request.method == "connect" {
                return AgentProtocol.Response(id: request.id, error: .declined)
            }
            return AgentProtocol.Response(id: request.id, result: .array([.string("ok")]))
        }
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    private var binary: URL {
        // Tests run from .build/<config>/PortsideTests.xctest; the CLI sits beside it.
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("portside-cli")
    }

    /// Sends `lines` to `portside mcp` and returns its replies keyed by id.
    private func session(_ lines: [[String: Any]]) throws -> [Int: [String: Any]] {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp", "--socket", socketPath]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        for line in lines {
            var data = try JSONSerialization.data(withJSONObject: line)
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
        }
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var replies: [Int: [String: Any]] = [:]
        for line in out.split(separator: 0x0A) {
            let m = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            if let id = m["id"] as? Int { replies[id] = m }
        }
        return replies
    }

    private func call(_ id: Int, _ name: String, _ args: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": args]]
    }

    func testHandshakeAndToolListing() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), binary.path)
        let replies = try session([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "nope"],
        ])
        let initResult = replies[1]?["result"] as? [String: Any]
        XCTAssertEqual(initResult?["protocolVersion"] as? String, "2025-06-18")
        let tools = (replies[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("portside_connect"))
        XCTAssertTrue(names.contains("portside_list_hosts"))
        // Reading tools say so; closing says it destroys something.
        let hints = Dictionary(uniqueKeysWithValues: tools.map {
            ($0["name"] as! String, $0["annotations"] as! [String: Any])
        })
        XCTAssertEqual(hints["portside_list_hosts"]?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(hints["portside_connect"]?["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(hints["portside_close_tab"]?["destructiveHint"] as? Bool, true)
        XCTAssertNotNil(replies[3]?["error"], "unknown methods are errors, not silence")
        XCTAssertEqual(replies.count, 3, "the notification got no reply")
    }

    func testToolCallsBecomeSocketRequests() throws {
        let replies = try session([
            call(1, "portside_list_hosts", ["query": "env:prod -is:protected"]),
            call(2, "portside_connect", ["query": "folder:web", "grid": true]),
            call(3, "portside_close_tab", ["tab": "web-01"]),
            call(4, "portside_connect", [:]),
        ])
        let sent = received.all
        XCTAssertEqual(sent.map(\.method), ["hosts", "connect", "close"], "a call missing its arguments sends nothing")
        XCTAssertEqual(sent[0].params.query, "env:prod -is:protected")
        XCTAssertEqual(sent[1].params.layout, "grid")
        XCTAssertEqual(sent[2].params.name, "web-01")

        let hosts = replies[1]?["result"] as? [String: Any]
        XCTAssertEqual(hosts?["isError"] as? Bool, false)
        // A refusal in the app reaches the agent as a tool error naming it.
        let refused = replies[2]?["result"] as? [String: Any]
        XCTAssertEqual(refused?["isError"] as? Bool, true)
        let text = ((refused?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("declined"), text)
        XCTAssertEqual((replies[4]?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
}
