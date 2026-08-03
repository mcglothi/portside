import Foundation
import Security
import Darwin

/// Per-session passwords, stored in the macOS login Keychain keyed by the
/// session's UUID (plus one fixed key for the app-wide default password —
/// see `defaultAccount`). Passwords never touch the JSON library.
enum CredentialStore {
    private static let service = "net.timmcg.portside.ssh"
    /// Keychain "account" for the single app-wide default password, alongside
    /// the per-host entries (which use the host's UUID string as account).
    private static let defaultAccount = "net.timmcg.portside.default-password"

    @discardableResult
    static func setPassword(_ password: String, for id: UUID) -> Bool {
        set(password, account: id.uuidString)
    }

    static func password(for id: UUID) -> String? {
        get(account: id.uuidString)
    }

    static func deletePassword(for id: UUID) {
        delete(account: id.uuidString)
    }

    @discardableResult
    static func setDefaultPassword(_ password: String) -> Bool {
        set(password, account: defaultAccount)
    }

    static func defaultPassword() -> String? {
        get(account: defaultAccount)
    }

    static func deleteDefaultPassword() {
        delete(account: defaultAccount)
    }

    /// Prefixed distinctly from per-host UUIDs and `defaultAccount` so there's
    /// no possibility of collision.
    private static func profileAccount(_ id: UUID) -> String { "profile-\(id.uuidString)" }

    @discardableResult
    static func setProfilePassword(_ password: String, for id: UUID) -> Bool {
        set(password, account: profileAccount(id))
    }

    static func profilePassword(for id: UUID) -> String? {
        get(account: profileAccount(id))
    }

    static func deleteProfilePassword(for id: UUID) {
        delete(account: profileAccount(id))
    }

