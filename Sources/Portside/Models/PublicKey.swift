import Foundation

/// A public key found in `~/.ssh`, described well enough to be *shown to
/// someone before they push it to forty machines*.
///
/// The fingerprint is the point. A key file's name says nothing about which key
/// it holds — `id_rsa.pub` on two Macs is two different keys — so a
/// confirmation that names the file is not a confirmation at all. What a person
/// can actually check against a host's `authorized_keys`, or against what they
/// were sent, is the SHA256 fingerprint, and that is what `road-to-1.0.md`
/// means by showing it *before* rather than after.
struct PublicKey: Identifiable, Equatable, Hashable {
    /// Absolute path to the `.pub` file.
    let path: String
    /// The full single line as it will be appended to `authorized_keys`.
    let line: String
    /// `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`, …
    let algorithm: String
    /// The base64 blob. Identity lives here: the comment is decoration and the
    /// same key may appear under different comments on different hosts.
    let blob: String
    /// Trailing comment, usually `user@host`. Empty when the key has none.
    let comment: String
    /// `SHA256:…` as `ssh-keygen -l` prints it.
    let fingerprint: String
    /// Key size in bits, when `ssh-keygen` reported one.
    let bits: Int?

    var id: String { path }

    var filename: String { (path as NSString).lastPathComponent }

    /// What the picker shows: enough to tell two keys apart at a glance.
    var summary: String {
        var parts = [filename, shortAlgorithm]
        if let bits { parts.append("\(bits) bits") }
        return parts.joined(separator: " · ")
    }

    /// `ED25519` rather than `ssh-ed25519`; `ECDSA` rather than
    /// `ecdsa-sha2-nistp256`.
    var shortAlgorithm: String {
        if algorithm.hasPrefix("ssh-") {
            return String(algorithm.dropFirst(4)).uppercased()
        }
        if algorithm.hasPrefix("ecdsa-") { return "ECDSA" }
        if algorithm.hasPrefix("sk-") { return "SECURITY KEY" }
        return algorithm.uppercased()
    }

    /// The two fields that decide whether a host already trusts this key.
    ///
    /// Matching on the whole line would treat a comment edit as a different
    /// key and append a duplicate; matching on the blob alone would ignore the
    /// algorithm. `authorized_keys` authenticates on type + blob, so that pair
    /// is what an idempotency check has to compare.
    var identityFields: String { "\(algorithm) \(blob)" }

    /// Parses one line of a `.pub` file.
    ///
    /// Returns nil for anything that isn't a key line — blank lines, comments,
    /// and (deliberately) private keys, so pointing this at `~/.ssh` and
    /// reading everything can't turn a private key into something offered for
    /// distribution.
    static func parse(line raw: String, path: String, fingerprint: String, bits: Int?) -> PublicKey? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        guard !line.contains("PRIVATE KEY") else { return nil }

        // Split on any whitespace: `ssh-keygen` writes spaces, but a
        // hand-edited file may use tabs, and the remote `awk` check treats
        // both as separators — the two ends must agree on what a field is.
        let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true,
                                whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { return nil }
        let algorithm = String(fields[0])
        let blob = String(fields[1])

        // A public key line starts with its type. Anything else is a file we
        // were handed by mistake, and appending it would corrupt the remote
        // authorized_keys rather than fail cleanly.
        guard algorithm.hasPrefix("ssh-") || algorithm.hasPrefix("ecdsa-")
                || algorithm.hasPrefix("sk-") else { return nil }
        // **Certificates are not keys here.** An `id_ed25519-cert.pub` parses
        // like a key and appending one to `authorized_keys` is accepted
        // silently by sshd and grants nothing — certificates are trusted via
        // `TrustedUserCAKeys`, not by being listed. Offering one would install
        // a line, report success, and leave the user locked out wondering why.
        guard !algorithm.contains("-cert-") else { return nil }
        guard !blob.isEmpty, blob.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" })
        else { return nil }

        return PublicKey(
            path: path,
            line: line,
            algorithm: algorithm,
            blob: blob,
            comment: fields.count > 2 ? String(fields[2]) : "",
            fingerprint: fingerprint,
            bits: bits
        )
    }

    /// Reads the `SHA256:…` fingerprint and bit count out of `ssh-keygen -lf`.
    ///
    /// The output is `<bits> <fingerprint> <comment> (<ALGO>)`, where the
    /// comment may itself contain spaces — so this takes the first two fields
    /// positionally and leaves the rest alone rather than trying to split the
    /// whole line.
    static func parseFingerprint(_ output: String) -> (fingerprint: String, bits: Int?)? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        let fingerprint = String(fields[1])
        guard fingerprint.hasPrefix("SHA256:") || fingerprint.hasPrefix("MD5:") else { return nil }
        return (fingerprint, Int(fields[0]))
    }
}
