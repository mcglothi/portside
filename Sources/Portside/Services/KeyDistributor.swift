import Foundation

/// What happened to one host in a push.
enum KeyPushOutcome: Equatable {
    /// The key was appended to `authorized_keys`.
    case added
    /// A matching entry was already in `authorized_keys`; nothing was written.
    ///
    /// **Not "the host trusts this key".** The check locates the key's fields;
    /// the line it found may carry an option sshd refuses, or one that has since
    /// stopped authorizing. Appending a bare copy anyway would be worse — it
    /// would quietly widen access past an intentional `from=` or `command=` — so
    /// not writing is right. The status just must not overstate what it means.
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

    /// Whether `authorized_keys` ends up holding an entry for this key, whoever
    /// put it there. **Presence, not trust** — see `alreadyPresent`.
    var keyEntryPresent: Bool {
        self == .added || self == .alreadyPresent
    }

    var label: String {
        switch self {
        case .added: return "Key added"
        case .alreadyPresent: return "Already present"
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
    /// Idempotency is checked with `awk` over the type/blob pair rather than
    /// `grep -F` over the whole line — see `installedCheck`. `grep` would match
    /// inside a *commented out* entry and report the host as already trusting a
    /// key it does not, and it would miss a match whose comment had been
    /// edited; scanning fields also handles entries carrying `command=`/`from=`
    /// options, where the algorithm is not the first field.
    /// The script is the same whether or not an `account` is given; escalation
    /// lives in `remoteCommand`, which runs it under `sudo -H -u <account>`.
    ///
    /// ## Root does not appear in this path at all
    ///
    /// 0.23.0 ran the whole thing as root so it could create a missing home,
    /// then chowned what it made. That was a privilege escalation: root working
    /// inside a directory the account controls follows whatever that account
    /// points `~/.ssh`, `authorized_keys` or the predictable backup name at.
    ///
    /// The obvious repair — validate the path first — cannot be made sound in
    /// a shell. Ownership plus POSIX mode bits do not prove a directory has no
    /// unprivileged writer: an ACL can grant `add_file`/`delete_child` to
    /// somebody while the mode still reads `0755 root root`, so the check
    /// passes and the component can still be swapped before the write. Doing it
    /// properly needs fd-relative (`openat`) semantics, which is a helper
    /// binary and a platform threat model, not a line of `find`.
    ///
    /// So Portside no longer creates homes. It requires one that already exists
    /// and is **usable by** the account, and does everything **as** that
    /// account — which removes the symlink question, the ownership repair and
    /// the nested escalation together, rather than guarding each one.
    ///
    /// Note the property precisely: the script checks that the home *exists*
    /// and then lets the account's own permissions decide. It does not prove
    /// ownership, and saying so would claim more than the code does. What is
    /// guaranteed is that every write happens as the target account — which is
    /// the property that matters, and a stronger one than an ownership check
    /// could give, since a check can be raced and an identity cannot.
    /// An `awk` program that finds a key at its **real position** in an
    /// `authorized_keys` line, and the predicate built on it.
    ///
    /// ## Why this is a parser
    ///
    /// The format is `[options] keytype base64 [comment]`. Two cheaper rules
    /// were tried and both were wrong in ways that destroy access:
    ///
    /// - **Blob anywhere.** A blob appearing in another key's *comment*
    ///   satisfied the check, so a push reported a key installed that was not,
    ///   and the retire path deleted the unrelated key whose comment mentioned
    ///   it.
    /// - **Type and blob adjacent anywhere.** Also insufficient, and this one
    ///   looked convincing enough to ship. Both of these falsely match a target
    ///   of `ssh-ed25519 AAAATARGET` while the line actually grants
    ///   `ssh-rsa AAAAOTHER`:
    ///   ```
    ///   ssh-rsa AAAAOTHER note ssh-ed25519 AAAATARGET
    ///   command="echo ssh-ed25519 AAAATARGET now",no-pty ssh-rsa AAAAOTHER real
    ///   ```
    ///   A key quoted inside a comment or an option is a *reference* to it, not
    ///   an authorization for it.
    ///
    /// So the options field is skipped properly: it ends at the first
    /// whitespace that is not inside a double-quoted section, honouring
    /// backslash escapes. The type is the token after that, and the blob the
    /// token after the type. A line beginning with a key type has no options.
    ///
    /// **This locates key fields. It does not validate options and does not
    /// prove authorization.** sshd parses the options too, refuses the whole
    /// line if any is unrecognised, and enforces the ones it understands — so a
    /// line this finds may be one sshd rejects outright. Anything *destructive*
    /// must therefore use `bareEntryCheck` instead, which is deliberately **not**
    /// this parser: the whole point there is to reject what this helpfully skips
    /// past. Removal shares this one, because finding an old key wherever it
    /// sits is exactly what removal wants.
    /// Parses the key fields from the current authorized_keys record. It works
    /// on a copy so removal callers can preserve the original record exactly.
    static let authorizedKeysFieldParser = """
      line = $0
      sub(/\\r$/, "", line)
      sub(/^[ \\t]+/, "", line)
      t = ""; b = ""; hasKeyFields = 0
      if (line !~ /^#/ && line != "") {
        split(line, f, /[ \\t]+/)
        if (f[1] ~ /^(ssh-|ecdsa-|sk-)/) { t = f[1]; b = f[2] }
        else {
          inq = 0
          for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "\\\\") { i++; continue }
            if (c == "\\"") { inq = !inq; continue }
            if (!inq && (c == " " || c == "\\t")) break
          }
          rest = substr(line, i + 1)
          sub(/^[ \\t]+/, "", rest)
          split(rest, g, /[ \\t]+/)
          t = g[1]; b = g[2]
        }
        if (t != "" && b != "") hasKeyFields = 1
      }
    """

    static let authorizedKeysMatcher = """
    {
      \(authorizedKeysFieldParser)
      if (hasKeyFields && t == T && b == B) { found = 1; exit }
    }
    END { exit !found }
    """

    /// True (exit 0) when `file` contains this key as a **bare entry** — the key
    /// type in the first field, no options at all.
    ///
    /// ## Why "found the key's fields" is not "the key works"
    ///
    /// `installedCheck` locates a key by field position, which is right for
    /// deciding whether to append. It is **not** a statement that the host will
    /// authenticate with it, and using it as one is a way to remove somebody's
    /// old key while the new one does not work. sshd does more than locate
    /// fields: it parses the options and refuses the line outright if any is
    /// unknown, and enforces the ones it understands.
    ///
    /// Measured on a fixture host running OpenSSH 9.2p1 — the same
    /// `authorized_keys` line, prefixed with `portside-unknown-option`:
    ///
    /// ```text
    /// bare entry                              → sshd: authenticates
    /// portside-unknown-option ssh-ed25519 …   → sshd: Permission denied
    /// expiry-time="19990101" ssh-ed25519 …    → sshd: Permission denied
    /// ```
    ///
    /// `installedCheck` says the key is there in all three.
    ///
    /// So the retirement guard uses this instead, and **fails closed**: it
    /// accepts only the shape Portside itself installs. A key sitting behind
    /// options might be perfectly valid, or might have expired an hour ago, and
    /// nothing short of reimplementing sshd's option parser can tell the
    /// difference from here. Refusing to retire in that case costs the user a
    /// manual step; guessing wrong costs them the host.
    ///
    /// Removal stays option-aware — an old key must be removable wherever it
    /// sits — because being over-eager there is safe and being under-eager
    /// leaves a key behind.
    static func bareEntryCheck(for key: PublicKey, file: String = "\"$f\"") -> String {
        "awk -v T=\(ShellQuoting.quote(key.algorithm)) -v B=\(ShellQuoting.quote(key.blob)) "
            + "'\(bareEntryMatcher)' \(file)"
    }

    /// Deliberately does not reuse `authorizedKeysFieldParser`: the whole point
    /// is to reject anything the parser would helpfully skip past.
    static let bareEntryMatcher = """
    {
      line = $0
      sub(/\\r$/, "", line)
      sub(/^[ \\t]+/, "", line)
      if (line ~ /^#/ || line == "") next
      split(line, f, /[ \\t]+/)
      if (f[1] == T && f[2] == B) { found = 1; exit }
    }
    END { exit !found }
    """

    /// True (exit 0) when `file` contains this key in a key position.
    ///
    /// **Locates a key; does not prove it authorizes.** See
    /// `bareEntryCheck` for the difference and why anything
    /// destructive must use that one.
    static func installedCheck(for key: PublicKey, file: String = "\"$f\"") -> String {
        "awk -v T=\(ShellQuoting.quote(key.algorithm)) -v B=\(ShellQuoting.quote(key.blob)) "
            + "'\(authorizedKeysMatcher)' \(file)"
    }

    static func remoteScript(for key: PublicKey, nonce: String = "",
                             account: String? = nil) -> String {
        // `account` no longer changes the script. It used to select a root
        // variant that created the home and repaired ownership; that is gone,
        // and escalation now lives entirely in `remoteCommand`. The parameter
        // stays so callers read the same either way.
        _ = account
        return installPhase(for: key, nonce: nonce, home: #""$HOME""#)
    }

    /// Everything that touches `authorized_keys`, run **as the account that
    /// owns it** — the login user directly, or the target account via
    /// `sudo -H -u`.
    ///
    /// Running as the owner is what makes the symlink questions go away. A
    /// symlinked `authorized_keys` is followed rather than replaced, which is
    /// correct and is what the tests pin; it was only dangerous when *root* did
    /// the following. Nothing here chowns anything, because a file created by
    /// its owner already has the right owner.
    static func installPhase(for key: PublicKey, nonce: String, home: String) -> String {
        let line = ShellQuoting.quote(key.line)
        // Built from `$f` in the script rather than quoted in from here: a
        // quoted "$HOME/..." is a literal, so the copy would land in a relative
        // directory named `$HOME`, fail, and be swallowed by `2>/dev/null` —
        // leaving every push reporting success with no backup ever written.
        let backup = "\"$f\(backupSuffix)\""
        return """
        umask 077
        h=\(home)
        # No apostrophes in these messages: an unescaped ' inside a ${...}
        # expansion inside double quotes fails to parse, and `sh -n` on the
        # generated script is the only thing that shows it.
        if [ -z "$h" ]; then
          echo "portside: no home directory is set for this account" >&2
          exit 1
        fi
        if [ ! -d "$h" ]; then
          echo "portside: $h does not exist; create the home directory first" >&2
          exit 1
        fi
        d="$h/.ssh"; f="$d/authorized_keys"
        if [ ! -d "$d" ]; then mkdir -p "$d" || exit 1; chmod 700 "$d" 2>/dev/null; fi
        if [ ! -f "$f" ]; then : > "$f" || exit 1; chmod 600 "$f" 2>/dev/null; fi
        if \(installedCheck(for: key)); then
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
    /// `sudo -H -u <account>` — **one hop, directly to the target**, never via
    /// root. `-H` sets `HOME` from the passwd database, so the script resolves
    /// the right `~/.ssh`, and because it runs as the account every file it
    /// creates is already owned correctly.
    ///
    /// This was the design before 0.23.0, abandoned then for one reason: it
    /// cannot create a missing home. Portside no longer tries to — see
    /// `remoteScript` — so the reason is gone and the escalation goes with it.
    ///
    /// The script travels base64-encoded through a command substitution rather
    /// than being interpolated into `sh -c '…'`: it contains single quotes of
    /// its own (every path and the key line are shell-quoted), and nesting
    /// those inside another layer of quoting is how this kind of wrapper
    /// usually breaks. Base64's alphabet cannot terminate a quoted string.
    ///
    /// `-S` reads the sudo password from stdin, which `push` supplies once and
    /// never again; `-p ''` silences the prompt so it can't be mistaken for
    /// output. A host where sudo is unavailable, or where policy forbids this
    /// RunAs target, fails and is reported like any other failure.
    static func remoteCommand(for key: PublicKey, nonce: String,
                              account: String? = nil) -> String {
        guard let account = account?.trimmingCharacters(in: .whitespaces),
              !account.isEmpty else {
            return remoteScript(for: key, nonce: nonce)
        }
        let script = remoteScript(for: key, nonce: nonce)
        let encoded = Data(script.utf8).base64EncodedString()
        return "__pk=\(ShellQuoting.quote(encoded)); "
            + "sudo -S -p '' -H -u \(ShellQuoting.quote(account)) sh -c "
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
    /// Splitting on `\.isNewline`, not on `"\n"` — **`\r\n` is a single Swift
    /// `Character`**, so `split(separator: "\n")` finds no separator at all in
    /// CRLF output and returns the whole blob as one line. ssh writes its own
    /// client errors with CRLF (measured: "Could not resolve hostname" arrives
    /// as `\r\n`), so this degraded every failure ssh itself reported: either a
    /// leading `Warning:` swallowed the entire transcript and left only the exit
    /// code, or the whole multi-line transcript came back as one host's
    /// "reason". Messages relayed from the *remote* side use plain `\n`, which
    /// is why sudo's refusals looked correct and hid this.
    static func failureReason(status: Int32, err: String) -> String {
        let lines = err
            .split(whereSeparator: \.isNewline)
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
    @MainActor
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
                progress(result)
                continue
            }
            let outcome = await push(key: key, to: entry, password: password(entry),
                                     defaults: defaults, account: account, runner: runner)
            let result = KeyPushResult(entryID: entry.id, hostName: entry.name, outcome: outcome)
            results.append(result)
            progress(result)
        }
        return results
    }

    static let defaultRunner: Runner = { executable, args, environment, stdin in
        try await SFTPClient.runProcess(executable, args, stdin: stdin, environment: environment)
    }
}
