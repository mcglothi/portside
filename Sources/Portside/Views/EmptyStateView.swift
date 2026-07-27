import SwiftUI

/// The one empty state in the app.
///
/// Every view that can show nothing was inventing its own — the sidebar used
/// `ContentUnavailableView`, the history browser hand-rolled icon/title/detail,
/// the coverage view had a bare line of caption text, the file browser had two
/// lines jammed into one `Text`. They read as different apps, and the thin ones
/// read as a bug rather than a state.
///
/// Full-size states render as `ContentUnavailableView`, so they stay native and
/// follow the platform as it changes. The compact variant is hand-rolled because
/// there is no small `ContentUnavailableView` and the full one swamps a pane in
/// a split.
///
/// The shape is fixed on purpose: an icon, a short statement of *what is not
/// here*, and a detail line saying **what would put something here**. An empty
/// state that only says "nothing yet" tells you what you can already see.
///
/// `action` is for when the thing that fills the view is one control away. Leave
/// it off when the answer is somewhere else entirely — a wrong button is worse
/// than no button.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let detail: String
    var action: Action?
    /// For panes rather than whole windows.
    var compact = false

    struct Action {
        let label: String
        let perform: () -> Void
    }

    var body: some View {
        if compact {
            compactBody
        } else {
            ContentUnavailableView {
                Label(title, systemImage: icon)
            } description: {
                Text(detail)
            } actions: {
                if let action {
                    Button(action.label, action: action.perform)
                }
            }
        }
    }

    private var compactBody: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if let action {
                Button(action.label, action: action.perform)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
