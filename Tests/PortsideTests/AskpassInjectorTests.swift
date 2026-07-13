import Foundation
import XCTest
@testable import Portside

final class AskpassInjectorTests: XCTestCase {
    func testEnvironmentCreatesPrivateFiles() throws {
        let injected = try XCTUnwrap(AskpassInjector.environment(for: "correct horse battery staple"))
        defer { injected.cleanup() }

        let values = envDictionary(injected.env)
        let askpass = try XCTUnwrap(values["SSH_ASKPASS"])
        let secret = try XCTUnwrap(values["PORTSIDE_ASKPASS_FILE"])
        let stateDir = try XCTUnwrap(values["PORTSIDE_ASKPASS_STATE_DIR"])

        XCTAssertEqual(values["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(try permissions(at: stateDir), 0o700)
        XCTAssertEqual(try permissions(at: askpass), 0o700)
        XCTAssertEqual(try permissions(at: secret), 0o600)
        XCTAssertTrue(askpass.hasPrefix(stateDir + "/"))
        XCTAssertTrue(secret.hasPrefix(stateDir + "/"))
    }

    func testHelperOnlySuppliesSavedPasswordOnceForPasswordPrompt() throws {
        let injected = try XCTUnwrap(AskpassInjector.environment(for: "secret-password"))
        defer { injected.cleanup() }

        let first = runHelper(injected.env, prompt: "user@example.com's password:")
        XCTAssertEqual(first.status, 0)
        XCTAssertEqual(first.output, "secret-password\n")

        let second = runHelper(injected.env, prompt: "user@example.com's password:")
        XCTAssertNotEqual(second.status, 0)
        XCTAssertEqual(second.output, "")
    }

    func testHelperSuppliesPassphrasePrompt() throws {
        let injected = try XCTUnwrap(AskpassInjector.environment(for: "key-passphrase"))
        defer { injected.cleanup() }

        let result = runHelper(injected.env, prompt: "Enter passphrase for key '/Users/tim/.ssh/id_ed25519':")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "key-passphrase\n")
    }

    func testMfaPromptFallsBackToDialogInsteadOfSavedPassword() throws {
        let injected = try XCTUnwrap(AskpassInjector.environment(for: "do-not-leak"))
        defer { injected.cleanup() }

        let fakeBin = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-askpass-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeBin) }

        let fakeOsascript = fakeBin.appendingPathComponent("osascript")
        try "#!/bin/sh\nprintf '123456\\n'\n".write(to: fakeOsascript, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeOsascript.path)

        var env = injected.env
        env.append("PATH=\(fakeBin.path):/usr/bin:/bin")
        let result = runHelper(env, prompt: "Verification code:")

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "123456\n")
    }

    private func envDictionary(_ pairs: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: pairs.compactMap { pair in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
        })
    }

    private func permissions(at path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func runHelper(_ envPairs: [String], prompt: String) -> (status: Int32, output: String) {
        let env = envDictionary(envPairs)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [env["SSH_ASKPASS"] ?? "", prompt]
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }
}
