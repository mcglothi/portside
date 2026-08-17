import Foundation

/// What happened when one host was asked to prove it accepts the new key.
enum KeyVerifyOutcome: Equatable {
    /// The host authenticated **this key**, proved by fingerprint.
    case verified
    /// Reached the host; it would not authenticate this key.
    case rejected(String)
    /// Could not find out. Never treated as a pass.
    case failed(String)
    case skipped(String)

    /// The only state that permits a retirement. Deliberately not derived from
    /// "didn't fail" — an unknown result is not a proof, and this is the
    /// property the whole feature rests on.
    var provesKeyWorks: Bool { self == .verified }

    var label: String {
        switch self {
        case .verified: return "New key works"
        case .rejected(let why): return "Key not accepted — \(why)"
        case .failed(let why): return "Could not verify — \(why)"
        case .skipped(let why): return "Skipped — \(why)"
        }
    }
}

/// What happened when one host was asked to drop the old key.
enum KeyRetireOutcome: Equatable {
    /// The old key was removed. Carries how many lines matched, because more
    /// than one is worth seeing.
    case removed(Int)
    /// The old key was not in `authorized_keys`; nothing was rewritten.
    case notPresent
    /// **The host refused**, because its own check for the new key failed.
    /// Distinct from `failed` on purpose: this is the safety rule working, and
    /// it means the host is untouched.
    case refused(String)
    case failed(String)
    case skipped(String)

    var isSuccess: Bool {
        switch self {
        case .removed, .notPresent: return true
        case .refused, .failed, .skipped: return false
        }
    }

    var label: String {
        switch self {
        case .removed(let n): return n == 1 ? "Old key removed" : "Old key removed (\(n) entries)"
        case .notPresent: return "Didn’t have the old key"
        case .refused(let why): return "Refused — \(why)"
        case .failed(let why): return "Failed — \(why)"
        case .skipped(let why): return "Skipped — \(why)"
        }
    }
}

struct KeyVerifyResult: Identifiable, Equatable {
    let entryID: UUID
    let hostName: String
    let outcome: KeyVerifyOutcome
    var id: UUID { entryID }
}

struct KeyRetireResult: Identifiable, Equatable {
    let entryID: UUID
    let hostName: String
    let outcome: KeyRetireOutcome
    var id: UUID { entryID }
}

/// Whether the new key can be used from *this Mac* at all.
///
/// Checked once, before any host is contacted. A passphrase-protected key that
/// isn't loaded in the agent fails every verify identically, and forty hosts
/// reporting "key not accepted" for a local problem is the most misleading
/// output this feature could produce.
enum PrivateKeyReadiness: Equatable {
    case ready
    /// No private key beside the `.pub`.
    case missing(String)
    /// Encrypted and not in the agent, so nothing here can use it.
    case locked(String)

    var isReady: Bool { self == .ready }

    var problem: String? {
        switch self {
        case .ready: return nil
        case .missing(let why), .locked(let why): return why
        }
    }
}

