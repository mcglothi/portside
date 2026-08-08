import Foundation

/// What happened to one host in a push.
enum KeyPushOutcome: Equatable {
    /// The key was appended to `authorized_keys`.
    case added
    /// The host already trusted this key; nothing was written.
    case alreadyPresent
    /// Excluded before anything was attempted. Carries why, because "skipped"
    /// on its own reads as a bug when you were expecting a push.
    case skipped(String)
    /// The push was attempted and did not succeed.
    case failed(String)

    var isSuccess: Bool {
        switch self {
        case .added, .alreadyPresent: return true
        case .skipped, .failed: return false
        }
    }

    /// Whether the host ended up trusting the key, whoever put it there.
    var hostTrustsKey: Bool {
        self == .added || self == .alreadyPresent
    }

    var label: String {
        switch self {
        case .added: return "Key added"
        case .alreadyPresent: return "Already had it"
        case .skipped(let why): return "Skipped — \(why)"
        case .failed(let why): return "Failed — \(why)"
        }
    }
}

struct KeyPushResult: Identifiable, Equatable {
    let entryID: UUID
    let hostName: String
    let outcome: KeyPushOutcome
    var id: UUID { entryID }
}

/// Pushes a public key to a *selection* of hosts.
///
/// The single-host case is one `ssh-copy-id` command and needs no GUI; the
/// fleet case is the feature. It is also the first thing Portside does that
/// **changes remote machines**, so the rules below are the feature, and the
/// convenience is incidental.
///
/// ## Never more than one password attempt per host
///
/// `NumberOfPasswordPrompts=1` is set on every connection, always, and there is
/// no retry anywhere in this file. Forty hosts pushed with a stale password is
/// forty failed authentications, and enough of those locks the account across
/// the estate — turning "the key didn't install" into "nobody can log in".
/// A push that fails is reported and left alone.
///
/// When Portside holds no password for a host, the connection additionally runs
/// under `BatchMode=yes` so ssh fails immediately rather than blocking on a
/// prompt no one is watching. A push that hangs on host seventeen of forty is
/// its own kind of failure.
///
/// ## What it does on the host
///
/// `~/.ssh` and `authorized_keys` are created if absent (and only then given
/// `0700`/`0600` — an existing file's permissions are the user's business), the
/// key is appended only if the host does not already have it, and the file is
/// copied aside first. The check compares the algorithm and blob, never the
/// comment, because that pair is what `authorized_keys` authenticates on.
enum KeyDistributor {

    /// Runs a process. Injected so every rule above is testable without a
    /// network, a host, or a password — which matters more here than usual,
    /// since the thing most worth testing is what this *doesn't* do.
    typealias Runner = @Sendable (
        _ executable: String, _ args: [String], _ environment: [String]?, _ stdin: String
    ) async throws -> (status: Int32, out: String, err: String)

    static let resultMarker = "PORTSIDE-RESULT:"

