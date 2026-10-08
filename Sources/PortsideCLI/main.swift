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
  connect QUERY [--grid] [--wait S]  open matching hosts; --wait until connected
  connect --ids ID,ID [--grid]   open hosts by id
  open-group NAME                open a saved group
  focus TAB                      bring a tab forward (id or title)
  close TAB                      close a tab (id or title)
  send PANE TEXT [--enter]       type into one pane (needs typing turned on);
                                 with --enter --wait S, run it and print the result
  send PANE --key KEY            press enter, tab, escape, ctrl-c or ctrl-d
  screen PANE [--lines N]        read a pane's screen as plain text
  last PANE [--count N] [--wait S]  the last command(s) in a pane: text, exit code,
                                 output; --wait until one that's running finishes
                                 PANE may be `current` (the pane you're looking at) or,
                                 for screen and last, `tab` (every pane in that tab)

shared inventories and your own hosts (editing needs its switch on in Settings):
  sources                        subscribed inventories, their pull status, linked folders
  pull [SOURCE]                  fetch the latest of one source, or all
  preview SOURCE [--resolve HOST=mine|theirs ...]
                                 what publishing would send, what's incoming, conflicts
  publish SOURCE [--message M] [--resolve HOST=mine|theirs ...]
                                 publish the linked folder (asks you in Portside first)
  link SOURCE FOLDER             copy a source's hosts into FOLDER for publishing
  host add NAME --host H [--user U] [--port P] [--folder F] [--alias A]
                                 [--identity PATH] [--env prod|staging|dev|personal] [--protected]
  host update ID|NAME [same fields] [--rename NEW]   (rename needs the id)
  host remove ID|NAME ...        remove your own hosts (asks; undoable)

  mcp                            run as an MCP server on stdio (for Claude Code, etc.)

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
var enter = false
var key: String?
var lineCount: Int?
var commandCount: Int?
var waitSeconds: Int?
var ids: [String]?
/// Host fields and publishing options, passed through as given.
var hostFields: [String: Any] = [:]
var resolutions: [String: String] = [:]
var positional: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--json": forceJSON = true
    case "--grid": grid = true
    case "--enter": enter = true
    case "--key":
        i += 1
        guard i < args.count else { fail("--key needs a key name", .usage) }
        key = args[i]
    case "--wait":
        i += 1
        guard i < args.count, let n = Int(args[i]) else { fail("--wait needs a number of seconds", .usage) }
        waitSeconds = n
    case "--count":
        i += 1
        guard i < args.count, let n = Int(args[i]) else { fail("--count needs a number", .usage) }
        commandCount = n
    case "--lines":
        i += 1
        guard i < args.count, let n = Int(args[i]) else { fail("--lines needs a number", .usage) }
        lineCount = n
    case "--socket":
        i += 1
        guard i < args.count else { fail("--socket needs a path", .usage) }
        socketOverride = args[i]
    case "--host", "--user", "--folder", "--alias", "--identity", "--env", "--message", "--rename", "--port":
        i += 1
        guard i < args.count else { fail("\(a) needs a value", .usage) }
        let keyName = ["--host": "hostname", "--identity": "identityFile", "--env": "environment",
                       "--rename": "name"][a] ?? String(a.dropFirst(2))
        if a == "--port" {
            guard let n = Int(args[i]) else { fail("--port needs a number", .usage) }
            hostFields[keyName] = n
        } else {
            hostFields[keyName] = args[i]
        }
    case "--protected":
        hostFields["protected"] = true
    case "--resolve":
        i += 1
        let pair = i < args.count ? args[i].split(separator: "=", maxSplits: 1).map(String.init) : []
        guard pair.count == 2 else { fail("--resolve needs HOST=mine or HOST=theirs", .usage) }
        resolutions[pair[0]] = pair[1]
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

if command == "mcp" {
    MCPServer(socket: AgentSocket.path(override: socketOverride)).run()
    exit(0)
}
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
case "send":
    method = "send"
    let parts = Array(positional.dropFirst())
    guard let pane = parts.first else { fail("send needs a pane id or host", .usage) }
    params["pane"] = pane
    let text = parts.dropFirst().joined(separator: " ")
    if let key { params["key"] = key } else if !text.isEmpty { params["text"] = text } else {
        fail("send needs TEXT or --key", .usage)
    }
    if enter { params["enter"] = true }
case "sources":
    method = "sources"
case "pull":
    method = "pull"
    if !rest.isEmpty { params["source"] = rest }
case "preview", "publish":
    method = command == "preview" ? "publish-preview" : "publish"
    guard !rest.isEmpty else { fail("\(command) needs a source name or id", .usage) }
    params["source"] = rest
    if !resolutions.isEmpty { params["resolutions"] = resolutions }
    if let m = hostFields["message"] { params["message"] = m }
case "link":
    method = "link"
    let parts = Array(positional.dropFirst())
    guard parts.count >= 2 else { fail("link needs SOURCE and FOLDER", .usage) }
    params["source"] = parts[0]
    params["folder"] = parts.dropFirst().joined(separator: " ")
case "host":
    let parts = Array(positional.dropFirst())
    guard let verb = parts.first else { fail("host needs add, update or remove", .usage) }
    let target = parts.dropFirst().joined(separator: " ")
    for (k, v) in hostFields where k != "message" { params[k] = v }
    switch verb {
    case "add":
        method = "host-add"
        guard !target.isEmpty else { fail("host add needs a NAME", .usage) }
        params["name"] = target
    case "update":
        method = "host-update"
        guard !target.isEmpty else { fail("host update needs an id or name", .usage) }
        if UUID(uuidString: target) != nil { params["ids"] = [target] } else {
            if hostFields["name"] != nil { fail("renaming needs the host's id (see `portside hosts --json`)", .usage) }
            params["name"] = target
        }
    case "remove":
        method = "host-remove"
        let keys = Array(parts.dropFirst())
        guard !keys.isEmpty else { fail("host remove needs ids or names", .usage) }
        params["ids"] = keys
    default:
        fail("host needs add, update or remove", .usage)
    }
case "last":
    method = "last-command"
    guard let pane = positional.dropFirst().first else { fail("last needs a pane id, host or current", .usage) }
    params["pane"] = pane
    if let commandCount { params["count"] = commandCount }
case "screen":
    method = "screen"
    guard let pane = positional.dropFirst().first else { fail("screen needs a pane id or host", .usage) }
    params["pane"] = pane
    if let lineCount { params["lines"] = lineCount }
default:
    fail("unknown command \u{201C}\(command)\u{201D}\n\n\(usage)", .usage)
}

