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
    /// Idempotency is checked with `awk` over the type/blob pair rather than
    /// `grep -F` over the whole line — see `installedCheck`. `grep` would match
    /// inside a *commented out* entry and report the host as already trusting a
    /// key it does not, and it would miss a match whose comment had been
    /// edited; scanning fields also handles entries carrying `command=`/`from=`
    /// options, where the algorithm is not the first field.
    /// `account` is set only for a sudo push. Without it the script runs as the
    /// login user in `$HOME`; with it, see `rootBootstrap` — root creates the
    /// account's home if it is missing and then **drops to the account** for
    /// everything else.
    ///
    /// ## Why not run the whole thing as root
    ///
    /// Running *as* the target gets file ownership for free but cannot
    /// bootstrap: `mkdir /home/svc_goose` as `svc_goose` fails because `/home`
    /// isn't theirs to write. That argued for doing everything as root and
    /// chowning afterwards, which is what shipped in 0.23.0 — and it was wrong.
    /// Root working inside a directory the account controls is a privilege
    /// escalation: the account can point `~/.ssh`, `authorized_keys` or the
    /// predictable backup name somewhere else and root follows it.
    ///
    /// The split resolves both. Root does the one thing only root can — create
    /// the home, in a parent the account cannot influence — and the account
    /// does everything inside it, which also means no `chown` is needed at all.
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
    /// backslash escapes, exactly as sshd reads it. The type is the token after
    /// that, and the blob the token after the type. A line beginning with a key
    /// type has no options at all.
    ///
    /// **Shared with retirement deliberately.** The question "does this line
    /// grant this key" must have one answer, because one side installs on it
    /// and the other deletes on it.
    static let authorizedKeysMatcher = """
    {
      line = $0
      sub(/^[ \\t]+/, "", line)
      if (line ~ /^#/ || line == "") next
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
      if (t == T && b == B) { found = 1; exit }
    }
    END { exit !found }
    """

    /// True (exit 0) when `file` grants `key`.
    static func installedCheck(for key: PublicKey, file: String = "\"$f\"") -> String {
        "awk -v T=\(ShellQuoting.quote(key.algorithm)) -v B=\(ShellQuoting.quote(key.blob)) "
            + "'\(authorizedKeysMatcher)' \(file)"
    }

    static func remoteScript(for key: PublicKey, nonce: String = "",
                             account: String? = nil) -> String {
        let target = account?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !target.isEmpty else {
            // No escalation: this runs as the login user in their own home,
            // where following a symlink is their business and not a privilege
            // boundary.
            return installPhase(for: key, nonce: nonce, home: #""$HOME""#)
        }
        return rootBootstrap(for: key, nonce: nonce, account: target)
    }

    /// Everything that touches `authorized_keys`. **Always runs as the account
    /// that owns the file** — as the login user directly, or dropped down to the
    /// target account after `rootBootstrap` has made the home exist.
    ///
    /// Running as the owner is what makes the symlink questions go away. A
    /// symlinked `authorized_keys` is followed rather than replaced, which is
    /// correct and is what the tests pin; it is only dangerous when *root* is
    /// the one following it. Nothing here chowns anything either, because files
    /// created by their owner already have the right owner.
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

    /// The root half of a cross-account push: make the account's home exist,
    /// then **drop privileges** and let the account install its own key.
    ///
    /// ## Why root does as little as possible
    ///
    /// The previous version ran the *whole* script as root against paths inside
    /// a home the target account controls. That is a local privilege escalation
    /// waiting to happen: the account can pre-create `~/.ssh`, `authorized_keys`
    /// or the predictable `.portside-backup` name as a symlink, and root then
    /// follows it. Pointing `~/.ssh` at `/root/.ssh` installs the attacker's key
    /// for root; pointing `authorized_keys` at `/etc/shadow` gets it copied to a
    /// backup that is then chowned *to them*.
    ///
    /// Checking for symlinks first is not a fix. The account owns the
    /// containing directory, so it can swap any component between the check and
    /// the write — a check-then-use race. The only durable answer is to stop
    /// being root before touching anything the account can influence.
    ///
    /// So root creates **only the home directory**, whose parent (`/home`, or
    /// whatever passwd says) is root-owned and therefore not something the
    /// account can redirect, chowns it, and hands off. Everything after that —
    /// `~/.ssh`, `authorized_keys`, the backup — is created by the account
    /// itself, which also means it is owned correctly with no `chown` at all.
    ///
    /// **A pre-existing root-owned `~/.ssh` is now reported rather than
    /// repaired.** The old code chowned it, which is the same unsafe pattern;
    /// and sshd's `StrictModes` rejects that directory anyway, so it was a
    /// broken state being silently papered over. Bootstrapping a genuinely new
    /// account is unaffected: nothing exists, so the account creates it all.
    static func rootBootstrap(for key: PublicKey, nonce: String, account: String) -> String {
        let inner = Data(installPhase(for: key, nonce: nonce, home: #""$1""#).utf8)
            .base64EncodedString()
        return """
        umask 077
        u=\(ShellQuoting.quote(account))
        # The account's real home, from passwd rather than a guess — `~u` isn't
        # expandable from a variable in POSIX sh, and assuming /home/$u is wrong
        # on any host that doesn't do it that way.
        h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
        [ -n "$h" ] || h=$(awk -F: -v u="$u" '$1 == u {print $6}' /etc/passwd 2>/dev/null)
        if [ -z "$h" ]; then echo "portside: unknown user $u" >&2; exit 1; fi
        if [ -h "$h" ]; then
          echo "portside: $h is a symbolic link; refusing to write through it as root" >&2
          exit 1
        fi
        case "$h" in /*) ;; *) echo "portside: $h is not an absolute path" >&2; exit 1 ;; esac
        if [ ! -d "$h" ]; then
          # Creating the home means root writes into a path it did not choose.
          # Checking only the final component is a check-then-use race — but a
          # race needs a racer: if no unprivileged party can modify ANY ancestor,
          # nothing can be swapped between the check and the mkdir. So every
          # ancestor must be a real directory, root-owned, and writable by
          # nobody else. That is what makes this safe without openat.
          # Canonicalise the parent before validating it. A symlinked ancestor
          # is not itself the problem — /home is a symlink on plenty of real
          # hosts, and /var is one on macOS — the problem is an ancestor an
          # unprivileged user can write. Resolving first means we validate the
          # directories that actually exist, and an attacker-controlled symlink
          # resolves to somewhere whose ancestors fail the ownership test.
          __parent=$(cd "$(dirname "$h")" 2>/dev/null && pwd -P)
          if [ -z "$__parent" ]; then
            echo "portside: $(dirname "$h") does not exist; create the home yourself" >&2
            exit 1
          fi
          h="$__parent/$(basename "$h")"
          __a=$__parent
          while : ; do
            if [ ! -d "$__a" ]; then
              echo "portside: $__a is not a plain directory; refusing to create $h" >&2
              exit 1
            fi
            if [ -z "$(find "$__a" -maxdepth 0 -user root ! -perm -0020 ! -perm -0002 2>/dev/null)" ]; then
              echo "portside: $__a is not root-owned and unwritable by others; refusing to create $h — create the home yourself" >&2
              exit 1
            fi
            [ "$__a" = "/" ] && break
            __b=$(dirname "$__a")
            [ "$__b" = "$__a" ] && break
            __a=$__b
          done
          # No -p: every ancestor was just verified to exist, so this creates
          # exactly one component and fails if anything raced it into being.
          mkdir "$h" || exit 1
          chown "$u:" "$h" 2>/dev/null || chown "$u" "$h" 2>/dev/null
        elif [ -z "$(find "$h" -maxdepth 0 -user "$u" 2>/dev/null)" ]; then
          echo "portside: $h is not owned by $u; refusing" >&2
          exit 1
        fi
        if [ -h "$h/.ssh" ]; then
          echo "portside: $h/.ssh is a symbolic link; refusing" >&2
          exit 1
        fi
        # Ownership compared against the ACCOUNT, never with `-O`. `-O` asks
        # whether the *effective* uid owns it, which under root is true exactly
        # when the directory is root-owned — so an earlier version of this guard
        # exempted the one case it claimed to refuse.
        if [ -d "$h/.ssh" ] && [ -z "$(find "$h/.ssh" -maxdepth 0 -user "$u" 2>/dev/null)" ]; then
          echo "portside: $h/.ssh is not owned by $u; fix its ownership first" >&2
          exit 1
        fi
        __pi=\(ShellQuoting.quote(inner))
        # Drop to the account for everything that touches its files. sudo never
        # prompts when the caller is already root, and -n keeps it that way.
        sudo -n -u "$u" /bin/sh -c "$(printf %s "$__pi" | base64 -d 2>/dev/null \
          || printf %s "$__pi" | base64 -D 2>/dev/null)" portside "$h"
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
        guard let account = account?.trimmingCharacters(in: .whitespaces),
              !account.isEmpty else {
            return remoteScript(for: key, nonce: nonce)
        }
        // Root, not `-u account` — see `remoteScript`. The script resolves the
        // target's home from passwd and chowns what it creates.
        let script = remoteScript(for: key, nonce: nonce, account: account)
        let encoded = Data(script.utf8).base64EncodedString()
        return "__pk=\(ShellQuoting.quote(encoded)); "
            + "sudo -S -p '' sh -c "
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