/// The second and third phases of a key rotation: **prove** the new key works
/// on a host, then **retire** the old one from it.
///
/// The first phase is `KeyDistributor` unchanged — rotation's "add" step *is* a
/// key push, which is why rotation deliberately waited until distribution had
/// real-fleet mileage rather than shipping alongside it.
///
/// ## The one rule
///
/// > The old key is never removed from a host that has not **just** proved the
/// > new one works.
///
/// "The push reported success" is not proof: it says a line was appended, not
/// that sshd will authenticate with it. `StrictModes` rejecting a home
/// directory's permissions, an `AuthorizedKeysFile` pointing somewhere else, a
/// `Match` block restricting key types — each leaves a correct-looking
/// `authorized_keys` that authenticates nothing. So the proof is a real login.
///
/// ## Three ways a verify can pass while proving nothing
///
/// All three were measured against real hosts, and each one, unnoticed, would
/// have turned this feature into a way to lock yourself out of a fleet.
///
/// 1. **Connection multiplexing.** Portside opens a `ControlMaster` for
///    interactive sessions, and a second connection over that socket
///    authenticates *nothing at all* — `ssh -v` through a live master prints
///    `mux_client_request_session` and not one `Server accepts key` line. So
///    verifying a host you happen to have a session open to would pass
///    unconditionally. Hence `ControlPath=none`, not merely `ControlMaster=no`.
/// 2. **The entry's own identity file.** `SessionEntry.sshArgs` includes the
///    host's configured `-i`, which is usually the *old* key. `IdentitiesOnly`
///    permits every identity that was explicitly configured, so the old key
///    would be offered too and could be the one that succeeds. Hence
///    `sshTargetArgs`, which carries the destination and nothing else.
/// 3. **`~/.ssh/config`.** `IdentitiesOnly=yes` does not mean "only the `-i` I
///    passed" — the man page says the configured identity files count as
///    configured, and an aliased host's `IdentityFile` is duly offered and
///    reported as `explicit`. There is no option that suppresses it while still
///    resolving the alias, and every host in the maintainer's own library is
///    aliased, so this is the common case rather than the corner.
///
/// (3) is why the assertion is not "the connection succeeded" but **"the server
/// accepted a key with this fingerprint"**, read from ssh's own verbose output.
/// That is a direct statement about which key authenticated, so it holds no
/// matter how many other identities were offered alongside — and it fails
/// closed under (1), where the line is absent entirely.
enum KeyRotator {

    static let verifyMarker = "PORTSIDE-VERIFY:"
    static let retireMarker = "PORTSIDE-RETIRE:"

    /// ssh prints `Server accepts key: <path> <ALGO> SHA256:<fp> <source>` at
    /// `-v`. The fingerprint on *that* line is the proof.
    static let acceptedKeyPrefix = "Server accepts key:"

    /// Every `SHA256:…` fingerprint ssh reported as **accepted**.
    ///
    /// ## Why this is a parser and not two `contains` calls
    ///
    /// The first version asked whether some line contained both the prefix and
    /// the fingerprint. Against a real host that reported an **uninstalled key
    /// as verified** — the exact vacuous pass the whole design is built to
    /// prevent — for a reason that has nothing to do with ssh:
    ///
    /// **`\r\n` is a single Swift `Character`.** It is one extended grapheme
    /// cluster, so `split(separator: "\n")` finds *no* separator in CRLF text
    /// and hands back the entire blob as one line. ssh's verbose logger writes
    /// CRLF, so the per-line check quietly became a whole-output check — and the
    /// output contains both strings: the prefix on the accepted key's line, and
    /// the *rejected* key's fingerprint on its own `Offering public key:` line.
    ///
    /// So the split is on `isNewline` (which does recognise the `\r\n` cluster),
    /// and the fingerprint is read as a **field of the accepted line** rather
    /// than sought anywhere within it.
    static func acceptedFingerprints(in verboseOutput: String) -> [String] {
        fingerprints(in: verboseOutput, onLinesContaining: acceptedKeyPrefix)
    }

    /// Every fingerprint ssh reported **offering**.
    ///
    /// Offered-but-not-accepted is the server saying no to that specific key,
    /// which is a more precise answer than "the connection failed" — and it
    /// stays true on a host where some *other* identity then succeeds, which is
    /// the normal case for an aliased host.
    static func offeredFingerprints(in verboseOutput: String) -> [String] {
        fingerprints(in: verboseOutput, onLinesContaining: offeredKeyPrefix)
    }

    static let offeredKeyPrefix = "Offering public key:"

