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
            Text(environment.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(color)
                .background(color.opacity(0.18), in: Capsule())
        }
    }
}