    /// A per-push random tag appended to the marker.
    ///
    /// The marker is what decides success, and it is read out of the host's
    /// stdout — which also carries anything the login shell feels like
    /// printing. A fixed string is guessable and, more plausibly than
    /// malice, could simply appear in a banner or a `motd` someone pasted a
    /// Portside log into, turning a failed push into a reported success. A
    /// nonce the host cannot know in advance removes the class.
    static func newNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }
    static let backupSuffix = ".portside-backup"

    // MARK: - The remote script

    /// The shell run on the host. Written to be sh-portable: hosts that would
    /// need a key pushed to them are exactly the hosts least likely to have a
    /// modern shell.
    ///
    /// Idempotency is checked with `awk` over the blob rather than `grep -F`
    /// over the whole line. `grep` would match the blob inside a *commented
    /// out* entry and report the host as already trusting a key it does not,
    /// and it would miss a match whose comment had been edited. Scanning
    /// non-comment lines field by field also handles entries carrying
    /// `command=`/`from=` options, where the algorithm is not the first field.
    static func remoteScript(for key: PublicKey, nonce: String = "") -> String {
        let blob = ShellQuoting.quote(key.blob)
        let line = ShellQuoting.quote(key.line)
        // Built from `$f` in the script rather than quoted in from here: a
        // quoted "$HOME/..." is a literal, so the copy would land in a relative
        // directory named `$HOME`, fail, and be swallowed by `2>/dev/null` —
        // leaving every push reporting success with no backup ever written.
        let backup = "\"$f\(backupSuffix)\""
        return """
        umask 077
        d="$HOME/.ssh"; f="$d/authorized_keys"
        if [ ! -d "$d" ]; then mkdir -p "$d" || exit 1; chmod 700 "$d" 2>/dev/null; fi
        if [ ! -f "$f" ]; then : > "$f" || exit 1; chmod 600 "$f" 2>/dev/null; fi
        if awk -v b=\(blob) '/^[[:space:]]*#/ {next} {for (i = 1; i <= NF; i++) if ($i == b) {found = 1; exit}} END {exit !found}' "$f"; then
          printf '%s%s present\\n' '\(resultMarker)' '\(nonce)'
        else
          cp "$f" \(backup) 2>/dev/null
          # A file not ending in a newline is common (hand-edited, or written
          # by something that didn't bother) and appending straight onto it
          # welds our key to the end of the last entry — breaking that host's
          # existing access *and* installing nothing usable.
          if [ -s "$f" ] && [ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]; then printf '\\n' >> "$f"; fi
          printf '%s\\n' \(line) >> "$f" || exit 1
          printf '%s%s added\\n' '\(resultMarker)' '\(nonce)'
        fi
        """
    }

    // MARK: - Connection arguments

    /// ssh arguments for one host.
    ///
    /// `hasPassword` decides only whether `BatchMode` is set — it never adds a
    /// retry, and there is no path through this function that allows more than
    /// one password prompt.
    ///
    /// The login is always the host's own user. Installing the key for a
    /// *different* account is `sudo`'s job, not the login's — see
    /// `remoteCommand(for:nonce:account:)`.
    static func sshArguments(for entry: SessionEntry, hasPassword: Bool,
                             defaults: ConnectionDefaults = ConnectionDefaults()) -> [String] {
        var args = [
            // The rule this whole feature is built around. First, so it is the
            // first thing anyone reads in a process listing or a bug report.
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=15",
        ]
        if !hasPassword {
            // Nothing to answer a prompt with: fail now rather than block the
            // queue on a host nobody is looking at.
            args += ["-o", "BatchMode=yes"]
        }
        if defaults.autoAcceptNewHostKeys ?? false {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        // Reuse an interactive session's master when there is one — that costs
        // no authentication at all — but never become the master, so a push
        // can't outlive itself as a socket other connections lean on.
        args += SSHControl.passiveOptions

        args += entry.sshArgs
        return args
    }

    // MARK: - Reaching another account

    /// The command actually handed to ssh.
    ///
    /// With no `account`, that is the script itself and the key lands in the
    /// login user's home — the `ssh-copy-id` model, where `[user@]hostname`
    /// decides both who authenticates and whose `authorized_keys` is written.
    /// No privileges are involved and nothing needs explaining.
    ///
    /// With an `account`, the login is unchanged and the script runs under
    /// `sudo -H -u <account>`. **This is the only honest way to reach an
    /// account you cannot log in as** — a key-only service account being
    /// bootstrapped is exactly the case, and it is why Ansible's
    /// `authorized_key` module pairs its `user:` parameter with `become`.
    /// `-H` sets `HOME` to the target's, so the untouched script resolves the
    /// right `~/.ssh`, and running *as* the target rather than as root means
    /// every file is created with the right ownership — no `chown` afterwards,
    /// and nothing for sshd's `StrictModes` to reject.
    ///
    /// The script travels base64-encoded through a command substitution rather
    /// than being interpolated into `sh -c '…'`: it contains single quotes of
    /// its own (every path and the key line are shell-quoted), and nesting
    /// those inside another layer of quoting is how this kind of wrapper
    /// usually breaks. Base64's alphabet cannot terminate a quoted string.
    ///
    /// `-S` reads the sudo password from stdin, which `push` supplies once and
    /// never again; `-p ''` silences the prompt so it can't be mistaken for
    /// output. Hosts where sudo is unavailable or needs a password we don't
    /// have fail and are reported, like any other failure.
    static func remoteCommand(for key: PublicKey, nonce: String,
                              account: String? = nil) -> String {
        let script = remoteScript(for: key, nonce: nonce)
        guard let account = account?.trimmingCharacters(in: .whitespaces),
              !account.isEmpty else { return script }
        let encoded = Data(script.utf8).base64EncodedString()
        let user = ShellQuoting.quote(account)
        return "__pk=\(ShellQuoting.quote(encoded)); "
            + "sudo -S -p '' -H -u \(user) sh -c "
            + "\"$(printf %s \"$__pk\" | base64 -d 2>/dev/null "
            + "|| printf %s \"$__pk\" | base64 -D 2>/dev/null)\""
    }

    /// Whether a push to this account needs sudo on the host — which is what
    /// the confirmation warns about.
    static func requiresSudo(account: String?) -> Bool {
        !((account ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - Result parsing

    /// Turns one completed ssh run into an outcome.
    ///
    /// Trusts the marker rather than the exit status: `ssh host 'script'`
    /// returns the script's status, and a host whose login shell prints a
    /// banner or whose profile exits non-zero would otherwise report a failure
    /// for a key that installed fine. The marker is only printed on the two
    /// paths that actually succeeded.
    static func outcome(status: Int32, out: String, err: String,
                        nonce: String = "") -> KeyPushOutcome {
        if out.contains("\(resultMarker)\(nonce) added") { return .added }
        if out.contains("\(resultMarker)\(nonce) present") { return .alreadyPresent }
        return .failed(failureReason(status: status, err: err))
    }

    /// The most useful line of ssh's stderr, or a description of the exit code.
    ///
    /// ssh is chatty on failure and the first line is rarely the informative
    /// one ("Warning: Permanently added…" precedes the actual error), so this
    /// prefers a line that names a known failure over simply taking the first.
    static func failureReason(status: Int32, err: String) -> String {
        let lines = err
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }

        let telling = lines.first {
            let l = $0.lowercased()
            // sudo's own refusals, named plainly. "sudo: a password is
            // required" and "is not in the sudoers file" are the two answers a
            // user needs when a push to another account fails, and burying
            // them under a generic exit code makes the feature look broken
            // rather than unpermitted.
            return l.contains("is not in the sudoers file")
                || l.contains("a password is required")
                || l.contains("no tty present")
                || l.contains("sorry, try again")
                || l.contains("unknown user")
                || l.contains("command not found")
                || l.contains("permission denied")
                || l.contains("host key verification failed")
                || l.contains("could not resolve")
                || l.contains("connection refused")
                || l.contains("connection timed out")
                || l.contains("operation timed out")
                || l.contains("no route to host")
                || l.contains("too many authentication failures")
        }
        if let telling { return telling }
        if let first = lines.first { return first }

        switch status {
        case 255: return "ssh could not connect"
        case 1: return "the host rejected the change (exit 1)"
        default: return "ssh exited with status \(status)"
        }
    }

    // MARK: - Pushing

    /// Pushes `key` to one host. Never retries.
    static func push(
        key: PublicKey,
        to entry: SessionEntry,
        password: String?,
        defaults: ConnectionDefaults = ConnectionDefaults(),
        account: String? = nil,
        runner: Runner = defaultRunner
    ) async -> KeyPushOutcome {
        var environment: [String]?
        var expire: (() -> Void)?
        var cleanup: (() -> Void)?
        if let password, !password.isEmpty,
           let injected = AskpassInjector.environment(for: password) {
            environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
                + injected.env
            expire = injected.expireSecret
            cleanup = injected.cleanup
        }
        defer {
            expire?()
            cleanup?()
        }

        let nonce = newNonce()
        let args = sshArguments(for: entry, hasPassword: environment != nil, defaults: defaults)
            + [remoteCommand(for: key, nonce: nonce, account: account)]

        // `sudo -S` reads the password from stdin. Sent once, never re-sent:
        // a failed sudo is logged on the host and repeated attempts carry the
        // same lockout risk as repeated ssh authentications, so the
        // one-attempt rule covers sudo too. Empty when there is nothing to
        // send, which leaves `sudo -S` to fail immediately rather than wait.
        let stdin = requiresSudo(account: account) && !(password ?? "").isEmpty
            ? (password ?? "") + "\n"
            : ""
        do {
            let result = try await runner("/usr/bin/ssh", args, environment, stdin)
            return outcome(status: result.status, out: result.out, err: result.err, nonce: nonce)
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Pushes `key` to every host in `entries`, one at a time, reporting each
    /// result as it lands.
    ///
    /// Sequential on purpose. Parallel pushes would multiply a wrong password
    /// into simultaneous failed authentications across the estate before the
    /// first failure could be seen, and this is the one operation where being
    /// slower is the safer behaviour. It also means `progress` arrives in the
    /// order the user is reading.
    static func push(
        key: PublicKey,
        to entries: [SessionEntry],
        password: @Sendable (SessionEntry) -> String?,
        defaults: ConnectionDefaults = ConnectionDefaults(),
        account: String? = nil,
        runner: Runner = defaultRunner,
        progress: @MainActor (KeyPushResult) -> Void
    ) async -> [KeyPushResult] {
        var results: [KeyPushResult] = []
        for entry in entries {
            if Task.isCancelled {
                let result = KeyPushResult(entryID: entry.id, hostName: entry.name,
                                           outcome: .skipped("cancelled"))
                results.append(result)
                await progress(result)
                continue
            }
            let outcome = await push(key: key, to: entry, password: password(entry),
                                     defaults: defaults, account: account, runner: runner)
            let result = KeyPushResult(entryID: entry.id, hostName: entry.name, outcome: outcome)
            results.append(result)
            await progress(result)
        }
        return results
    }

    static let defaultRunner: Runner = { executable, args, environment, stdin in
        try await SFTPClient.runProcess(executable, args, stdin: stdin, environment: environment)
    }
}
