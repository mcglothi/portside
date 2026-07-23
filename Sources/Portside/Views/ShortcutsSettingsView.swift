import AppKit
import SwiftUI

/// Lets a user view and remap every shortcut in `ShortcutAction`, grouped by
/// category. Rebinding takes effect immediately — `PortsideApp`'s `.commands`
/// reads `store.keyBindings` reactively, the same way its existing "Go to Tab"
/// menu already reacts to state.
struct ShortcutsSettingsView: View {
    @EnvironmentObject var store: SessionStore
    @State private var recording: ShortcutAction?
    @State private var pendingConflict: (binding: KeyBinding, with: ShortcutAction)?

    var body: some View {
        Form {
            ForEach(ShortcutAction.categoryOrder, id: \.self) { category in
                Section(category) {
                    ForEach(ShortcutAction.allCases.filter { $0.category == category }) { action in
                        row(for: action)
                    }
                }
            }
            Section {
                Button("Reset All to Defaults") { store.updateKeyBindings(KeyBindings()) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 560)
        .alert(
            "Shortcut Already Used",
            isPresented: Binding(get: { pendingConflict != nil }, set: { if !$0 { pendingConflict = nil } })
        ) {
            Button("Use Anyway", role: .destructive) {
                if let pendingConflict, let action = recording {
                    apply(pendingConflict.binding, to: action, clearing: pendingConflict.with)
                }
                pendingConflict = nil
                recording = nil
            }
            Button("Cancel", role: .cancel) { pendingConflict = nil }
        } message: {
            if let pendingConflict {
                Text("\"\(pendingConflict.with.label)\" already uses this shortcut. Assign it here too and clear it there?")
            }
        }
    }

    @ViewBuilder
    private func row(for action: ShortcutAction) -> some View {
        HStack {
            Text(action.label)
            Spacer()
            if recording == action {
                ShortcutRecorderField(
                    onCapture: { handleCapture($0, for: action) },
                    onCancel: { recording = nil }
                )
                .frame(width: 130, height: 22)
                Button("Cancel") { recording = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Text(store.keyBindings.binding(for: action).displaySymbol)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
                if store.keyBindings.isCustomized(action) {
                    Button {
                        var kb = store.keyBindings
                        kb.reset(action)
                        store.updateKeyBindings(kb)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default")
                }
                Button("Record…") { recording = action }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func handleCapture(_ binding: KeyBinding, for action: ShortcutAction) {
        if let conflict = store.keyBindings.conflict(with: binding, excluding: action) {
            pendingConflict = (binding, conflict)
            return
        }
        apply(binding, to: action, clearing: nil)
        recording = nil
    }

    private func apply(_ binding: KeyBinding, to action: ShortcutAction, clearing other: ShortcutAction?) {
        var kb = store.keyBindings
        if let other { kb.reset(other) }
        kb.set(binding, for: action)
        store.updateKeyBindings(kb)
    }
}

/// Captures the next keystroke as a `KeyBinding`. Requires ⌘ to be held so an
/// accidental unmodified keypress can't get bound to a plain letter (which
/// would then swallow that key everywhere in the app).
private struct ShortcutRecorderField: NSViewRepresentable {
    let onCapture: (KeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: KeyRecorderNSView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
    }
}

final class KeyRecorderNSView: NSView {
    var onCapture: ((KeyBinding) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = "Press a shortcut…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            onCancel?()
            return
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<ModifierKey> = []
        if mods.contains(.command) { modifiers.insert(.command) }
        if mods.contains(.shift) { modifiers.insert(.shift) }
        if mods.contains(.option) { modifiers.insert(.option) }
        if mods.contains(.control) { modifiers.insert(.control) }
        guard modifiers.contains(.command) else {
            NSSound.beep()
            return
        }
        guard let key = ShortcutKey.from(charactersIgnoringModifiers: event.charactersIgnoringModifiers, keyCode: event.keyCode) else {
            NSSound.beep()
            return
        }
        onCapture?(KeyBinding(key: key, modifiers: modifiers))
    }
}
