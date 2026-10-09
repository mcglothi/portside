import XCTest
@testable import Portside

/// kubectl's failures, read the way the session bar and Browse… read them.
/// Every message here was captured from a real cluster (OrbStack, kubectl
/// 1.35) by producing that failure, not written from memory.
final class KubernetesDiagnosisTests: XCTestCase {
    private func cause(_ output: String) -> KubernetesDiagnosis.Cause? {
        KubernetesDiagnosis.diagnose(output)?.cause
    }

    func testTheRealMessages() {
        XCTAssertEqual(cause("error: You must be logged in to the server (Unauthorized)"), .signInNeeded)
        XCTAssertEqual(cause("""
            Unable to connect to the server: getting credentials: exec: executable konvoy-async-plugin not found

            It looks like you are trying to use a client-go credential plugin that is not installed.
            """), .pluginMissing("konvoy-async-plugin"))
        XCTAssertEqual(cause("Unable to connect to the server: getting credentials: exec: executable /usr/bin/false failed with exit code 1"),
                       .pluginFailed("/usr/bin/false"))
        XCTAssertEqual(cause(#"Error from server (Forbidden): deployments.apps "web" is forbidden: User "system:serviceaccount:portside-fixture:nobody" cannot get resource "deployments" in API group "apps" in the namespace "portside-fixture""#),
                       .notAllowed)
        XCTAssertEqual(cause(#"E1008 12:42:34.822451   36161 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list: Get \"https://127.0.0.1:1/api?timeout=3s\": dial tcp 127.0.0.1:1: connect: connection refused""#),
                       .unreachable)
        XCTAssertEqual(cause("Error in configuration: context was not found for specified context: nkp-nope"),
                       .contextMissing("nkp-nope"))
        XCTAssertEqual(cause(#"Error from server (NotFound): deployments.apps "nope" not found"#), .notFound)
        XCTAssertEqual(cause(#"Error from server (NotFound): pods "nope-123" not found"#), .notFound)
        XCTAssertEqual(cause(#"OCI runtime exec failed: exec failed: unable to start container process: exec: "bash": executable file not found in $PATH"#),
                       .shellMissing("bash"))
        XCTAssertEqual(cause("Error from server (BadRequest): container nope is not valid for pod web-79bbf699f7-7ftbd"),
                       .containerMissing)
    }

    /// Seen by accident while writing the live test: a kubeconfig kubectl
    /// can't parse, or a path that isn't there.
    func testAKubeconfigThatCantBeReadIsNamed() {
        XCTAssertEqual(cause(#"error: error loading config file "/var/folders/x/expired.json": yaml: found unknown escape character"#),
                       .kubeconfigUnreadable)
        XCTAssertEqual(cause(#"error: stat /Users/me/.kube/nkp.conf: no such file or directory"#), .kubeconfigUnreadable)
    }

    func testANamespaceThatDoesntExistSaysSo() {
        XCTAssertEqual(KubernetesDiagnosis.diagnose(#"Error from server (NotFound): namespaces "nope-ns" not found"#)?.headline,
                       "That namespace doesn\u{2019}t exist")
    }

    /// What a working session prints must read as nothing: the bar is for
    /// failures, and a false one over a live shell is noise.
    func testOrdinaryOutputIsNotAFailure() {
        XCTAssertNil(cause("Defaulted container \"app\" out of: app, sidecar\n/ # "))
        XCTAssertNil(cause("Last login: Thu Oct  8 12:00:00 on ttys001\nmcglothi@Newton ~ % kubectl exec -it deploy/web -- sh"))
        XCTAssertNil(cause("curl: (22) The requested URL returned error: 401 Unauthorized"))
        XCTAssertNil(cause(""))
    }

    func testOnlyAuthFailuresOfferSignIn() {
        XCTAssertTrue(KubernetesDiagnosis.diagnose("error: You must be logged in to the server (Unauthorized)")!.offersSignIn)
        XCTAssertFalse(KubernetesDiagnosis.diagnose(#"Error from server (NotFound): pods "x" not found"#)!.offersSignIn)
        XCTAssertFalse(KubernetesDiagnosis.diagnose("Error from server (Forbidden): pods is forbidden")!.offersSignIn,
                       "signed in already; signing in again won't grant a role")
    }

    // MARK: - Sign-in command

    /// NKP's kubeconfig (the redacted one from #26): a browser-based exec
    /// plugin, so the sign-in is any kubectl call that needs credentials.
    func testNKPSignsInByRunningKubectlWhereItCanBeSeen() throws {
        let view = #"""
        {"clusters":[{"cluster":{"server":"https://nkp-example-cl01-api.example.com:6443","certificate-authority-data":"DATA+OMITTED"},"name":"nkp-example-cl01.example.com"}],
         "users":[{"name":"default-profile-nkp-example-cl01.example.com","user":{"exec":{"apiVersion":"client.authentication.k8s.io/v1beta1",
           "command":"konvoy-async-plugin","args":["-auth-url=https://nkp-example-mgmt.example.com/token/async-auth/kubernetes-cluster"],
           "interactiveMode":"IfAvailable"}}}]}
        """#
        let auth = try XCTUnwrap(KubernetesSignIn.parse(configView: view))
        XCTAssertEqual(auth.execCommand, "konvoy-async-plugin")
        let target = KubernetesTarget(context: "default-profile-nkp-example-cl01.example.com", namespace: "shop", pod: "deploy/web")
        XCTAssertEqual(KubernetesSignIn.command(for: target, auth: auth, local: true),
                       "kubectl --context=default-profile-nkp-example-cl01.example.com --namespace=shop auth can-i get pods")
    }

    func testGKEAndOpenShiftUseTheirOwnLogins() {
        let gke = KubernetesSignIn.Auth(execCommand: "gke-gcloud-auth-plugin", server: "https://1.2.3.4", usesToken: false)
        XCTAssertEqual(KubernetesSignIn.command(for: KubernetesTarget(pod: "web"), auth: gke, local: true), "gcloud auth login")

        let ocp = KubernetesSignIn.Auth(execCommand: nil, server: "https://api.ocp.example.com:6443", usesToken: true)
        XCTAssertEqual(KubernetesSignIn.command(for: KubernetesTarget(pod: "web", binary: .oc), auth: ocp, local: true),
                       "oc login --web --server=https://api.ocp.example.com:6443")
        XCTAssertFalse(KubernetesSignIn.command(for: KubernetesTarget(pod: "web"), auth: ocp, local: true).hasPrefix("oc login"),
                       "a token alone isn't OpenShift; no login renews a static one")
    }

    /// EKS kubeconfigs name their AWS profile in the exec stanza — through
    /// `AWS_PROFILE` in its env, or `--profile`. Signing in the default
    /// profile instead signs in the wrong account, or one that isn't SSO.
    func testEKSSignsInTheProfileItsKubeconfigUses() throws {
        func view(_ exec: String) -> String {
            #"{"clusters":[{"cluster":{"server":"https://x.eks.amazonaws.com"}}],"users":[{"user":{"exec":"# + exec + "}}]}"
        }
        let byEnv = try XCTUnwrap(KubernetesSignIn.parse(configView: view(
            #"{"command":"aws","args":["eks","get-token","--cluster-name","prod"],"env":[{"name":"AWS_PROFILE","value":"prod-admin"}]}"#)))
        XCTAssertEqual(KubernetesSignIn.command(for: KubernetesTarget(pod: "web"), auth: byEnv, local: true),
                       "aws sso login --profile prod-admin")

        let byArg = try XCTUnwrap(KubernetesSignIn.parse(configView: view(
            #"{"command":"aws","args":["--region","us-west-2","eks","get-token","--cluster-name","prod","--profile","staging"]}"#)))
        XCTAssertEqual(KubernetesSignIn.command(for: KubernetesTarget(pod: "web"), auth: byArg, local: true),
                       "aws sso login --profile staging")

        let joined = try XCTUnwrap(KubernetesSignIn.parse(configView: view(
            #"{"command":"aws","args":["eks","get-token","--profile=dev"]}"#)))
        XCTAssertEqual(KubernetesSignIn.command(for: KubernetesTarget(pod: "web"), auth: joined, local: true),
                       "aws sso login --profile dev")

        let none = try XCTUnwrap(KubernetesSignIn.parse(configView: view(#"{"command":"aws","args":["eks","get-token"]}"#)))
        XCTAssertEqual(KubernetesSignIn.command(for: KubernetesTarget(pod: "web"), auth: none, local: true), "aws sso login")

        let hostile = try XCTUnwrap(KubernetesSignIn.parse(configView: view(
            #"{"command":"aws","args":["--profile","x; touch /tmp/p"]}"#)))
        XCTAssertEqual(KubernetesSignIn.command(for: KubernetesTarget(pod: "web"), auth: hostile, local: true),
                       "aws sso login --profile 'x; touch /tmp/p'")
    }

    func testAServerShapedLikeAnInjectionIsQuoted() {
        let auth = KubernetesSignIn.Auth(execCommand: nil, server: "https://x;touch /tmp/p", usesToken: true)
        let command = KubernetesSignIn.command(for: KubernetesTarget(pod: "web", binary: .oc), auth: auth, local: true)
        XCTAssertEqual(command, "oc login --web '--server=https://x;touch /tmp/p'")
    }

    // MARK: - The session watch

    @MainActor
    func testTheWatchReadsWholeLinesAcrossReadsAndStopsAtTheFirstReading() {
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        var readings: [KubernetesDiagnosis] = []
        view.onKubernetesDiagnosis = { readings.append($0) }
        view.kubernetesWatch = .init(binary: .kubectl, until: Date().addingTimeInterval(60))

        let message = Array("error: You must be logged in to the server (Unauthorized)\r\n".utf8)
        view.dataReceived(slice: message[0..<20])
        XCTAssertTrue(readings.isEmpty, "half a line isn't read")
        view.dataReceived(slice: message[20...])
        XCTAssertEqual(readings.map(\.cause), [.signInNeeded])
        view.dataReceived(slice: message[...])
        XCTAssertEqual(readings.count, 1, "one reading, then the watch is over")
    }

    @MainActor
    func testTheWatchEndsAtItsDeadline() {
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        var readings = 0
        view.onKubernetesDiagnosis = { _ in readings += 1 }
        view.kubernetesWatch = .init(binary: .kubectl, until: Date().addingTimeInterval(-1))
        view.dataReceived(slice: Array("error: You must be logged in to the server (Unauthorized)\r\n".utf8)[...])
        XCTAssertEqual(readings, 0)
        XCTAssertNil(view.kubernetesWatch)
    }

    /// Output from inside a pod that merely mentions a failure must not raise
    /// the bar: the user's first keystroke means they're past the exec.
    @MainActor
    func testTheUsersFirstKeystrokeEndsTheWatch() {
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        var readings = 0
        view.onKubernetesDiagnosis = { _ in readings += 1 }
        view.kubernetesWatch = .init(binary: .kubectl, until: Date().addingTimeInterval(60))
        view.send(source: view, data: Array("ls\r".utf8)[...])
        XCTAssertNil(view.kubernetesWatch)
        view.dataReceived(slice: Array("error: You must be logged in to the server (Unauthorized)\r\n".utf8)[...])
        XCTAssertEqual(readings, 0)
    }

    // MARK: - Live

    /// The whole path in a real session: a Kubernetes entry whose kubeconfig
    /// holds a token the cluster rejects, opened the way the sidebar opens it;
    /// the pane reports a sign-in problem while its shell stays up. Needs the
    /// fixture cluster (`PORTSIDE_K8S_CONTEXT`, default `orbstack`); skips
    /// without one.
    @MainActor
    func testAnExpiredSignInIsReportedInTheSession() async throws {
        let context = ProcessInfo.processInfo.environment["PORTSIDE_K8S_CONTEXT"] ?? "orbstack"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let view = Process()
        view.executableURL = URL(fileURLWithPath: shell)
        view.arguments = ["-lc", "kubectl config view --minify --flatten --context=\(context) -o json"]
        let pipe = Pipe()
        view.standardOutput = pipe
        view.standardError = FileHandle.nullDevice
        try view.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        view.waitUntilExit()
        guard view.terminationStatus == 0,
              var config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var users = config["users"] as? [[String: Any]], !users.isEmpty else {
            throw XCTSkip("no \(context) cluster")
        }
        users[0]["user"] = ["token": "expired-\(UUID().uuidString)"]
        config["users"] = users
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portside-k8s-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kubeconfig = dir.appendingPathComponent("expired.json")
        // kubectl reads JSON as YAML, and YAML has no `\/` escape.
        try JSONSerialization.data(withJSONObject: config, options: .withoutEscapingSlashes).write(to: kubeconfig)

        var entry = SessionEntry(name: "expired")
        entry.kind = .kubernetes
        entry.kubernetes = KubernetesTarget(context: context, namespace: "portside-fixture", pod: "deploy/web",
                                            kubeconfig: kubeconfig.path)
        let sessions = SessionManager()
        sessions.connect(to: entry)
        defer { sessions.tabs.forEach(sessions.closeTab) }
        let pane = try XCTUnwrap(sessions.tabs.last?.leaves.first)

        for _ in 0..<600 where pane.kubernetesDiagnosis == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(pane.kubernetesDiagnosis?.cause, .signInNeeded,
                       String(pane.terminalView.outputTail.current.suffix(400)))
        XCTAssertTrue(pane.isRunning, "the local shell is still there to sign in from")
    }
}
