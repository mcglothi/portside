import Darwin
import Foundation

// portside — drive the running Portside app from the command line.
//
// One request per invocation over the app's agent socket. Human-readable when
// stdout is a terminal, JSON when it isn't (or with --json), so the same
// command serves a person and an agent. Everything that matters — who may do
// what, what needs a person's OK — is decided in the app, never here.

let usage = """
usage: portside <command> [args] [--json] [--socket PATH]

  status                         app version, your access, counts
  hosts [QUERY]                  list hosts, optionally filtered (sidebar syntax)
  groups                         list saved groups
  tabs                           list open tabs and their panes
  connect QUERY [--grid]         open matching hosts (one tab each, or one grid)
  connect --ids ID,ID [--grid]   open hosts by id
  open-group NAME                open a saved group
  focus TAB                      bring a tab forward (id or title)
  close TAB                      close a tab (id or title)

QUERY uses the sidebar filter syntax: words, env:prod, folder:lab, kind:ssh,
is:protected, -env:prod, /regex/. Quote it in the shell: 'env:prod folder:web'.

Agent Access must be on in Portside (Settings \u{25B8} Agents). The first use from a
new program asks for approval in the app; protected hosts and large
selections ask again each time. MultiExec is never armed from here.
"""

enum Exit: Int32 { case ok = 0, error = 1, denied = 2, unavailable = 3, usage = 64 }

func fail(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code.rawValue)
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
var forceJSON = false
var socketOverride: String?
var grid = false
var ids: [String]?
var positional: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--json": forceJSON = true
    case "--grid": grid = true
    case "--socket":
        i += 1
        guard i < args.count else { fail("--socket needs a path", .usage) }
        socketOverride = args[i]
    case "--ids":
        i += 1
        guard i < args.count else { fail("--ids needs a comma-separated list", .usage) }
        ids = args[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    case "-h", "--help", "help":
        print(usage)
        exit(0)
    default:
        positional.append(a)
    }
    i += 1
}

guard let command = positional.first else { print(usage); exit(Exit.usage.rawValue) }
let rest = positional.dropFirst().joined(separator: " ")

var params: [String: Any] = [:]
let method: String
switch command {
case "status", "groups", "tabs":
    method = command
case "hosts":
    method = "hosts"
    if !rest.isEmpty { params["query"] = rest }
case "connect":
    method = "connect"
    if let ids { params["ids"] = ids } else if !rest.isEmpty { params["query"] = rest } else {
        fail("connect needs a QUERY or --ids", .usage)
    }
    params["layout"] = grid ? "grid" : "tabs"
case "open-group":
    method = "open-group"
    guard !rest.isEmpty else { fail("open-group needs a group name", .usage) }
    params["name"] = rest
case "focus", "close":
    method = command
    guard !rest.isEmpty else { fail("\(command) needs a tab id or title", .usage) }
    if UUID(uuidString: rest) != nil { params["ids"] = [rest] } else { params["name"] = rest }
default:
    fail("unknown command \u{201C}\(command)\u{201D}\n\n\(usage)", .usage)
}

// MARK: - Socket

/// Must match `AgentServer.socketPath(libraryDirectory:)` in the app.
func socketPath(override: String?) -> String {
    let env = ProcessInfo.processInfo.environment
    if let explicit = override ?? env["PORTSIDE_SOCKET"] { return explicit }
    let directory: String
    if let override = env["PORTSIDE_LIBRARY_DIR"] {
        directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true).path
    } else {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Portside").path
    }
    let preferred = (directory as NSString).appendingPathComponent("agent.sock")
    if preferred.utf8.count < 100 { return preferred }
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in directory.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return (NSTemporaryDirectory() as NSString).appendingPathComponent("portside-\(String(hash, radix: 16)).sock")
}

func send(_ request: [String: Any], to path: String) -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("portside: couldn't create a socket", .error) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let bytes = Array(path.utf8.prefix(raw.count - 1))
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        fail("portside: Portside isn't reachable at \(path).\n"
             + "Is it running, with Agent Access on (Settings \u{25B8} Agents)?", .unavailable)
    }
    var data = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
    data.append(0x0A)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }

    // A confirmation in the app can take up to a couple of minutes.
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        reply.append(contentsOf: buffer[0..<n])
        if buffer[n - 1] == 0x0A { break }
    }
    close(fd)
    guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        fail("portside: no reply from Portside", .error)
    }
    return object
}

let response = send(["id": 1, "method": method, "params": params], to: socketPath(override: socketOverride))

// MARK: - Output

