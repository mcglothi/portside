import Foundation

/// Where the Help menu points.
///
/// Portside's documentation is written and has been for a while — compatibility,
/// port forwarding, the road to 1.0 — and until now the only way to reach any of
/// it was to go browsing the repository. These are the links the menu opens.
///
/// Deliberately the rendered GitHub pages rather than bundled copies. Docs get
/// corrections between releases, and a build from three months ago showing three
/// month-old caveats about *tunnel supervision* is the kind of stale that costs
/// someone an afternoon. The tradeoff is that Help needs a network; for an app
/// whose entire purpose is connecting to remote machines, that is not the
/// constraint it would be elsewhere.
enum Docs {
    static let repository = URL(string: "https://github.com/mcglothi/portside")!
    /// The project's own site, not the README — it's the front door, it has the
    /// screenshots, and it links onward to everything else.
    static let index = URL(string: "https://mcglothi.github.io/portside/")!
    static let multiExec = URL(string: "https://github.com/mcglothi/portside/blob/main/docs/multiexec.md")!
    static let compatibility = URL(string: "https://github.com/mcglothi/portside/blob/main/docs/COMPATIBILITY.md")!
    static let portForwarding = URL(string: "https://github.com/mcglothi/portside/blob/main/docs/port-forwarding.md")!
    static let newIssue = URL(string: "https://github.com/mcglothi/portside/issues/new/choose")!
    static let security = URL(string: "https://github.com/mcglothi/portside/security/advisories/new")!
}
