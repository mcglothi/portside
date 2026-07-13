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

/// Transport marker (mosh today; serial/telnet to come). Same visual language
/// as the environment badges so rows read as one line of chips.
struct TransportBadge: View {
    let entry: SessionEntry

    var body: some View {
        if entry.kind == .host, entry.preferMosh {
            CapsuleBadge(text: "mosh", color: .teal)
        }
    }
}

struct CapsuleBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: Capsule())
    }
}
