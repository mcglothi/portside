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
            .appendingPathComponent("portside-askpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return dir
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