    /// Removes per-host passwords whose host is no longer in the library.
    ///
    /// Deleting a host defers its Keychain removal until the delete can no
    /// longer be undone (see `DeletedItemRing`). A crash or force-quit inside
    /// that window skips the removal, leaving a password behind for a host that
    /// no longer exists — the same shape of leak `AskpassInjector.purgeStale
    /// Directories` cleans up, and handled the same way: sweep at launch.
    ///
    /// Only touches accounts that are a bare UUID. The app-wide default
    /// password and the `profile-` entries have their own lifetimes and are not
    /// this function's business.
    ///
    /// **`live` must be the complete host list of the real library.** Called
    /// with a partial or wrong one — a store that failed to decode, or a dev
    /// build pointed at a throwaway library — this deletes the passwords for
    /// every host it can't see. `SessionStore` guards both cases; anything else
    /// calling this needs to as well.
    static func purgeOrphanedPasswords(keeping live: Set<UUID>) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account),   // skips default + profile- accounts
                  !live.contains(id) else { continue }
            NSLog("Portside: removing orphaned Keychain password for \(account)")
            delete(account: account)
        }
    }

    /// Adds or updates the item for `account`. Tries an add first (the
    /// common case) and falls back to an update on a duplicate — more
    /// reliable than a preceding blind delete-then-add, which silently loses
    /// the new value if the delete fails (e.g. an item left behind under a
    /// stale ACL from a previous code signature) and the add then also fails
    /// as a duplicate. Returns whether the value actually ended up saved, so
    /// callers can surface a failure instead of assuming success.
    private static func set(_ password: String, account: String) -> Bool {
        guard !password.isEmpty, let data = password.data(using: .utf8) else {
            delete(account: account)
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let addQuery = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]) { _, new in new }
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if status != errSecSuccess {
            NSLog("Portside: Keychain save failed for account \(account): OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    private static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Builds the environment that makes `ssh` auto-supply a saved password.
///
/// `ssh` never reads a password from stdin — it opens /dev/tty. Setting
/// `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4+) makes it invoke an askpass
/// helper even with a PTY attached. The helper just prints the contents of a
/// 0600 file we point it at, so the secret never appears in the process's
/// environment or argv.
enum AskpassInjector {
    /// The env additions plus two teardown stages: `expireSecret` shreds just
    /// the password file (safe to run early — the helper script survives so
    /// late interactive prompts still get the dialog), and `cleanup` removes
    /// the whole per-connection dir once ssh has exited.
    static func environment(for password: String)
        -> (env: [String], expireSecret: () -> Void, cleanup: () -> Void)? {
        guard !password.isEmpty else { return nil }
        do {
            let dir = try makePrivateDir()
            let helper = try installHelper(in: dir)
            let secretFile = dir.appendingPathComponent("pw-\(UUID().uuidString)")
            try writeSecret(password + "\n", to: secretFile)

            let env = [
                "SSH_ASKPASS=\(helper.path)",
                "SSH_ASKPASS_REQUIRE=force",
                "PORTSIDE_ASKPASS_FILE=\(secretFile.path)",
                "PORTSIDE_ASKPASS_STATE_DIR=\(dir.path)",
                "DISPLAY=:0",   // harmless; older ssh required it for askpass
            ]
            let expireSecret = { _ = try? FileManager.default.removeItem(at: secretFile) }
            let cleanup = { _ = try? FileManager.default.removeItem(at: dir) }
            return (env, expireSecret, cleanup)
        } catch {
            NSLog("Portside: askpass setup failed: \(error)")
            return nil
        }
    }

    private static func makePrivateDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    static let directoryPrefix = "portside-askpass-"

    /// Removes any `portside-askpass-*` directory left over from a previous
    /// run — normally `cleanup` (or the 30-second expiry) removes these, but
    /// a crash or force-quit skips both, leaving a password sitting in a
    /// 0600 file until the OS eventually reclaims temp space on its own
    /// schedule. Call at launch, mirroring `RemoteFileEditor.purgeStaleCopies`.
    nonisolated static func purgeStaleDirectories() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        guard let contents = try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
        else { return }
        for url in contents where url.lastPathComponent.hasPrefix(directoryPrefix) {
            try? fm.removeItem(at: url)
        }
    }

    private static func installHelper(in dir: URL) throws -> URL {
        let helper = dir.appendingPathComponent("askpass.sh")
        try helperScript.write(to: helper, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }

    private static func writeSecret(_ secret: String, to url: URL) throws {
        guard let data = secret.data(using: .utf8) else { return }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var written = 0
                while written < data.count {
                    let result = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
                    if result < 0 {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    if result == 0 {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                    }
                    written += result
                }
            }
            close(fd)
        } catch {
            close(fd)
            _ = try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static let helperScript = """
#!/bin/sh
prompt="${1:-}"
state_dir="${PORTSIDE_ASKPASS_STATE_DIR:-$(dirname "$PORTSIDE_ASKPASS_FILE")}"
attempt_file="$state_dir/password-attempted"

# The saved secret answers the first password/passphrase prompt, exactly
# once — a second prompt means the server rejected it, and blind retries
# just burn auth attempts (fail2ban). Capped or already-expired secrets
# fall through to the dialog so the user can type the right one.
if printf '%s\\n' "$prompt" | grep -Eiq '(^|[^[:alpha:]])(password|passphrase)([^[:alpha:]]|$)'; then
    if [ ! -e "$attempt_file" ] && [ -r "$PORTSIDE_ASKPASS_FILE" ]; then
        : > "$attempt_file" && cat "$PORTSIDE_ASKPASS_FILE" && exit 0
    fi
fi

# Interactive fallback: MFA codes, host-key confirmations, rejected or
# expired passwords. Input is hidden unless this is a yes/no confirmation
# (the prompt text rides an env var to keep it out of AppleScript source).
hidden="with hidden answer"
case "$prompt" in *yes/no*) hidden="" ;; esac
export PORTSIDE_ASKPASS_PROMPT="$prompt"
answer="$(osascript -e 'set promptText to system attribute "PORTSIDE_ASKPASS_PROMPT"' -e "text returned of (display dialog promptText default answer \\"\\" with title \\"Portside SSH Prompt\\" buttons {\\"Cancel\\", \\"OK\\"} default button \\"OK\\" cancel button \\"Cancel\\" $hidden)" 2>/dev/null)" || exit 1
printf '%s\\n' "$answer"
"""
}
