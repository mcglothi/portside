import Foundation

/// Why a Kubernetes connection didn't get a shell, read from what kubectl (or
/// oc) printed.
///
/// A Kubernetes session on this Mac is a local shell that Portside types
/// `kubectl exec` into, so when kubectl fails nothing *ends* — the shell is
/// still there and `ConnectionDiagnosis`, which runs when a session's process
/// exits, never sees it. This reads the output just after the exec is typed
/// instead, and the same reading explains a failed Browse….
///
/// Like `ConnectionDiagnosis` this is a heuristic over English messages, and
/// built the same way: every reading carries the line it matched, so the user
/// sees the evidence and not only the conclusion. The patterns are kubectl's
/// own wording, captured from a real cluster for each case — see
/// `KubernetesDiagnosisTests`.
struct KubernetesDiagnosis: Equatable {
    enum Cause: Equatable {
        /// Expired or never signed in. The one cause Sign In answers.
        case signInNeeded
        /// The kubeconfig's credential plugin (konvoy-async-plugin,
        /// gke-gcloud-auth-plugin, kubelogin, …) isn't on the login shell's PATH.
        case pluginMissing(String)
        /// The credential plugin ran and failed — often a sign-in that was
        /// cancelled or timed out in the browser.
        case pluginFailed(String)
        /// Signed in, but RBAC doesn't allow this.
        case notAllowed
        /// The API server can't be reached: VPN, DNS, a firewall.
        case unreachable
        case contextMissing(String)
        /// The kubeconfig file is missing or kubectl can't parse it.
        case kubeconfigUnreadable
        case notFound
        case shellMissing(String)
        case containerMissing
    }

    var cause: Cause
    var headline: String
    var nextStep: String?
    /// kubectl's own line, verbatim.
    var evidence: String

    var offersSignIn: Bool {
        switch cause {
        case .signInNeeded, .pluginFailed: return true
        default: return false
        }
    }

    /// The first recognised failure in `output`, or nil. Escape sequences
    /// should already be stripped.
    static func diagnose(_ output: String, binary: KubernetesTarget.Binary = .kubectl) -> KubernetesDiagnosis? {
        let cli = binary.rawValue
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            if lower.contains("must be logged in to the server")
                || lower.contains("server has asked for the client to provide credentials")
                || (lower.hasPrefix("error") && lower.contains("(unauthorized)")) {
                return .init(cause: .signInNeeded,
                             headline: "Not signed in to this cluster",
                             nextStep: "The sign-in has expired or hasn\u{2019}t happened yet. Sign In runs it "
                                + "here, where you can see it; then Try Again.",
                             evidence: line)
            }
            if let plugin = value(in: line, after: "getting credentials: exec: executable ", before: " not found") {
                return .init(cause: .pluginMissing(plugin),
                             headline: "\u{201C}\(plugin)\u{201D} isn\u{2019}t installed where Portside looks",
                             nextStep: "Your kubeconfig signs in through \(plugin), and the login shell can\u{2019}t "
                                + "find it. Install it, or add its folder (often ~/.local/bin) to PATH in your "
                                + "shell\u{2019}s profile, not only your rc file.",
                             evidence: line)
            }
            if let plugin = value(in: line, after: "getting credentials: exec: executable ", before: " failed") {
                return .init(cause: .pluginFailed(plugin),
                             headline: "Signing in through \(plugin) didn\u{2019}t finish",
                             nextStep: "If a browser opened, the sign-in may have been cancelled or timed out. "
                                + "Sign In tries again here.",
                             evidence: line)
            }
            if lower.contains("error loading config file")
                || (lower.hasPrefix("error: stat ") && lower.contains("no such file or directory")) {
                return .init(cause: .kubeconfigUnreadable,
                             headline: "Can\u{2019}t read the kubeconfig",
                             nextStep: "Check the entry\u{2019}s Kubeconfig path, and that the file is the one your "
                                + "platform downloaded.",
                             evidence: line)
            }
            if lower.contains("error from server (forbidden)") {
                return .init(cause: .notAllowed,
                             headline: "Signed in, but not allowed here",
                             nextStep: "Your account can reach the cluster but its role doesn\u{2019}t allow this "
                                + "in this namespace. Check the namespace, or ask for access.",
                             evidence: line)
            }
            if let context = value(in: line, after: "context was not found for specified context: ", before: nil)
                ?? value(in: line, after: "no context exists with the name: ", before: nil) {
                let name = context.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                return .init(cause: .contextMissing(name),
                             headline: "No context \u{201C}\(name)\u{201D} in the kubeconfig",
                             nextStep: "Choose one with Browse… next to Context, or check which kubeconfig "
                                + "this entry uses.",
                             evidence: line)
            }
            if lower.contains("error from server (notfound)") {
                return .init(cause: .notFound,
                             headline: lower.contains("namespaces \"") ? "That namespace doesn\u{2019}t exist"
                                                                       : "Nothing by that name here",
                             nextStep: "A pod\u{2019}s name changes on every rollout. Point the entry at its "
                                + "workload, like deploy/web, with Browse….",
                             evidence: line)
            }
            if lower.contains("container") && lower.contains("is not valid for pod") {
                return .init(cause: .containerMissing,
                             headline: "That container isn\u{2019}t in the pod",
                             nextStep: "Choose one with Browse… next to Container, or leave it empty for the "
                                + "pod\u{2019}s default.",
                             evidence: line)
            }
            if let shell = value(in: line, after: "exec: \"", before: "\": executable file not found") {
                return .init(cause: .shellMissing(shell),
                             headline: "The image has no \(shell)",
                             nextStep: shell == "sh"
                                ? "This image has no shell at all (distroless). `\(cli) debug` can attach one."
                                : "Set the entry\u{2019}s Shell to sh.",
                             evidence: line)
            }
            if lower.hasPrefix("unable to connect to the server")
                || (lower.contains("dial tcp") && (lower.contains("connection refused") || lower.contains("i/o timeout")
                    || lower.contains("no such host") || lower.contains("network is unreachable"))) {
                return .init(cause: .unreachable,
                             headline: "Can\u{2019}t reach the cluster",
                             nextStep: "The API server didn\u{2019}t answer. On a VPN-only cluster, check the VPN.",
                             evidence: shortened(line))
            }
        }
        return nil
    }

    /// The text between `after` and `before` (or the end of the line).
    private static func value(in line: String, after: String, before: String?) -> String? {
        guard let start = line.range(of: after) else { return nil }
        let rest = line[start.upperBound...]
        if let before {
            guard let end = rest.range(of: before) else { return nil }
            let v = String(rest[..<end.lowerBound])
            return v.isEmpty ? nil : v
        }
        let v = String(rest).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// kubectl's connection errors arrive as long structured log lines.
    private static func shortened(_ line: String) -> String {
        line.count > 240 ? String(line.prefix(240)) + "\u{2026}" : line
    }
}

