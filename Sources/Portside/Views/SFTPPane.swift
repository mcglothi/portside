import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SFTPBrowserModel: ObservableObject {
    let entry: SessionEntry
    private let client: SFTPClient

    @Published var path = ""
    @Published var files: [RemoteFile] = []
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var showHidden = false

    private var loaded = false

    init(entry: SessionEntry) {
        self.entry = entry
        self.client = SFTPClient(entry: entry)
    }

    var visibleFiles: [RemoteFile] {
        showHidden ? files : files.filter { !$0.name.hasPrefix(".") }
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await withBusy {
            let home = try await self.client.pwd()
            try await self.load(home)
        }
    }

    func navigate(to file: RemoteFile) async {
        guard file.isDirectory || file.isSymlink else { return }
        await withBusy { try await self.load(self.join(file.name)) }
    }

    func navigateUp() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await withBusy { try await self.load(parent.isEmpty ? "/" : parent) }
    }

    func refresh() async {
        await withBusy { try await self.load(self.path) }
    }

    func upload(_ urls: [URL]) async {
        await withBusy {
            // A drop before the first listing lands leaves `path` empty, which
            // would send the file to sftp's default dir and list the wrong one.
            let target = self.path.isEmpty ? try await self.client.pwd() : self.path
            for url in urls {
                try await self.client.upload(localURL: url, toDirectory: target)
            }
            try await self.load(target)
        }
    }

    func makeDirectory(named name: String) async {
        guard !name.isEmpty else { return }
        await withBusy {
            try await self.client.mkdir(self.join(name))
            try await self.load(self.path)
        }
    }

    func delete(_ file: RemoteFile) async {
        await withBusy {
            try await self.client.delete(file, in: self.path)
            try await self.load(self.path)
        }
    }

    /// The Sendable pieces a drag-out promise needs. Captured on the main actor
    /// at drag start; the actual download must run OFF the main actor (a Finder
    /// drag spins a nested run loop on the main thread, so a @MainActor download
    /// would deadlock and the promised file would never arrive).
    func dragSpec(for file: RemoteFile) -> (entry: SessionEntry, remotePath: String, name: String) {
        (entry, join(file.name), file.name)
    }

    func downloadToDownloads(_ file: RemoteFile) async {
        await withBusy {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            var target = downloads.appendingPathComponent(file.name)
            var counter = 1
            while FileManager.default.fileExists(atPath: target.path) {
                let base = (file.name as NSString).deletingPathExtension
                let ext = (file.name as NSString).pathExtension
                let suffixed = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                target = downloads.appendingPathComponent(suffixed)
                counter += 1
            }
            try await self.client.download(remotePath: self.join(file.name), to: target)
        }
    }

    private func join(_ name: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }

    private func load(_ newPath: String) async throws {
        files = try await client.list(newPath)
        path = newPath
    }

    private func withBusy(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }
}

struct SFTPPaneView: View {
    @ObservedObject var model: SFTPBrowserModel
    @State private var newFolderName = ""
    @State private var showingNewFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage {
                errorBanner(error)
            }
            fileList
        }
        .background(.background)
        .task { await model.loadIfNeeded() }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.makeDirectory(named: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.navigateUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(model.path == "/" || model.isBusy)
            .help("Parent directory")

            Text(model.path.isEmpty ? "…" : model.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(model.path)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")

            Menu {
                Button("New Folder…") { showingNewFolder = true }
                Toggle("Show Hidden Files", isOn: $model.showHidden)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer()
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(6)
        .background(Color.yellow.opacity(0.12))
    }

    private var fileList: some View {
        List(model.visibleFiles) { file in
            row(for: file)
                .gesture(
                    TapGesture(count: 2).onEnded {
                        Task { await model.navigate(to: file) }
                    }
                )
                .contextMenu {
                    if file.isDirectory || file.isSymlink {
                        Button("Open") {
                            Task { await model.navigate(to: file) }
                        }
                    }
                    if !file.isDirectory {
                        Button("Download to ~/Downloads") {
                            Task { await model.downloadToDownloads(file) }
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        Task { await model.delete(file) }
                    }
                }
        }
        .listStyle(.inset)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.upload(urls) }
            return true
        }
        .overlay {
            if model.visibleFiles.isEmpty && !model.isBusy && model.errorMessage == nil {
                Text("Empty directory\nDrop files here to upload")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }
        }
    }

    /// A remote row. Files are draggable out to Finder/Desktop via a file
    /// promise (downloaded on drop); directories aren't draggable.
    @ViewBuilder
    private func row(for file: RemoteFile) -> some View {
        if file.isDirectory {
            RemoteFileRow(file: file)
        } else {
            RemoteFileRow(file: file)
                .onDrag { dragProvider(for: file) }
        }
    }

    /// An item provider backed by a lazy file promise: the file is downloaded
    /// only when the drop target (Finder) asks for it. The download runs on a
    /// detached task with a fresh SFTPClient (reusing the ControlMaster socket)
    /// so it never touches the main actor the drag's run loop is holding.
    private func dragProvider(for file: RemoteFile) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name
        let ext = (file.name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        let spec = model.dragSpec(for: file)
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task.detached {
                do {
                    let client = SFTPClient(entry: spec.entry)
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("portside-drag-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let local = dir.appendingPathComponent(spec.name)
                    try await client.download(remotePath: spec.remotePath, to: local)
                    progress.completedUnitCount = 1
                    completion(local, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }
}

struct RemoteFileRow: View {
    let file: RemoteFile

    private var icon: String {
        if file.isSymlink { return "arrow.triangle.turn.up.right.circle" }
        return file.isDirectory ? "folder.fill" : "doc"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !file.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .help("\(file.permissions)  \(file.dateText)")
    }
}