if let waitSeconds, ["connect", "send", "last-command"].contains(method) { params["wait"] = waitSeconds }
let response: [String: Any]
switch AgentSocket.call(method, params, socket: AgentSocket.path(override: socketOverride)) {
case .success(let reply): response = reply
case .failure(let failure): fail("portside: \(failure.message)", failure.unavailable ? .unavailable : .error)
}

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
case "send":
    let r = result as? [String: Any] ?? [:]
    print("Typed into \(str(r["host"]).isEmpty ? str(r["pane"]) : str(r["host"])).")
    if let row = r["result"] as? [String: Any], let c = (row["commands"] as? [[String: Any]])?.first {
        let status = (c["finished"] as? Bool == true) ? "exit \(str(c["exitCode"]))" : "still running"
        print("\u{1B}[1m$ \(str(c["command"]))\u{1B}[0m  (\(status))")
        print(str(c["output"]))
    } else if r["waitedOut"] as? Bool == true {
        print("(gave up waiting; it may still be running)")
    }
case "screen":
    let r = result as? [String: Any] ?? [:]
    print(str(r["text"]))
case "last-command":
    let r = result as? [String: Any] ?? [:]
    for c in r["commands"] as? [[String: Any]] ?? [] {
        let status = (c["finished"] as? Bool == true) ? "exit \(str(c["exitCode"]))" : "still running"
        print("\u{1B}[1m$ \(str(c["command"]))\u{1B}[0m  (\(status))")
        print(str(c["output"]))
        print("")
    }
case "status":
    let r = result as? [String: Any] ?? [:]
    print("Portside \(str(r["version"]))  \u{00B7}  access: \(str(r["tier"]))  \u{00B7}  "
          + "\(str(r["hosts"])) hosts, \(str(r["tabs"])) tabs  \u{00B7}  asks above \(str(r["connectCap"])) hosts")
default:
    let out = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .fragmentsAllowed])
    print(String(decoding: out, as: UTF8.self))
}