let asJSON = forceJSON || isatty(STDOUT_FILENO) == 0

if let error = response["error"] as? [String: Any] {
    let code = error["code"] as? String ?? "error"
    let message = error["message"] as? String ?? "failed"
    if asJSON {
        let out = try! JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys])
        print(String(decoding: out, as: UTF8.self))
    } else {
        FileHandle.standardError.write(Data("portside: \(message)\n".utf8))
    }
    exit(["denied", "declined", "timed_out"].contains(code) ? Exit.denied.rawValue : Exit.error.rawValue)
}

let result = response["result"] ?? NSNull()
if asJSON {
    let out = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys,
                                                                          .fragmentsAllowed])
    print(String(decoding: out, as: UTF8.self))
    exit(0)
}

func str(_ v: Any?) -> String { (v as? String) ?? (v.map { "\($0)" } ?? "") }

func table(_ rows: [[String]], header: [String]) {
    let all = [header] + rows
    let widths = header.indices.map { col in all.map { $0[col].count }.max() ?? 0 }
    for (n, row) in all.enumerated() {
        let line = row.enumerated().map { col, cell in
            col == row.count - 1 ? cell : cell.padding(toLength: widths[col], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
        print(n == 0 ? "\u{1B}[1m\(line)\u{1B}[0m" : line)
    }
}

switch method {
case "hosts":
    let hosts = result as? [[String: Any]] ?? []
    if hosts.isEmpty { print("No hosts match."); break }
    table(hosts.map { h in
        let place = [str(h["source"]), str(h["folder"])].filter { !$0.isEmpty }.joined(separator: "/")
        let env = str(h["environment"]) == "none" ? "" : str(h["environment"])
        let flags = [(h["protected"] as? Bool == true) ? "protected" : "",
                     (h["favorite"] as? Bool == true) ? "\u{2605}" : ""].filter { !$0.isEmpty }.joined(separator: " ")
        return [str(h["name"]), str(h["target"]), env, place, flags]
    }, header: ["NAME", "TARGET", "ENV", "FOLDER", ""])
    print("\n\(hosts.count) host\(hosts.count == 1 ? "" : "s")")
case "groups":
    let groups = result as? [[String: Any]] ?? []
    if groups.isEmpty { print("No saved groups."); break }
    table(groups.map { [str($0["name"]), str($0["folder"]), str($0["panes"])] }, header: ["NAME", "FOLDER", "PANES"])
case "tabs":
    let tabs = result as? [[String: Any]] ?? []
    if tabs.isEmpty { print("No open tabs."); break }
    for tab in tabs {
        let mark = (tab["selected"] as? Bool == true) ? "\u{25B8} " : "  "
        let armed = (tab["multiExecArmed"] as? Bool == true) ? "  [MultiExec armed]" : ""
        print("\(mark)\(str(tab["title"]))  \(str(tab["id"]))\(armed)")
        for pane in tab["panes"] as? [[String: Any]] ?? [] {
            let state = (pane["connected"] as? Bool == true) ? "connected"
                : (pane["running"] as? Bool == true) ? "connecting" : "ended"
            print("      \(str(pane["host"]).isEmpty ? str(pane["title"]) : str(pane["host"]))  (\(state))")
        }
    }
case "connect":
    let r = result as? [String: Any] ?? [:]
    let names = (r["opened"] as? [String] ?? []).joined(separator: ", ")
    let layout = str(r["layout"]) == "grid" ? " in one grid (MultiExec off)" : ""
    print("Opened \((r["opened"] as? [Any])?.count ?? 0)\(layout): \(names)")
case "open-group":
    let r = result as? [String: Any] ?? [:]
    if r["alreadyOpen"] as? Bool == true { print("\u{201C}\(str(r["group"]))\u{201D} was already open; brought it forward.") }
    else {
        let missing = (r["missing"] as? Int ?? 0) > 0 ? " (\(str(r["missing"])) missing from the library)" : ""
        print("Opened \u{201C}\(str(r["group"]))\u{201D}: \(str(r["opened"])) panes\(missing)")
    }
case "status":
    let r = result as? [String: Any] ?? [:]
    print("Portside \(str(r["version"]))  \u{00B7}  access: \(str(r["tier"]))  \u{00B7}  "
          + "\(str(r["hosts"])) hosts, \(str(r["tabs"])) tabs  \u{00B7}  asks above \(str(r["connectCap"])) hosts")
default:
    let out = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .fragmentsAllowed])
    print(String(decoding: out, as: UTF8.self))
}
