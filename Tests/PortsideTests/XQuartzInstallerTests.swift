import XCTest
@testable import Portside

/// The package route opens an installer only if it's XQuartz's own, signed
/// and notarized. These run the checks against the output `pkgutil` and
/// `spctl` gave for the real XQuartz 2.8.6 package, and against the same
/// output with one thing wrong.
final class XQuartzInstallerTests: XCTestCase {
    private let pkgutil = """
    Package "XQuartz-2.8.6.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2026-07-13 23:06:08 +0000
       Certificate Chain:
        1. Developer ID Installer: Apple Inc. - XQuartz (NA574AWV7E)
           Expires: 2027-02-01 22:12:15 +0000
           ------------------------------------------------------------------------
        2. Developer ID Certification Authority
           Expires: 2027-02-01 22:12:15 +0000
           ------------------------------------------------------------------------
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000
    """
    private let spctl = """
    /tmp/XQuartz-2.8.6.pkg: accepted
    source=Notarized Developer ID
    origin=Developer ID Installer: Apple Inc. - XQuartz (NA574AWV7E)
    """

    func testTheRealPackagePasses() {
        XCTAssertTrue(XQuartzInstaller.signatureIsXQuartz(pkgutil: pkgutil))
        XCTAssertTrue(XQuartzInstaller.gatekeeperAccepts(spctl: spctl, status: 0))
    }

    func testAnotherTeamIsRefused() {
        let other = pkgutil.replacingOccurrences(of: "(NA574AWV7E)", with: "(ABCDE12345)")
        XCTAssertFalse(XQuartzInstaller.signatureIsXQuartz(pkgutil: other))
        XCTAssertFalse(XQuartzInstaller.gatekeeperAccepts(
            spctl: spctl.replacingOccurrences(of: "(NA574AWV7E)", with: "(ABCDE12345)"), status: 0))
    }

    func testTheTeamNameAloneIsNotEnough() {
        // XQuartz's team ID appearing anywhere but the leaf certificate.
        let lookalike = pkgutil.replacingOccurrences(
            of: "1. Developer ID Installer: Apple Inc. - XQuartz (NA574AWV7E)",
            with: "1. Developer ID Installer: Someone (NA574AWV7E) Else (ZZZZZ99999)")
        XCTAssertFalse(XQuartzInstaller.signatureIsXQuartz(pkgutil: lookalike))
        let application = pkgutil.replacingOccurrences(of: "Developer ID Installer", with: "Developer ID Application")
        XCTAssertFalse(XQuartzInstaller.signatureIsXQuartz(pkgutil: application), "an app certificate isn't an installer one")
    }

    func testUnsignedOrUnnotarizedIsRefused() {
        XCTAssertFalse(XQuartzInstaller.signatureIsXQuartz(pkgutil: "Package \"x.pkg\":\n   Status: no signature\n"))
        XCTAssertFalse(XQuartzInstaller.signatureIsXQuartz(pkgutil: pkgutil.replacingOccurrences(
            of: "issued by Apple for distribution", with: "issued by Apple (Development)")))
        XCTAssertFalse(XQuartzInstaller.gatekeeperAccepts(spctl: spctl, status: 3), "spctl's exit status counts")
        XCTAssertFalse(XQuartzInstaller.gatekeeperAccepts(
            spctl: spctl.replacingOccurrences(of: "Notarized Developer ID", with: "Developer ID"), status: 0))
        XCTAssertFalse(XQuartzInstaller.gatekeeperAccepts(
            spctl: spctl.replacingOccurrences(of: ": accepted", with: ": rejected"), status: 0))
    }

    func testThePublishedChecksumIsReadInEitherFormat() {
        let hash = "9ac35a505095bfbd3009c3b4772f0c6421e2f79c4210ab908459270d1c447909"
        XCTAssertEqual(XQuartzInstaller.publishedHash("SHA256(/Users/x/XQuartz-2.8.6.pkg)= \(hash)\n"), hash)
        XCTAssertEqual(XQuartzInstaller.publishedHash("\(hash.uppercased())  XQuartz-2.8.6.pkg\n"), hash)
        XCTAssertNil(XQuartzInstaller.publishedHash("not a checksum"))
    }

    func testTheReleasePicksThePackageNotTheSymbols() throws {
        let json = """
        {"tag_name":"XQuartz-2.8.6","assets":[
          {"name":"XQuartz-2.8.6.dSYMS.tar.bz2","browser_download_url":"https://example.com/a"},
          {"name":"XQuartz-2.8.6.pkg","browser_download_url":"https://example.com/b"},
          {"name":"XQuartz-2.8.6.pkg.sha256sum","browser_download_url":"https://example.com/c"}]}
        """
        let release = try JSONDecoder().decode(XQuartzInstaller.Release.self, from: Data(json.utf8))
        XCTAssertEqual(release.package?.name, "XQuartz-2.8.6.pkg")
        XCTAssertEqual(release.checksum?.name, "XQuartz-2.8.6.pkg.sha256sum")
    }

    func testHomebrewIsFoundWhereItInstallsAndNeverInstalled() {
        XCTAssertEqual(XQuartzInstaller.brew(exists: { $0 == "/usr/local/bin/brew" }), "/usr/local/bin/brew")
        XCTAssertEqual(XQuartzInstaller.brew(exists: { _ in true }), "/opt/homebrew/bin/brew")
        XCTAssertNil(XQuartzInstaller.brew(exists: { _ in false }))
        let command = XQuartzInstaller.brewCommand(brew: "/opt/homebrew/bin/brew")
        XCTAssertTrue(command.contains("'/opt/homebrew/bin/brew' install --cask xquartz;"))
        XCTAssertTrue(command.hasPrefix("PATH="), "the tab inherits no PATH")
        XCTAssertEqual(XQuartzInstaller.shell, "/bin/sh", "not the login shell, which may be fish or tcsh")
        XCTAssertFalse(command.contains("install.sh"), "never installs Homebrew itself")
    }

    /// The Homebrew route's command, run the way the tab runs it, parses as
    /// shell (checked with `sh -n`, nothing installed).
    func testTheBrewCommandIsValidShell() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: XQuartzInstaller.shell)
        p.arguments = ["-n", "-c", XQuartzInstaller.brewCommand(brew: "/opt/homebrew/bin/brew")]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}
