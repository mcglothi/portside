import AppKit
import CryptoKit
import Foundation

/// Gets XQuartz onto a Mac that has a host with X11 on and no X server.
///
/// Two routes, chosen by what's already there, and neither gives Portside any
/// privilege of its own:
/// - **Homebrew:** a local tab runs `brew install --cask xquartz`. The cask
///   asks for the admin password through sudo, in a real terminal, where the
///   person can see what's happening and Portside never touches it.
/// - **No Homebrew:** the official signed package from XQuartz's GitHub
///   releases, checked before anything opens it, then handed to Installer,
///   which asks for the password itself. Portside never installs Homebrew to
///   get here: that's a far bigger change than anyone asked for.
///
/// The package is only opened if every check passes: it matches the checksum
/// published beside it, `pkgutil` reports a Developer ID Installer signature
/// from XQuartz's team, and Gatekeeper accepts it as notarized from that
/// same team. Anything else, including being offline, opens xquartz.org in
/// the browser instead and says why.
enum XQuartzInstaller {
    /// XQuartz's Developer ID team ("Apple Inc. - XQuartz"), as read from
    /// the signed 2.8.6 package. A package signed by anyone else is refused.
    static let teamID = "NA574AWV7E"
    static let latestRelease = URL(string: "https://api.github.com/repos/XQuartz/XQuartz/releases/latest")!
    static let website = URL(string: "https://www.xquartz.org")!

    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func brew(exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        brewPaths.first(where: exists)
    }

    /// What the Homebrew route types, run by the person's login shell so
    /// brew finds its PATH. Says how it went before the tab ends.
    static func brewCommand(brew: String) -> String {
        "'\(brew)' install --cask xquartz; s=$?; echo; "
            + "if [ $s -eq 0 ]; then echo 'XQuartz is installed. Back in Portside, click Start XQuartz.'; "
            + "else echo \"brew stopped with status $s.\"; fi"
    }

    // MARK: Checking the package

    /// Whether `pkgutil --check-signature` output shows a distribution
    /// signature whose leaf certificate is a Developer ID Installer from
    /// XQuartz's team.
    static func signatureIsXQuartz(pkgutil output: String) -> Bool {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("Status: signed by a developer certificate issued by Apple for distribution"),
              let leaf = lines.first(where: { $0.hasPrefix("1. ") }) else { return false }
        return leaf.hasPrefix("1. Developer ID Installer: ") && leaf.hasSuffix("(\(teamID))")
    }

    /// Whether `spctl -a -vv -t install` accepted the package as notarized
    /// and from XQuartz's team.
    static func gatekeeperAccepts(spctl output: String, status: Int32) -> Bool {
        guard status == 0 else { return false }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.contains { $0.hasSuffix(": accepted") }
            && lines.contains("source=Notarized Developer ID")
            && lines.contains { $0.hasPrefix("origin=Developer ID Installer: ") && $0.hasSuffix("(\(teamID))") }
    }

    /// The package asset and its published SHA-256 from a GitHub release.
    struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
        }
        var tag_name: String
        var assets: [Asset]

        var package: Asset? {
            assets.first { $0.name.hasPrefix("XQuartz-") && $0.name.hasSuffix(".pkg") }
        }
        var checksum: Asset? {
            guard let package else { return nil }
            return assets.first { $0.name == package.name + ".sha256sum" }
        }
    }

    /// The hash from a `.sha256sum` file — either `<hash>  <file>` or
    /// OpenSSL's `SHA256(<file>)= <hash>`.
    static func publishedHash(_ text: String) -> String? {
        let candidates = text.split(whereSeparator: { " \n=()".contains($0) }).map(String.init)
        return candidates.first { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }?.lowercased()
    }

    // MARK: Running it

    enum Outcome: Equatable {
        /// Installer is open; the person finishes it there.
        case openedInstaller(version: String)
        /// Couldn't get or trust the package; the website is open instead.
        case openedWebsite(reason: String)
    }

    /// Downloads, checks and opens the package. `progress` is told what's
    /// happening, for the editor to show.
    @MainActor
    static func installPackage(progress: @escaping (String) -> Void) async -> Outcome {
        do {
            progress("Finding the latest XQuartz…")
            let (data, _) = try await URLSession.shared.data(from: latestRelease)
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let package = release.package, let checksum = release.checksum else {
                return fallBack("the latest release has no installer package")
            }

            progress("Downloading \(package.name)…")
            let (sumData, _) = try await URLSession.shared.data(from: checksum.browser_download_url)
            guard let expected = publishedHash(String(decoding: sumData, as: UTF8.self)) else {
                return fallBack("the release's checksum couldn't be read")
            }
            let (downloaded, _) = try await URLSession.shared.download(from: package.browser_download_url)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("portside-xquartz-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkg = dir.appendingPathComponent(package.name)
            try FileManager.default.moveItem(at: downloaded, to: pkg)

            progress("Checking the package…")
            let actual = SHA256.hash(data: try Data(contentsOf: pkg, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { return fallBack("the download doesn't match its published checksum") }
            let signature = await run("/usr/sbin/pkgutil", ["--check-signature", pkg.path])
            guard signatureIsXQuartz(pkgutil: signature.output) else {
                return fallBack("the package isn't signed by XQuartz")
            }
            let gatekeeper = await run("/usr/sbin/spctl", ["-a", "-vv", "-t", "install", pkg.path])
            guard gatekeeperAccepts(spctl: gatekeeper.output, status: gatekeeper.status) else {
                return fallBack("macOS didn't accept the package as notarized")
            }

            NSWorkspace.shared.open(pkg)
            return .openedInstaller(version: release.tag_name)
        } catch {
            return fallBack("it couldn't be downloaded (\(error.localizedDescription))")
        }
    }

    @MainActor
    private static func fallBack(_ reason: String) -> Outcome {
        NSWorkspace.shared.open(website)
        return .openedWebsite(reason: reason)
    }

    private static func run(_ path: String, _ args: [String]) async -> (output: String, status: Int32) {
        await withCheckedContinuation { done in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                done.resume(returning: (String(decoding: data, as: UTF8.self), p.terminationStatus))
            }
            do { try p.run() } catch { done.resume(returning: ("", -1)) }
        }
    }

    /// Starts an installed XQuartz. A running one serves :0, which is all
    /// ssh needs (see `X11Support.displayEnvironment`).
    static func start() {
        for path in ["/Applications/Utilities/XQuartz.app", "/Applications/XQuartz.app"]
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            return
        }
    }
}
