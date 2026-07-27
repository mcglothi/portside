import SwiftUI

extension HostEnvironment {
    var color: Color? {
        switch self {
        case .none: return nil
        case .prod: return .red
        case .staging: return .orange
        case .dev: return .green
        case .personal: return .blue
        }
    }
}

struct EnvironmentBadge: View {
    let environment: HostEnvironment

    var body: some View {
        if let color = environment.color {
            CapsuleBadge(text: environment.label, color: color)
        }
    }
}

/// Transport marker (mosh, serial, telnet). Same visual language
/// as the environment badges so rows read as one line of chips.
struct TransportBadge: View {
    let entry: SessionEntry

    var body: some View {
        if entry.kind == .host, entry.preferMosh {
            CapsuleBadge(text: "mosh", color: .teal)
        }
        if entry.kind == .serial {
            CapsuleBadge(text: "serial", color: .orange)
        }
        if entry.kind == .telnet {
            CapsuleBadge(text: "unencrypted", color: .red)
        }
    }
}

/// The app's one capsule badge.
///
/// It already existed for host tags (environment, mosh, serial, unencrypted),
/// but the credential-profile list and the port-forwarding list had each
/// hand-rolled their own capsule beside it, at 6pt and 5pt horizontal padding
/// respectively. Same element, three implementations, none agreeing.
///
/// The styles are the three jobs a badge actually does here: label a *kind*
/// (tinted, the host tags), mark the *chosen* one (accent), or state a neutral
/// attribute. Uppercasing belongs to the tinted style only — it suits a
/// three-letter tag like PROD and looks shouty on a word like "Default".
struct CapsuleBadge: View {
    enum Style {
        case tinted(Color)
        case accent
        case neutral
    }

    let text: String
    var style: Style = .neutral

    init(text: String, style: Style = .neutral) {
        self.text = text
        self.style = style
    }

    /// Host tags, which are always tinted and uppercased.
    init(text: String, color: Color) {
        self.init(text: text, style: .tinted(color))
    }

    private var isTinted: Bool {
        if case .tinted = style { return true }
        return false
    }

    var body: some View {
        Text(isTinted ? text.uppercased() : text)
            .font(isTinted ? .system(size: 9, weight: .bold) : .caption2.weight(.semibold))
            .padding(.horizontal, Metrics.badgeHorizontal)
            .padding(.vertical, Metrics.badgeVertical)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    /// `AnyShapeStyle`, not `some View`: `.background(_:in:)` fills a shape with
    /// a style, and a `@ViewBuilder` here yields a view instead.
    private var background: AnyShapeStyle {
        switch style {
        case .tinted(let color): return AnyShapeStyle(color.opacity(0.18))
        case .accent: return AnyShapeStyle(Color.accentColor)
        case .neutral: return AnyShapeStyle(Color.secondary.opacity(0.18))
        }
    }

    private var foreground: Color {
        switch style {
        case .tinted(let color): return color
        case .accent: return .white
        case .neutral: return .secondary
        }
    }
}
