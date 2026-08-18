import Foundation

/// Seeds the rotation sheet with fabricated results so its later stages can be
/// looked at.
///
/// ## Why this exists
///
/// Stages two and three of a rotation cannot be reached by hand. Getting there
/// honestly needs hosts that fail in specific ways — a host that declines the
/// key, a host whose own guard refuses the retirement, a push that failed — and
/// even with those, the sheet is closed to automation: AppleScript sees a
/// SwiftUI sheet as one opaque group, and it takes no keyboard focus even with
/// Full Keyboard Access enabled. Three approaches were tried and none worked.
///
/// So the states are constructed rather than reached, purely so somebody can
/// look at them.
///
/// ## Presentation only, and that is enforced
///
/// This is the dangerous part, and it is worth being blunt about. A seeded
/// `verified` is a **lie**: it is the exact record that authorises removing a
/// key from a live host, and nothing about it came from a host. If the sheet
/// let you act on it, this file would be a way to talk somebody into deleting
/// their own access.
///
/// So the sheet disables every action while a preview is active and says so on
/// screen. The seeding cannot arm anything — it can only be photographed.
enum RotationPreview {

    /// Read from the environment, so it needs no build flag. The app ships as a
    /// release build, so `#if DEBUG` would exclude it from exactly the build
    /// that gets tested, which is the same reason `PORTSIDE_LIBRARY_DIR` works
    /// this way.
    static let environmentKey = "PORTSIDE_DEBUG_ROTATION"

    struct Plan: Equatable {
        /// Which stage to open on.
        var stage: KeyRotation.Phase
        /// Whether to open that stage's confirmation rather than its picker.
        var confirming: Bool
    }

    /// `add`, `verify`, `retire`, or `confirm-retire`. Anything else is ignored
    /// rather than guessed at — a typo should do nothing, not open something
    /// unexpected.
    static func plan(from value: String?) -> Plan? {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "add": return Plan(stage: .add, confirming: false)
        case "confirm-add": return Plan(stage: .add, confirming: true)
        case "verify": return Plan(stage: .verify, confirming: false)
        case "retire": return Plan(stage: .retire, confirming: false)
        case "confirm-retire": return Plan(stage: .retire, confirming: true)
        default: return nil
        }
    }

    /// A representative mixture, applied to whichever hosts the rotation has.
    ///
    /// Deliberately not "everything succeeded". The states worth looking at are
    /// the awkward ones: a host that will keep its old key because it never
    /// verified, a host whose own guard refused, a push that failed. A
    /// screenshot of five green ticks proves nothing about the layout that
    /// matters.
    static func seed(_ rotation: inout KeyRotation) {
        let hosts = rotation.hosts
        guard !hosts.isEmpty else { return }

        func at(_ index: Int) -> UUID? {
            index < hosts.count ? hosts[index].id : nil
        }

        // 0: the whole way through, old key gone.
        if let id = at(0) {
            rotation.record(KeyPushOutcome.added, forHost: id)
            rotation.record(KeyVerifyOutcome.verified, forHost: id)
            rotation.record(KeyRetireOutcome.removed(1), forHost: id)
        }
        // 1: verified and still holding its old key — what Retire acts on.
        if let id = at(1) {
            rotation.record(KeyPushOutcome.added, forHost: id)
            rotation.record(KeyVerifyOutcome.verified, forHost: id)
        }
        // 2: the key is installed and the host will not authenticate it. This
        //    is the case the verify stage exists for, and it must be visibly
        //    excluded from retirement.
        if let id = at(2) {
            rotation.record(KeyPushOutcome.added, forHost: id)
            rotation.record(KeyVerifyOutcome.rejected("the host would not authenticate this key"),
                            forHost: id)
        }
        // 3: never got the key at all.
        if let id = at(3) {
            rotation.record(KeyPushOutcome.failed("ssh could not connect"), forHost: id)
        }
        // 4: verified, then the host's own guard refused the retirement.
        if let id = at(4) {
            rotation.record(KeyPushOutcome.alreadyPresent, forHost: id)
            rotation.record(KeyVerifyOutcome.verified, forHost: id)
            rotation.record(
                KeyRetireOutcome.refused("the new key is not active in authorized_keys"),
                forHost: id)
        }
        // 5: verified, retirement failed outright — must stay retryable.
        if let id = at(5) {
            rotation.record(KeyPushOutcome.added, forHost: id)
            rotation.record(KeyVerifyOutcome.verified, forHost: id)
            rotation.record(KeyRetireOutcome.failed("connection reset"), forHost: id)
        }
    }

    /// Shown on screen whenever a preview is active, so a screenshot can never
    /// be mistaken for a real run.
    static let banner =
        "PREVIEW — these results are fabricated by \(environmentKey) and no host was contacted. "
        + "Every action is disabled."
}