    private static func fingerprints(in verboseOutput: String,
                                     onLinesContaining prefix: String) -> [String] {
        verboseOutput
            .split(whereSeparator: \.isNewline)
            .filter { $0.contains(prefix) }
            .compactMap { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }
                    .map(String.init)
            }
    }

    // MARK: - The key itself

    /// The private key beside a `.pub`, which is the convention `ssh-keygen`
    /// creates and `ssh -i` expects.
    static func privateKeyPath(for key: PublicKey) -> String {
        key.path.hasSuffix(".pub") ? String(key.path.dropLast(4)) : key.path
    }

    /// Whether this Mac can actually authenticate with the new key.
    ///
    /// `ssh-keygen -y` derives the public key from the private one and succeeds
    /// only when it can read it — so it answers "is this usable without a
    /// passphrase" without touching the network. When it fails the key may still
    /// be usable via the agent, which is checked by fingerprint rather than by
    /// path, because `ssh-add -l` lists whatever comment the key was added under
    /// and paths do not have to match.
    static func readiness(
        of key: PublicKey,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        runner: KeyDistributor.Runner = KeyDistributor.defaultRunner
    ) async -> PrivateKeyReadiness {
        let path = privateKeyPath(for: key)
        guard fileExists(path) else {
            return .missing("no private key at \(path) — rotation has to log in with the new key, "
                            + "so the matching private key must be on this Mac")
        }
        if let result = try? await runner("/usr/bin/ssh-keygen", ["-y", "-f", path], nil, ""),
           result.status == 0 {
            return .ready
        }
        // Encrypted, or unreadable. The agent is the remaining way to use it.
        if !key.fingerprint.isEmpty,
           let listed = try? await runner("/usr/bin/ssh-add", ["-l"], nil, ""),
           listed.out.contains(key.fingerprint) {
            return .ready
        }
        return .locked("\((path as NSString).lastPathComponent) needs a passphrase and is not "
                       + "loaded in the agent — run `ssh-add \(path)` first, or every host will "
                       + "report the key as rejected when the problem is local")
    }

    // MARK: - Verify

    /// ssh arguments that prove one host accepts `key`, and can prove nothing
    /// else.
    ///
    /// Every option here is load-bearing; see the type's documentation for the
    /// three ways this passes vacuously without them.
    static func verifyArguments(
        for entry: SessionEntry, privateKeyPath: String,
        defaults: ConnectionDefaults = ConnectionDefaults(),
        account: String? = nil
    ) -> [String] {
        var args = [
            // Verbose, because the answer this function needs — which key the
            // server accepted — exists nowhere else.
            "-v",
            // Key-only, and never a prompt. A verify that fell back to a
            // password would report the *password* working.
            "-o", "PreferredAuthentications=publickey",
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "IdentitiesOnly=yes",
            "-i", privateKeyPath,
            // Not merely ControlMaster=no: riding an existing master skips
            // authentication altogether.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ConnectTimeout=15",
        ]
        if defaults.autoAcceptNewHostKeys ?? false {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        // Destination only — deliberately not `entry.sshArgs`, which would
        // offer the old key as well.
        args += entry.sshTargetArgs(loggingInAs: account)
        return args
    }

    /// The remote command for a verify: prove a session really ran, cheaply.
    ///
    /// The fingerprint check establishes which key authenticated; this
    /// establishes that the connection got as far as running something, so a
    /// host that authenticates and then dies in its login shell is not counted
    /// as ready to lose its old key.
    static func verifyCommand(nonce: String) -> String {
        "printf '%s%s ok\\n' \(ShellQuoting.quote(verifyMarker)) \(ShellQuoting.quote(nonce))"
    }

    /// Reads one completed verify run.
    ///
    /// Requires **both** proofs: the marker (a session ran) and the fingerprint
    /// on ssh's `Server accepts key` line (that key authenticated). Missing
    /// either is a failure, never a pass.
    static func verifyOutcome(
        status: Int32, out: String, err: String, nonce: String, fingerprint: String
    ) -> KeyVerifyOutcome {
        guard !fingerprint.isEmpty else {
            return .failed("the new key has no fingerprint, so there is no way to tell which "
                           + "key a host accepted")
        }
        let acceptedThisKey = acceptedFingerprints(in: err).contains(fingerprint)
        let offeredThisKey = offeredFingerprints(in: err).contains(fingerprint)
        let ranSomething = out.contains("\(verifyMarker)\(nonce) ok")

        if acceptedThisKey && ranSomething { return .verified }

        if acceptedThisKey {
            return .failed("the host accepted the key but the session did not run — "
                           + KeyDistributor.failureReason(status: status, err: err))
        }

        // Offered and not accepted is a direct statement by the server about
        // *this* key, and stays true whether or not some other key then got in —
        // which is the normal shape on an aliased host, where `~/.ssh/config`
        // supplies a second identity that `IdentitiesOnly` still permits.
        if offeredThisKey {
            return .rejected("the host would not authenticate this key")
        }

        let lower = err.lowercased()
        if lower.contains("permission denied") || lower.contains("no supported authentication") {
            return .rejected("the host would not authenticate this key")
        }

        // The key was never even put to the host. A session that ran anyway is
        // the vacuous pass this function exists to refuse — most likely a
        // multiplexed connection, which authenticates nothing at all.
        if ranSomething {
            return .failed("connected without ever offering the new key, so this proves "
                           + "nothing — most likely a multiplexed session")
        }
        return .failed(KeyDistributor.failureReason(status: status, err: err))
    }

    /// Proves one host accepts `key`. Never sends a password: a verify is
    /// key-only by definition.
    static func verify(
        key: PublicKey,
        on entry: SessionEntry,
        defaults: ConnectionDefaults = ConnectionDefaults(),
        account: String? = nil,
        runner: KeyDistributor.Runner = KeyDistributor.defaultRunner
    ) async -> KeyVerifyOutcome {
        let nonce = KeyDistributor.newNonce()
        let args = verifyArguments(for: entry, privateKeyPath: privateKeyPath(for: key),
                                   defaults: defaults, account: account)
            + [verifyCommand(nonce: nonce)]
        do {
            let result = try await runner("/usr/bin/ssh", args, nil, "")
            return verifyOutcome(status: result.status, out: result.out, err: result.err,
                                 nonce: nonce, fingerprint: key.fingerprint)
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Verifies every host in turn.
    ///
    /// Sequential for the same reason a push is: this runs against a whole
    /// fleet, and a problem should be visible on host one rather than
    /// simultaneously on all forty.
    static func verify(
        key: PublicKey,
        on entries: [SessionEntry],
        defaults: ConnectionDefaults = ConnectionDefaults(),
        account: String? = nil,
        runner: KeyDistributor.Runner = KeyDistributor.defaultRunner,
        progress: @MainActor (KeyVerifyResult) -> Void
    ) async -> [KeyVerifyResult] {
        var results: [KeyVerifyResult] = []
        for entry in entries {
            let outcome: KeyVerifyOutcome = Task.isCancelled
                ? .skipped("cancelled")
                : await verify(key: key, on: entry, defaults: defaults,
                               account: account, runner: runner)
            let result = KeyVerifyResult(entryID: entry.id, hostName: entry.name, outcome: outcome)
            results.append(result)
            await progress(result)
        }
        return results
    }

    // MARK: - Retire

    /// The shell that removes `oldKey` from a host's `authorized_keys`.
    ///
    /// ## The guard is on the host, not only in the UI
    ///
    /// The script refuses unless `newKey` is *active* in the very file it is
    /// about to rewrite. The app already refuses to offer retirement for a host
    /// that hasn't verified, so this is deliberate duplication: the UI check
    /// tests what this session believes, and the script tests what the file
    /// actually says at the moment of the rewrite. Only the second one is true
    /// where it matters, and it costs one `awk`.
    ///
    /// After rewriting it checks again, and **restores from the backup** if the
    /// new key somehow went missing. A rewrite that loses both keys is the one
    /// outcome that ends in a console visit, so it is worth handling rather than
    /// reporting.
    ///
    /// ## Differences from the append path, and why
    ///
    /// - **A failed backup aborts.** `KeyDistributor` lets `cp` fail quietly,
    ///   which is survivable when the only change is an append. Here the next
    ///   step destroys data, so no backup means no rewrite.
    /// - **`cat` into the original, never `mv`.** A rename would replace the
    ///   inode and hand the file this script's ownership and permissions;
    ///   writing through the existing file keeps all three — the same reason
    ///   `ShellIntegrationSnippet.repairCommand` does it, and the reason a
    ///   symlinked `authorized_keys` is followed rather than replaced.
    /// - **Comment lines are preserved exactly.** A commented-out copy of the
    ///   old key grants nothing, and someone's annotations are not ours to
    ///   delete. This matches the append path, which likewise does not count a
    ///   commented entry as installed.
    static func retireScript(removing oldKey: PublicKey, keeping newKey: PublicKey,
                             nonce: String = "", account: String? = nil) -> String {
        let old = ShellQuoting.quote(oldKey.blob)
        let new = ShellQuoting.quote(newKey.blob)
        let backup = "\"$f\(KeyDistributor.backupSuffix)\""
        let temp = "\"$f.portside-rewrite\""
        let target = account?.trimmingCharacters(in: .whitespaces) ?? ""

        let locate: String
        if target.isEmpty {
            locate = #"h="$HOME""#
        } else {
            locate = """
            u=\(ShellQuoting.quote(target))
            h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
            [ -n "$h" ] || h=$(awk -F: -v u="$u" '$1 == u {print $6}' /etc/passwd 2>/dev/null)
            if [ -z "$h" ]; then echo "portside: unknown user $u" >&2; exit 1; fi
            """
        }
        let claim = target.isEmpty
            ? ""
            : #"chown "$u:" "$1" 2>/dev/null || chown "$u" "$1" 2>/dev/null"#
        let ownFunction = target.isEmpty ? "own() { :; }" : "own() { \(claim); }"

        // Active (non-comment) presence of a blob, field by field — the same
        // test the append path uses, for the same reasons.
        func present(_ blob: String) -> String {
            "awk -v b=\(blob) '/^[[:space:]]*#/ {next} "
                + "{for (i = 1; i <= NF; i++) if ($i == b) {found = 1; exit}} END {exit !found}' \"$f\""
        }

        return """
        umask 077
        \(locate)
        \(ownFunction)
        d="$h/.ssh"; f="$d/authorized_keys"
        if [ ! -f "$f" ]; then printf '%s%s absent 0\\n' '\(retireMarker)' '\(nonce)'; exit 0; fi
        if ! \(present(new)); then
          echo "portside: the new key is not active in $f; refusing to remove the old one" >&2
          exit 3
        fi
        n=$(awk -v b=\(old) '/^[[:space:]]*#/ {next} {for (i = 1; i <= NF; i++) if ($i == b) {c++; next}} END {print c+0}' "$f")
        if [ "$n" -eq 0 ]; then printf '%s%s absent 0\\n' '\(retireMarker)' '\(nonce)'; exit 0; fi
        cp "$f" \(backup) || { echo "portside: could not back up $f; nothing was changed" >&2; exit 1; }
        own \(backup)
        awk -v b=\(old) '/^[[:space:]]*#/ {print; next} {for (i = 1; i <= NF; i++) if ($i == b) next} {print}' "$f" > \(temp) || exit 1
        cat \(temp) > "$f" || exit 1
        rm -f \(temp)
        if ! \(present(new)); then
          cat \(backup) > "$f" 2>/dev/null
          echo "portside: the rewrite lost the new key, so $f was restored from the backup" >&2
          exit 4
        fi
        printf '%s%s removed %s\\n' '\(retireMarker)' '\(nonce)' "$n"
        """
    }

    /// The retire script, wrapped in `sudo` when it is aimed at another account.
    /// Base64 for the reason `KeyDistributor.remoteCommand` explains: the script
    /// carries single quotes of its own.
    static func retireCommand(removing oldKey: PublicKey, keeping newKey: PublicKey,
                              nonce: String, account: String? = nil) -> String {
        guard let account = account?.trimmingCharacters(in: .whitespaces),
              !account.isEmpty else {
            return retireScript(removing: oldKey, keeping: newKey, nonce: nonce)
        }
        let script = retireScript(removing: oldKey, keeping: newKey,
                                  nonce: nonce, account: account)
        let encoded = Data(script.utf8).base64EncodedString()
        return "__pk=\(ShellQuoting.quote(encoded)); "
            + "sudo -S -p '' sh -c "
            + "\"$(printf %s \"$__pk\" | base64 -d 2>/dev/null "
            + "|| printf %s \"$__pk\" | base64 -D 2>/dev/null)\""
    }

    static func retireOutcome(status: Int32, out: String, err: String,
                              nonce: String = "") -> KeyRetireOutcome {
        let prefix = "\(retireMarker)\(nonce) "
        if let line = out.split(whereSeparator: \.isNewline).first(where: { $0.contains(prefix) }) {
            let fields = line.components(separatedBy: prefix).last?
                .split(separator: " ").map(String.init) ?? []
            if fields.first == "removed", let count = Int(fields.dropFirst().first ?? "") {
                return .removed(count)
            }
            if fields.first == "absent" { return .notPresent }
        }
        // The host's own guard, and the self-repair, are reported in their own
        // words — a bare exit code here would hide the single most important
        // thing this script can tell you.
        let reasons = err.split(whereSeparator: \.isNewline).map(String.init)
        if let refusal = reasons.first(where: { $0.contains("refusing to remove the old one") }) {
            return .refused(Self.tidy(refusal))
        }
        if let restored = reasons.first(where: { $0.contains("restored from the backup") }) {
            return .failed(Self.tidy(restored))
        }
        if let noBackup = reasons.first(where: { $0.contains("could not back up") }) {
            return .failed(Self.tidy(noBackup))
        }
        return .failed(KeyDistributor.failureReason(status: status, err: err))
    }

    private static func tidy(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("portside: ") { text = String(text.dropFirst("portside: ".count)) }
        return text
    }

    /// Removes `oldKey` from one host. Never retries, and never runs against a
    /// host the caller has not established a verify for — that gate lives in
    /// `KeyRotation`, and the script checks the file itself as well.
    static func retire(
        oldKey: PublicKey,
        keeping newKey: PublicKey,
        on entry: SessionEntry,
        password: String?,
        defaults: ConnectionDefaults = ConnectionDefaults(),
        account: String? = nil,
        runner: KeyDistributor.Runner = KeyDistributor.defaultRunner
    ) async -> KeyRetireOutcome {
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

        let nonce = KeyDistributor.newNonce()
        let args = KeyDistributor.sshArguments(for: entry, hasPassword: environment != nil,
                                               defaults: defaults)
            + [retireCommand(removing: oldKey, keeping: newKey, nonce: nonce, account: account)]
        let stdin = KeyDistributor.requiresSudo(account: account) && !(password ?? "").isEmpty
            ? (password ?? "") + "\n"
            : ""
        do {
            let result = try await runner("/usr/bin/ssh", args, environment, stdin)
            return retireOutcome(status: result.status, out: result.out, err: result.err,
                                 nonce: nonce)
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Retires the old key from every host in turn, sequentially.
    static func retire(
        oldKey: PublicKey,
        keeping newKey: PublicKey,
        on entries: [SessionEntry],
        password: @Sendable (SessionEntry) -> String?,
        defaults: ConnectionDefaults = ConnectionDefaults(),
        account: String? = nil,
        runner: KeyDistributor.Runner = KeyDistributor.defaultRunner,
        progress: @MainActor (KeyRetireResult) -> Void
    ) async -> [KeyRetireResult] {
        var results: [KeyRetireResult] = []
        for entry in entries {
            let outcome: KeyRetireOutcome = Task.isCancelled
                ? .skipped("cancelled")
                : await retire(oldKey: oldKey, keeping: newKey, on: entry,
                               password: password(entry), defaults: defaults,
                               account: account, runner: runner)
            let result = KeyRetireResult(entryID: entry.id, hostName: entry.name, outcome: outcome)
            results.append(result)
            await progress(result)
        }
        return results
    }
}
