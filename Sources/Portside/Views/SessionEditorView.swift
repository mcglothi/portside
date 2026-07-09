import SwiftUI

enum EditorResult<T> {
    case save(T)
    case delete
}

struct SessionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SessionEntry
    @State private var portText: String
    private let isNew: Bool
    private let folders: [String]
    private let onComplete: (EditorResult<SessionEntry>) -> Void

    init(entry: SessionEntry, folders: [String], onComplete: @escaping (EditorResult<SessionEntry>) -> Void) {
        _draft = State(initialValue: entry)
        _portText = State(initialValue: entry.port.map(String.init) ?? "")
        isNew = entry.name.isEmpty
        self.folders = folders
        self.onComplete = onComplete
    }

    private var userBinding: Binding<String> {
        Binding(
            get: { draft.user ?? "" },
            set: { draft.user = $0.isEmpty ? nil : $0 }
        )
    }

    private var aliasBinding: Binding<String> {
        Binding(
            get: { draft.sshAlias ?? "" },
            set: { draft.sshAlias = $0.isEmpty ? nil : $0 }
        )
    }

    private var canSave: Bool {
        !draft.name.isEmpty && (!draft.hostname.isEmpty || !(draft.sshAlias ?? "").isEmpty)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isNew ? "New Session" : "Edit Session")
                .font(.headline)
            Form {
                TextField("Name", text: $draft.name)
                HStack {
                    TextField("Folder", text: $draft.folder, prompt: Text("e.g. prod/web — empty for top level"))
                    if !folders.isEmpty {
                        Menu {
                            ForEach(folders, id: \.self) { folder in
                                Button(folder) { draft.folder = folder }
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                TextField("Host", text: $draft.hostname)
                TextField("User", text: userBinding, prompt: Text("optional"))
                TextField("Port", text: $portText, prompt: Text("22"))
                TextField("~/.ssh/config alias", text: aliasBinding, prompt: Text("optional — connects via ssh <alias>"))
                Picker("Environment", selection: $draft.environment) {
                    ForEach(HostEnvironment.allCases) { env in
                        Text(env.label).tag(env)
                    }
                }
                Toggle("Protected host — excluded from MultiExec unless confirmed", isOn: $draft.isProtected)
            }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        onComplete(.delete)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    draft.port = Int(portText)
                    draft.folder = draft.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    onComplete(.save(draft))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct MacroEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Macro
    private let isNew: Bool
    private let onComplete: (EditorResult<Macro>) -> Void

    init(macro: Macro, onComplete: @escaping (EditorResult<Macro>) -> Void) {
        _draft = State(initialValue: macro)
        isNew = macro.name.isEmpty
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Macro" : "Edit Macro")
                .font(.headline)
            TextField("Name", text: $draft.name)
            Text("Text sent to the terminal (multi-line runs line by line):")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft.text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Toggle("Press Return after sending", isOn: $draft.sendReturn)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        onComplete(.delete)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onComplete(.save(draft))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.isEmpty || draft.text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
