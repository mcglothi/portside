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
    /// The private key beside the `.pub` is a **different key**. Signing then
    /// fails after the server has already accepted the probe, which reads as
    /// the host rejecting the key when the fault is entirely local.
    case mismatched(String)

    var isReady: Bool { self == .ready }

    var problem: String? {
        switch self {
        case .ready: return nil
        case .missing(let why), .locked(let why), .mismatched(let why): return why
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

    /// The fingerprint of the key that **actually authenticated**, if one did.
    ///
    /// ## Why this reads the transcript in order
    ///
    /// `Server accepts key` does not mean the key authenticated. OpenSSH logs it
    /// from `input_userauth_pk_ok` — the reply to an *unsigned probe* — and only
    /// then signs and sends the real request. Signing can still fail, and ssh
    /// moves on to the next identity when it does.
    ///
    /// Measured against a fixture host, presenting one key's `.pub` beside
    /// another's private key:
    ///
    /// ```text
    /// Offering public key: …/mismatch ED25519 SHA256:ZK52…
    /// Server accepts key:  …/mismatch ED25519 SHA256:ZK52…
    /// identity_sign: private key …/mismatch contents do not match public
    /// Offering public key: …/id_testhost ED25519 SHA256:wr2F…
    /// Server accepts key:  …/id_testhost ED25519 SHA256:wr2F…
    /// Authenticated to 172.16.0.2 using "publickey".
    /// ```
    ///
    /// The command ran and exited 0. A check asking "was our fingerprint
    /// accepted anywhere" says yes, and is wrong: `ZK52` never authenticated
    /// anything. So the rule is positional — **the key that authenticated is
    /// the one on the last accept line before `Authenticated to`** — because any
    /// key accepted earlier had its signature rejected, or authentication would
    /// have finished there.
    ///
    /// ## Anchoring, not searching
    ///
    /// Lines are matched with `hasPrefix` after stripping ssh's `debugN: `
    /// prefix, never with `contains`. ssh logs the command it sends
    /// (`debug1: Sending command: …`), so a `contains` test can be satisfied by
    /// text we handed it. Measured: a remote printing a fake accept line to its
    /// own stderr never reaches the `-E` log at all, but the *command echo* does,
    /// and anchoring is what separates the two.
    static func authenticatingFingerprint(in verboseLog: String) -> String? {
        var lastAccepted: String?
        for raw in verboseLog.split(whereSeparator: \.isNewline) {
            let line = stripDebugPrefix(String(raw))
            if line.hasPrefix(acceptedKeyPrefix) {
                lastAccepted = fingerprint(in: line)
            } else if line.hasPrefix("Authenticated to ") {
                // Only a public key counts. Falling through to a password would
                // prove the password works, which is a different question.
                return line.contains("\"publickey\"") ? lastAccepted : nil
            }
        }
        return nil
    }

    /// Every fingerprint ssh reported *accepting*, in order.
    ///
    /// Not proof of authentication on its own — that is the whole point of
    /// `authenticatingFingerprint`. It is kept for one narrow question: was this
    /// key accepted at some point even though something else ultimately got in?
    /// Yes means the host trusts the key and the *signature* failed, which is a
    /// local fault; no means the host declined it.
    static func acceptedFingerprints(in verboseLog: String) -> [String] {
        verboseLog.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = stripDebugPrefix(String(raw))
            guard line.hasPrefix(acceptedKeyPrefix) else { return nil }
            return fingerprint(in: line)
        }
    }

    /// Fingerprints ssh reported **offering**, in order.
    ///
    /// Offered-and-not-authenticated is the server declining that specific key,
    /// which is a more precise answer than "the connection failed" — and it
    /// stays true when some *other* identity then succeeds, the normal shape on
    /// an aliased host.
    static func offeredFingerprints(in verboseLog: String) -> [String] {
        verboseLog.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = stripDebugPrefix(String(raw))
            guard line.hasPrefix(offeredKeyPrefix) else { return nil }
            return fingerprint(in: line)
        }
    }

    static let offeredKeyPrefix = "Offering public key:"

    /// `debug1: `, `debug2: `, … removed. Everything else is left alone.
    private static func stripDebugPrefix(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("debug") else { return trimmed }
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let level = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<colon]
        guard !level.isEmpty, level.allSatisfy(\.isNumber) else { return trimmed }
        return String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func fingerprint(in line: String) -> String? {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }
            .map(String.init)
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
            // **Exit status is not enough.** `ssh-keygen -y` succeeds whenever it
            // can read the private key, and says nothing about the `.pub` sitting
            // beside it. A stale or swapped `.pub` therefore passes, and the
            // failure surfaces much later and in the wrong place: the server
            // accepts the probe for the advertised key, signing fails because the
            // private key is a different one, and every host reports "key not
            // accepted" for a fault that is entirely local. Reproduced on a
            // fixture host before this check existed.
            let derived = PublicKey.parse(line: result.out, path: path, fingerprint: "", bits: nil)
            guard let derived else {
                return .mismatched("could not read a public key out of \(path)")
            }
            guard derived.identityFields == key.identityFields else {
                return .mismatched(
                    "\((path as NSString).lastPathComponent) is a different key from "
                    + "\(key.filename) — the private key and the .pub beside it do not match, so "
                    + "every host would report this key as rejected when the problem is here")
            }
            return .ready
        }
        // Encrypted, or unreadable. The agent is the remaining way to use it,
        // and it identifies keys by fingerprint rather than by path.
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
        logFile: String,
        defaults: ConnectionDefaults = ConnectionDefaults(),
        account: String? = nil
    ) -> [String] {
        var args = [
            // Verbose, because the answer this function needs — which key the
            // server accepted — exists nowhere else. `-E` alone logs at default
            // verbosity and does not include the authentication trace; the two
            // flags are only useful together.
            "-v",
            // **The transcript goes to a private file, not to stderr.** ssh's
            // stderr is shared with the remote host's, and a host can print a
            // convincing `Server accepts key` line of its own. Reading the
            // decision out of a channel the host can write to is not evidence.
            "-E", logFile,
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
    /// `transcript` is ssh's own `-E` log, which is a **different channel** from
    /// `err`. Both used to be the same pipe, and a host can print whatever it
    /// likes to its stderr — including a convincing `Server accepts key` line.
    /// Keeping them apart is what makes the transcript evidence rather than
    /// hearsay.
    ///
    /// Requires two independent proofs: the key that *authenticated* is ours,
    /// and a session actually ran. Missing either is a failure, never a pass.
    static func verifyOutcome(
        status: Int32, out: String, err: String, transcript: String,
        nonce: String, fingerprint: String
    ) -> KeyVerifyOutcome {
        guard !fingerprint.isEmpty else {
            return .failed("the new key has no fingerprint, so there is no way to tell which "
                           + "key a host accepted")
        }
        let authenticated = authenticatingFingerprint(in: transcript)
        let offeredOurs = offeredFingerprints(in: transcript).contains(fingerprint)
        let ranSomething = out.contains("\(verifyMarker)\(nonce) ok")

        if authenticated == fingerprint {
            guard ranSomething else {
                // The key works; the session is what failed — a nologin shell, a
                // ForceCommand, a full disk. Report the REMOTE's words, not the
                // transcript's: the transcript's first line is ssh's version
                // banner, which `failureReason` will happily return when nothing
                // in it looks like an error.
                // Only append a reason when the remote actually gave one.
                // `failureReason` falls back to describing the exit code, and
                // "the host rejected the change" is nonsense here — a verify
                // changes nothing.
                let remote = err.trimmingCharacters(in: .whitespacesAndNewlines)
                let why = remote.isEmpty ? "" : KeyDistributor.failureReason(status: status, err: err)
                return .failed("the host authenticated the key but the session did not run"
                               + (why.isEmpty ? "" : " — \(why)"))
            }
            return .verified
        }

        // Was this key accepted at *any* point, even though something else
        // ultimately authenticated? That distinguishes two very different
        // situations which look identical if you only ask "did it authenticate".
        let probeAccepted = acceptedFingerprints(in: transcript).contains(fingerprint)

        if probeAccepted {
            // The host DOES trust this key — it accepted the probe — and the
            // signature was still rejected. That is a local fault, not a host
            // one: the private key beside the `.pub` is a different key.
            // `readiness` catches this before any host is contacted; reaching
            // here means something changed underneath, so say which way round it
            // is rather than blaming the host.
            return .failed("the host accepted this key but the signature was rejected — the "
                           + "private key beside \(fingerprint) is a different key")
        }

        if offeredOurs {
            // Offered and never accepted is the server declining this specific
            // key: a definite negative, and the expected answer before the key
            // has been added. True whether or not some other identity then got
            // in, which is the normal shape on an aliased host.
            return .rejected("the host would not authenticate this key")
        }

        if let authenticated {
            // Something authenticated and this key was never even offered — so
            // nothing here speaks to it either way.
            return .failed("connected using a different key (\(authenticated)) without ever "
                           + "offering this one, so this proves nothing about \(fingerprint)")
        }

        let lower = transcript.lowercased() + " " + err.lowercased()
        if lower.contains("permission denied") || lower.contains("no supported authentication") {
            return .rejected("the host would not authenticate this key")
        }
        if ranSomething {
            // A session ran without this key ever being offered — most likely a
            // multiplexed connection, which authenticates nothing at all.
            return .failed("connected without ever offering the new key, so this proves "
                           + "nothing — most likely a multiplexed session")
        }
        return .failed(KeyDistributor.failureReason(status: status, err: transcript.isEmpty ? err : transcript))
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
        guard let log = makePrivateLogFile() else {
            return .failed("could not create a private file for ssh's transcript")
        }
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

        let args = verifyArguments(for: entry, privateKeyPath: privateKeyPath(for: key),
                                   logFile: log.path, defaults: defaults, account: account)
            + [verifyCommand(nonce: nonce)]
        do {
            let result = try await runner("/usr/bin/ssh", args, nil, "")
            let transcript = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return verifyOutcome(status: result.status, out: result.out, err: result.err,
                                 transcript: transcript, nonce: nonce,
                                 fingerprint: key.fingerprint)
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A 0700 directory holding the transcript, mirroring `CredentialStore`'s
    /// askpass handling. The transcript names hosts and key paths, so it is not
    /// something to leave in a world-readable temp file.
    static func makePrivateLogFile() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-verify-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        return dir.appendingPathComponent("ssh.log")
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
