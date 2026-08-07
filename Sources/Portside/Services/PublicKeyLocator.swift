import Foundation

/// Finds the public keys in `~/.ssh` and asks `ssh-keygen` to fingerprint them.
///
/// Deliberately only reads `.pub` files. `~/.ssh` holds private keys next to
/// public ones under near-identical names, and a locator that scanned
/// everything would eventually offer one for distribution. `PublicKey.parse`
/// rejects private key material as a second line of defence, but not being
/// handed it in the first place is the one that matters.
enum PublicKeyLocator {

    static func defaultDirectory() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
    }

    /// Public key files in `directory`, newest-looking names first.
    ///
    /// Sorted so the keys people actually use surface above the ones they have
    /// forgotten: ed25519 before rsa before everything else, then by name.
    static func discover(
        in directory: String = defaultDirectory(),
        fingerprinter: (String) async -> (fingerprint: String, bits: Int?)? = fingerprint
    ) async -> [PublicKey] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        var keys: [PublicKey] = []
        for name in names.sorted() where name.hasSuffix(".pub") {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            // A .pub file holds one key. Anything past the first key line is
            // not something to guess about, so only the first is offered.
            guard let firstLine = contents.split(separator: "\n").first else { continue }
            let measured = await fingerprinter(path)
            guard let key = PublicKey.parse(
                line: String(firstLine),
                path: path,
                fingerprint: measured?.fingerprint ?? "",
                bits: measured?.bits
            ) else { continue }
            keys.append(key)
        }
        return keys.sorted(by: preferred)
    }

    /// ed25519 first — the default OpenSSH generates and the one most likely to
    /// be the key someone means.
    static func preferred(_ a: PublicKey, _ b: PublicKey) -> Bool {
        let rank = { (key: PublicKey) -> Int in
            if key.algorithm.hasPrefix("sk-") { return 0 }
            if key.algorithm == "ssh-ed25519" { return 1 }
            if key.algorithm.hasPrefix("ecdsa-") { return 2 }
            if key.algorithm == "ssh-rsa" { return 3 }
            return 4
        }
        return rank(a) == rank(b) ? a.filename < b.filename : rank(a) < rank(b)
    }

    static func fingerprint(of path: String) async -> (fingerprint: String, bits: Int?)? {
        guard let result = try? await SFTPClient.runProcess(
            "/usr/bin/ssh-keygen", ["-l", "-f", path], stdin: ""
        ), result.status == 0 else { return nil }
        return PublicKey.parseFingerprint(result.out)
    }
}