/// The command that signs in for a target, typed where the user can see it.
///
/// Portside never signs in on its own and never touches a token: it offers
/// the provider's own command, and the provider's CLI keeps its credentials.
/// For browser-based exec plugins — NKP's konvoy-async-plugin, kubelogin —
/// any kubectl call that needs credentials starts the sign-in, so the command
/// is a harmless read that needs them.
enum KubernetesSignIn {
    /// What `kubectl config view --minify` says about how a context signs in.
    struct Auth: Equatable {
        var execCommand: String?
        var server: String?
        var usesToken: Bool
        /// The AWS profile an EKS exec stanza signs in with — its env's
        /// `AWS_PROFILE`, or a `--profile` argument.
        var awsProfile: String? = nil
    }

    static func command(for target: KubernetesTarget, auth: Auth?, local: Bool) -> String {
        let plugin = auth?.execCommand.map { ($0 as NSString).lastPathComponent } ?? ""
        if plugin == "gke-gcloud-auth-plugin" {
            return "gcloud auth login"
        }
        if plugin == "aws" || plugin == "aws-iam-authenticator" {
            // The kubeconfig's own profile: the default one may be another
            // account, or not SSO at all.
            if let profile = auth?.awsProfile, !profile.isEmpty {
                return ShellQuoting.command(["aws", "sso", "login", "--profile", profile])
            }
            return "aws sso login"
        }
        // OpenShift keeps a plain token from `oc login`. Only when the entry
        // says it's OpenShift: a token alone is just as likely a static one,
        // which no login command renews.
        if target.binary == .oc, let server = auth?.server, !server.isEmpty {
            return ShellQuoting.command(["oc", "login", "--web", "--server=\(server)"])
        }
        return ShellQuoting.command(target.baseArguments(local: local) + ["auth", "can-i", "get", "pods"])
    }

    static func parse(configView output: String) -> Auth? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            return nil
        }
        let user = ((object["users"] as? [[String: Any]])?.first?["user"] as? [String: Any]) ?? [:]
        let exec = user["exec"] as? [String: Any]
        let server = ((object["clusters"] as? [[String: Any]])?.first?["cluster"] as? [String: Any])?["server"] as? String
        return Auth(execCommand: exec?["command"] as? String, server: server,
                    usesToken: user["token"] != nil || user["tokenFile"] != nil,
                    awsProfile: awsProfile(exec))
    }

    /// `--profile X` or `--profile=X` among the args, else `AWS_PROFILE` in
    /// its env: the AWS CLI lets a command-line option override the
    /// environment, so that's the profile the plugin actually uses.
    private static func awsProfile(_ exec: [String: Any]?) -> String? {
        let args = exec?["args"] as? [String] ?? []
        for (i, arg) in args.enumerated() {
            if arg == "--profile", i + 1 < args.count, !args[i + 1].hasPrefix("-") { return args[i + 1] }
            if arg.hasPrefix("--profile=") {
                let value = String(arg.dropFirst("--profile=".count))
                if !value.isEmpty, !value.hasPrefix("-") { return value }
            }
        }
        let env = exec?["env"] as? [[String: Any]] ?? []
        if let value = env.first(where: { $0["name"] as? String == "AWS_PROFILE" })?["value"] as? String,
           !value.isEmpty, !value.hasPrefix("-") {
            return value
        }
        return nil
    }
}
