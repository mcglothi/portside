import AppKit
import SwiftUI

/// What the sidebar asked publishing to do, carried through `LibraryCommands`
/// to the sheet that does it.
enum PublishRequest: Identifiable, Equatable {
    case create(folder: String)
    case link(sourceID: UUID)
    case publish(sourceID: UUID)

    var id: String {
        switch self {
        case .create(let f): return "create:\(f)"
        case .link(let s): return "link:\(s)"
        case .publish(let s): return "publish:\(s)"
        }
    }
}

struct PublishRequestSheet: View {
    let request: PublishRequest
    var body: some View {
        switch request {
        case .create(let folder): NewSharedInventoryView(folder: folder)
        case .link(let sourceID): LinkFolderView(sourceID: sourceID)
        case .publish(let sourceID): PublishChangesView(sourceID: sourceID)
        }
    }
}

// MARK: - New shared inventory from a folder

struct NewSharedInventoryView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let folder: String

    @State private var name = ""
    @State private var remote = ""
    @State private var ref = "main"
    @State private var path = "portside.json"
    @State private var working = false
    @State private var error: String?
    @State private var done: InventoryPublisher.Result?

    private var preview: InventoryPublishing.Prepared {
        InventoryPublishing.prepare(entries: store.entries, folders: store.folders, root: folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Shared Inventory from \u{201C}\(folder)\u{201D}").font(.headline)
            if let done {
                Label("Published \(preview.hosts.count) hosts to \(done.branch) (\(done.commit)).",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Teammates can subscribe with File \u{25B8} Shared Inventory\u{2026} and the same git URL. "
                     + "Edit hosts in \u{201C}\(folder)\u{201D} as usual, then choose Publish Changes on the folder.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Publishes this folder's hosts to a git repository your team can subscribe to. Use an "
                     + "empty repository; Portside never overwrites one that already has an inventory.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow { Text("Name"); TextField("", text: $name, prompt: Text("Platform Team")) }
                    GridRow { Text("Git URL"); TextField("", text: $remote, prompt: Text("git@github.com:team/inventory.git")) }
                    GridRow {
                        Text("Branch")
                        HStack {
                            TextField("", text: $ref).frame(width: 110)
                            Text("Manifest")
                            TextField("", text: $path)
                        }
                    }
                }
                PublishSummary(prepared: preview)
                Label("No secrets are published — passwords stay in your Keychain and personal settings are left "
                      + "out — but a host list is a map of your infrastructure. Keep the repository private.",
                      systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if working { ProgressView().controlSize(.small); Text("Publishing\u{2026}").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Create and Publish") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || remote.trimmingCharacters(in: .whitespaces).isEmpty || preview.hosts.isEmpty)
                }
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { if name.isEmpty { name = folder.split(separator: "/").last.map(String.init) ?? folder } }
    }

    private func create() {
        working = true
        error = nil
        let source = InventorySource(name: name, remote: remote, ref: ref, path: path)
        Task {
            let r = await store.createSharedInventory(source, fromFolder: folder)
            working = false
            switch r {
            case .success(let result): done = result
            case .failure(let f): error = f.message
            }
        }
    }
}

// MARK: - Link a folder to an existing source

struct LinkFolderView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    @State private var folder = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let name = store.inventorySource(id: sourceID)?.name ?? "the source"
        VStack(alignment: .leading, spacing: 12) {
            Text("Link a Folder for Publishing").font(.headline)
            Text("Copies \(name)\u{2019}s hosts into a folder of your own. Edit them there like any other host, "
                 + "then choose Publish Changes to propose your edits back to the team. The \(name) tree keeps "
                 + "showing what\u{2019}s been merged.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Folder")
                TextField("", text: $folder, prompt: Text("e.g. \(name) (editing)"))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") { link() }.keyboardShortcut(.defaultAction)
                    .disabled(working || folder.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear { if folder.isEmpty { folder = "\(name) (editing)" } }
    }

    private func link() {
        working = true
        Task {
            let failure = await store.linkFolderForPublishing(sourceID: sourceID, folder: folder)
            working = false
            if let failure { error = failure.message } else { dismiss() }
        }
    }
}

// MARK: - Publish Changes

/// The review before anything is sent. Modelled on what people already know
/// from a pull request: what's coming in, what's going out, field by field,
/// and a choice per host where both sides changed it.
struct PublishChangesView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID

    @State private var plan: InventoryPublishing.Plan?
    @State private var loadError: String?
    @State private var resolutions: [UUID: InventoryPublishing.Side] = [:]
    @State private var message = ""
    @State private var working = false
    @State private var error: String?
    @State private var done: InventoryPublisher.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let done {
                result(done)
            } else if let plan {
                review(plan)
            } else if let loadError {
                Text(loadError).foregroundStyle(.red).textSelection(.enabled)
                HStack { Spacer(); Button("Close") { dismiss() } }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Fetching the team\u{2019}s latest\u{2026}").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(18)
        .frame(width: 620)
        .frame(minHeight: 260)
        .task { await load() }
    }

    private var header: some View {
        let source = store.inventorySource(id: sourceID)
        let link = store.publishLink(forSource: sourceID)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Publish Changes to \(source?.name ?? "Shared Inventory")").font(.headline)
            if let source, let link {
                Text("From \u{201C}\(link.folder)\u{201D} \u{2192} \(source.remote) \u{00B7} "
                     + (link.directPush ? "pushes straight to \(source.ref)" : "a review branch off \(source.ref)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func load() async {
        switch await store.planPublish(sourceID: sourceID) {
        case .success(let p):
            plan = p
            message = Self.defaultMessage(p.changes())
        case .failure(let f): loadError = f.message
        }
    }

    static func defaultMessage(_ changes: [InventoryPublishing.Change]) -> String {
        func names(_ kind: InventoryPublishing.Change.Kind) -> [String] { changes.filter { $0.kind == kind }.map(\.name) }
        var parts: [String] = []
        for (verb, kind) in [("Add", InventoryPublishing.Change.Kind.added), ("Update", .changed), ("Remove", .removed)] {
            let n = names(kind)
            if n.isEmpty { continue }
            parts.append(n.count <= 3 ? "\(verb) \(n.joined(separator: ", "))" : "\(verb) \(n.count) hosts")
        }
        return parts.isEmpty ? "Update hosts" : parts.joined(separator: "; ")
    }

    @ViewBuilder private func review(_ plan: InventoryPublishing.Plan) -> some View {
        let merge = plan.merged(resolutions)
        let changes = plan.changes(resolutions)
        let incoming = plan.incoming
        let unresolved = merge.conflicts.filter { resolutions[$0.id] == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !incoming.isEmpty {
                    section("From the team since your last publish (\(incoming.count))",
                            note: "These come into your folder when you publish.") {
                        ForEach(incoming) { ChangeRow(change: $0) }
                    }
                }
                if !merge.conflicts.isEmpty {
                    section("Changed on both sides (\(merge.conflicts.count))",
                            note: "Choose which version each host keeps.") {
                        ForEach(merge.conflicts) { conflict in
                            ConflictRow(conflict: conflict, choice: Binding(
                                get: { resolutions[conflict.id] }, set: { resolutions[conflict.id] = $0 }))
                        }
                    }
                }
                section("Your changes (\(changes.count))") {
                    if changes.isEmpty {
                        Text("Nothing to publish: the team already has exactly this.").foregroundStyle(.secondary)
                    }
                    ForEach(changes) { ChangeRow(change: $0) }
                }
                if !plan.mine.notes.isEmpty {
                    section("Left out (\(plan.mine.notes.count))", note: "Personal settings never leave your Mac.") {
                        ForEach(Array(Set(plan.mine.notes)).sorted { $0.host < $1.host }, id: \.self) { n in
                            Text("\(n.host): \(n.text)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.secrets.isEmpty {
                    section("Looks like a secret \u{2014} remove before publishing") {
                        ForEach(plan.secrets, id: \.self) { n in
                            Label("\(n.host): \(n.text)", systemImage: "exclamationmark.octagon.fill")
                                .font(.callout).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 380)
        TextField("Commit message", text: $message)
        if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        HStack {
            if working { ProgressView().controlSize(.small); Text("Publishing\u{2026}").foregroundStyle(.secondary) }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(plan.link.directPush ? "Publish to \(plan.source.ref)" : "Publish for Review") { send(plan) }
                .keyboardShortcut(.defaultAction)
                .disabled(working || changes.isEmpty || !unresolved.isEmpty || !plan.secrets.isEmpty)
        }
    }

    @ViewBuilder private func result(_ r: InventoryPublisher.Result) -> some View {
        if r.branch == plan?.source.ref {
            Label("Published to \(r.branch) (\(r.commit)). Subscribers get it on their next pull.",
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Label("Pushed \(r.branch) (\(r.commit)) for review.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("It reaches subscribers once the pull request is merged. Your folder already has the team\u{2019}s "
                 + "latest changes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            if let url = r.pullRequestURL {
                Button("Open Pull Request") { NSWorkspace.shared.open(url) }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func send(_ plan: InventoryPublishing.Plan) {
        working = true
        error = nil
        Task {
            let r = await store.publish(plan, resolutions: resolutions, message: message)
            working = false
            switch r {
            case .success(let result): done = result
            case .failure(let f): error = f.message
            }
        }
    }

    private func section<Content: View>(_ title: String, note: String? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            content()
        }
    }
}

private struct ChangeRow: View {
    let change: InventoryPublishing.Change
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: change.kind == .added ? "plus.circle.fill"
                      : change.kind == .removed ? "minus.circle.fill" : "pencil.circle.fill")
                    .foregroundStyle(change.kind == .added ? .green : change.kind == .removed ? .red : .orange)
                Text(change.name)
            }
            ForEach(change.fields, id: \.self) { f in
                Text("\(f.field): \(f.before.isEmpty ? "\u{2014}" : f.before) \u{2192} \(f.after.isEmpty ? "\u{2014}" : f.after)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
    }
}

private struct ConflictRow: View {
    let conflict: InventoryPublishing.Conflict
    @Binding var choice: InventoryPublishing.Side?

    private func describe(_ e: SessionEntry?) -> String {
        guard let e else { return "removed" }
        return "\(e.subtitle)\(e.environment == .none ? "" : " \u{00B7} \(e.environment.rawValue)")"
            + (e.isProtected ? " \u{00B7} protected" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conflict.name).font(.body.weight(.medium))
            Picker("", selection: $choice) {
                Text("Mine: \(describe(conflict.mine))").tag(InventoryPublishing.Side?.some(.mine))
                Text("Theirs: \(describe(conflict.theirs))").tag(InventoryPublishing.Side?.some(.theirs))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }
}

/// How many hosts a folder will publish, and what it leaves out.
struct PublishSummary: View {
    let prepared: InventoryPublishing.Prepared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(prepared.hosts.count) host\(prepared.hosts.count == 1 ? "" : "s") will be published.")
                .font(.callout)
            let skipped = prepared.notes.filter { $0.text.hasPrefix("not published") }
            if !skipped.isEmpty {
                Text("\(skipped.count) left out (only SSH hosts can be shared).").font(.caption).foregroundStyle(.secondary)
            }
            let fields = prepared.notes.count - skipped.count
            if fields > 0 {
                Text("Personal settings left out on \(fields) host\(fields == 1 ? "" : "s"): run-on-connect, "
                     + "forwarding, credential profiles, favourites.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
