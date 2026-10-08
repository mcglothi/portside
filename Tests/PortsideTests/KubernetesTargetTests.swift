import XCTest
@testable import Portside

/// Kubernetes entries (#26): the kubeconfig and CLI fields, how a library from
/// before them loads, and reading what kubectl answers.
final class KubernetesTargetTests: XCTestCase {

    /// A library written before `kubeconfig` and `binary` existed must load.
    /// A synthesized decoder would fail the entry on the missing keys.
    func testAnOlderEntryWithoutTheNewFieldsDecodes() throws {
        let old = #"{"context":"nkp","namespace":"shop","pod":"api-1","container":"","shell":"bash"}"#
        let t = try JSONDecoder().decode(KubernetesTarget.self, from: Data(old.utf8))
        XCTAssertEqual(t.pod, "api-1")
        XCTAssertEqual(t.shell, "bash")
        XCTAssertEqual(t.kubeconfig, "")
        XCTAssertEqual(t.binary, .kubectl)
    }

    func testAnUnknownCLIFromANewerVersionFallsBackRatherThanFailing() throws {
        let newer = #"{"pod":"api-1","binary":"k9s"}"#
        XCTAssertEqual(try JSONDecoder().decode(KubernetesTarget.self, from: Data(newer.utf8)).binary, .kubectl)
    }

    func testRoundTrips() throws {
        let t = KubernetesTarget(context: "c", namespace: "n", pod: "deploy/web", container: "app",
                                 shell: "bash", kubeconfig: "~/k.conf", binary: .oc)
        XCTAssertEqual(try JSONDecoder().decode(KubernetesTarget.self, from: JSONEncoder().encode(t)), t)
    }

    func testOcAndAKubeconfigReachTheCommand() {
        let t = KubernetesTarget(context: "ocp", pod: "deploy/api", kubeconfig: "/etc/k/ocp.conf", binary: .oc)
        XCTAssertEqual(t.execCommand(local: true),
                       "oc --kubeconfig=/etc/k/ocp.conf --context=ocp exec -it deploy/api -- sh")
    }

    /// Quoting stops the shell expanding `~`, so the path is resolved here:
    /// this Mac's home locally, relative (the remote home) over ssh.
    func testATildeKubeconfigIsResolvedForWhereItRuns() {
        let t = KubernetesTarget(pod: "web", kubeconfig: "~/.kube/nkp.conf")
        XCTAssertTrue(t.baseArguments(local: true).contains("--kubeconfig=\(NSHomeDirectory())/.kube/nkp.conf"))
        XCTAssertTrue(t.baseArguments(local: false).contains("--kubeconfig=.kube/nkp.conf"))
        XCTAssertFalse(t.execCommand(local: true)!.contains("~"))
    }

    func testAKubeconfigShapedLikeAnOptionStaysAValue() {
        let t = KubernetesTarget(pod: "web", kubeconfig: "-x; rm -rf ~")
        let command = t.execCommand(local: true)!
        XCTAssertTrue(command.contains("'--kubeconfig=-x; rm -rf ~'"), command)
    }

    // MARK: - Reading kubectl's answers (shapes from a real cluster)

    func testWorkloadsComeFirstAsTheNamesExecTakes() throws {
        let json = #"""
        {"items":[
          {"kind":"Pod","metadata":{"name":"web-79bb-7ftbd"},"status":{"phase":"Running",
            "containerStatuses":[{"ready":true},{"ready":false}]}},
          {"kind":"StatefulSet","metadata":{"name":"db"},"spec":{"replicas":1},"status":{"readyReplicas":1}},
          {"kind":"Deployment","metadata":{"name":"web"},"spec":{"replicas":2},"status":{"readyReplicas":2}},
          {"kind":"DaemonSet","metadata":{"name":"agent"},"status":{"desiredNumberScheduled":3,"numberReady":2}}
        ]}
        """#
        let rows = try ContainerLister.parseWorkloads(json)
        XCTAssertEqual(rows.map(\.name), ["deploy/web", "ds/agent", "sts/db", "web-79bb-7ftbd"])
        XCTAssertEqual(rows[0].detail, "Deployment · 2/2 ready")
        XCTAssertEqual(rows[1].detail, "DaemonSet · 2/3 ready")
        XCTAssertEqual(rows[3].detail, "Running · ready 1/2")
    }

    func testContextsAndTheCurrentOne() throws {
        let json = #"""
        {"current-context":"nkp-prod","contexts":[
          {"name":"nkp-prod","context":{"cluster":"prod","namespace":"shop"}},
          {"name":"gke_p_z_c","context":{"cluster":"gke_p_z_c"}}]}
        """#
        let (contexts, current) = try ContainerLister.parseContexts(json)
        XCTAssertEqual(contexts.map(\.name), ["gke_p_z_c", "nkp-prod"])
        XCTAssertEqual(contexts[1].namespace, "shop")
        XCTAssertEqual(current, "nkp-prod")
    }

    func testContainersOfAWorkloadAndTheAnnotatedDefault() throws {
        let deploy = #"""
        {"kind":"Deployment","spec":{"template":{
          "metadata":{"annotations":{"kubectl.kubernetes.io/default-container":"app"}},
          "spec":{"containers":[{"name":"sidecar"},{"name":"app"}]}}}}
        """#
        let w = try ContainerLister.parseContainerNames(deploy)
        XCTAssertEqual(w.names, ["sidecar", "app"])
        XCTAssertEqual(w.defaultName, "app")

        let pod = #"{"kind":"Pod","metadata":{},"spec":{"containers":[{"name":"lone"}]}}"#
        XCTAssertEqual(try ContainerLister.parseContainerNames(pod).defaultName, "lone", "else the first")
    }

    func testAnswerThatIsntJSONIsAnErrorNotAnEmptyList() {
        XCTAssertThrowsError(try ContainerLister.parseWorkloads("error: You must be logged in to the server"))
    }

    // MARK: - Live, against Scripts/k8s-fixture

    /// The whole discovery path against a real cluster: workloads, contexts
    /// and containers, through the login shell the app uses. Runs where the
    /// fixture is deployed (`PORTSIDE_K8S_CONTEXT`, default `orbstack`) and
    /// skips everywhere else, CI included.
    func testDiscoveryAgainstTheFixtureCluster() async throws {
        let context = ProcessInfo.processInfo.environment["PORTSIDE_K8S_CONTEXT"] ?? "orbstack"
        var entry = SessionEntry(name: "fixture")
        entry.kind = .kubernetes
        entry.kubernetes = KubernetesTarget(context: context, namespace: "portside-fixture", pod: "deploy/web")
        let rows: [RunningContainer]
        do { rows = try await ContainerLister.list(for: entry) } catch {
            throw XCTSkip("no fixture cluster (\(error.localizedDescription.prefix(80)))")
        }
        try XCTSkipIf(rows.isEmpty, "fixture namespace not deployed")

        XCTAssertEqual(Array(rows.map(\.name).prefix(2)), ["deploy/web", "sts/db"])
        XCTAssertTrue(rows.contains { $0.name == "lone" })
        let (contexts, _) = try await ContainerLister.contexts(for: entry)
        XCTAssertTrue(contexts.contains { $0.name == context })
        let containers = try await ContainerLister.containers(for: entry)
        XCTAssertEqual(containers.names, ["app", "sidecar"])
        XCTAssertEqual(containers.defaultName, "app")
    }
}
