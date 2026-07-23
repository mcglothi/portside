import AppKit
import SwiftUI

/// Reusable identities hosts can defer to instead of their own credentials —
/// see `CredentialProfile` and `SessionStore.resolved(_:)`. Rotating a
/// profile's password/key here updates every host assigned to it immediately.
struct CredentialProfilesView: View {
    @EnvironmentObject var store: SessionStore
    @State private var editingProfile: CredentialProfile?

    private func subtitle(for profile: CredentialProfile) -> String {
        var parts: [String] = []
        if let user = profile.user, !user.isEmpty { parts.append(user) }
        if let key = profile.identityFile, !key.isEmpty {
            parts.append((key as NSString).lastPathComponent)
        }
        if CredentialStore.profilePassword(for: profile.id) != nil { parts.append("password saved") }
        return parts.isEmpty ? "No credentials set" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.credentialProfiles.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No Credential Profiles")
                        .font(.headline)
                    Text("Create one to apply a shared username, key, or password to a batch of hosts — and rotate it everywhere at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.credentialProfiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(profile.name)
                                    if store.defaultProfileID == profile.id {
                                        Text("Default")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor, in: Capsule())
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(subtitle(for: profile))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.defaultProfileID != profile.id {
                                Button("Set as Default") { store.defaultProfileID = profile.id }
                                    .buttonStyle(.link)
                            }
                            Button("Edit…") { editingProfile = profile }
                            Button("Delete", role: .destructive) { store.delete(profile) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editingProfile = profile }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("A host with no profile assigned but \"Save password in Keychain\" checked falls back to the Default profile — the same behavior the old single default password gave you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Profile…") { editingProfile = CredentialProfile(name: "") }
            }
            .padding(10)
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 360)
        .sheet(item: $editingProfile) { profile in
            CredentialProfileEditorView(profile: profile) { result in
                switch result {
                case .save(let updated):
                    store.upsert(updated)
                    if store.defaultProfileID == nil { store.defaultProfileID = updated.id }
                case .delete:
                    store.delete(profile)
                }
            }
        }
    }
}

struct CredentialProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CredentialProfile
    @State private var password = ""
    @State private var hasSavedPassword: Bool
    @State private var credentialError: String?
    private let isNew: Bool
    private let onComplete: (EditorResult<CredentialProfile>) -> Void

    init(profile: CredentialProfile, onComplete: @escaping (EditorResult<CredentialProfile>) -> Void) {
        _draft = State(initialValue: profile)
        _hasSavedPassword = State(initialValue: CredentialStore.profilePassword(for: profile.id) != nil)
        isNew = profile.name.isEmpty
        self.onComplete = onComplete
    }

    private var userBinding: Binding<String> {
        Binding(
            get: { draft.user ?? "" },
            set: { draft.user = $0.isEmpty ? nil : $0 }
        )
    }

    private var identityBinding: Binding<String> {
        Binding(
            get: { draft.identityFile ?? "" },
            set: { draft.identityFile = $0.isEmpty ? nil : $0 }
        )
    }

    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: (NSString(string: "~/.ssh").expandingTildeInPath))
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }

    /// Blank means "keep whatever's already saved" — matches the per-host
    /// editor's convention. An explicit Clear button is the only way to
    /// actually remove a saved password.
    private func persistPassword() -> Bool {
        guard !password.isEmpty else { return true }
        return CredentialStore.setProfilePassword(password, for: draft.id)
    }

    private func clearPassword() {
        CredentialStore.deleteProfilePassword(for: draft.id)
        hasSavedPassword = false
        password = ""
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isNew ? "New Credential Profile" : "Edit Credential Profile")
                .font(.headline)
            Form {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Ansible SVC account"))
                TextField("User", text: userBinding, prompt: Text("optional"))
                HStack {
                    TextField("Identity file (key)", text: identityBinding,
                              prompt: Text("optional — e.g. ~/.ssh/id_ed25519"))
                    Button("Browse…") { browseForKey() }
                }
                HStack {
                    SecureField("Password", text: $password,
                                prompt: Text(hasSavedPassword ? "•••••••• (saved — leave blank to keep)" : "optional"))
                    if hasSavedPassword {
                        Button("Clear") { clearPassword() }
                    }
                }
                Text("Stored in the macOS Keychain and shared by every host assigned to this profile — rotating it here updates them all immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    let saved = persistPassword()
                    onComplete(.save(draft))
                    if saved {
                        dismiss()
                    } else {
                        credentialError = "The profile was saved, but its password couldn't be written to the Keychain. Try Edit… again to retry."
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .alert("Password Not Saved", isPresented: Binding(
            get: { credentialError != nil }, set: { if !$0 { credentialError = nil } }
        )) {
            Button("OK") { dismiss() }
        } message: {
            Text(credentialError ?? "")
        }
    }
}
