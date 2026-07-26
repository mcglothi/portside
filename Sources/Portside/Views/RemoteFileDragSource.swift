import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Fulfils a dragged-out remote file by downloading it **straight to wherever
/// it was dropped**.
///
/// This is why the drag path uses AppKit rather than SwiftUI's `.onDrag`: an
/// `NSItemProvider` file representation never learns the destination, so the
/// only thing it can do is download to a temp directory and hand the finished
/// file over for the system to copy again. On an 18GB model file that meant two
/// full-size writes, double the wall time, and nothing visible at the
/// destination until the whole thing had already landed once. A file *promise*
/// is given the real destination URL up front, so the bytes are written once
/// and the file appears and grows where the user dropped it.
final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let entry: SessionEntry
    private let remotePath: String
    private let name: String
    private let size: Int
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(entry: SessionEntry, remotePath: String, name: String, size: Int) {
        self.entry = entry
        self.remotePath = remotePath
        self.name = name
        self.size = size
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let entry = self.entry
        let remotePath = self.remotePath
        let name = self.name
        let size = self.size

        // The drag session ends the moment the file is dropped, but the
        // transfer runs on well past that, and this delegate is only weakly
        // held by its provider — so pin its lifetime to the download
        // explicitly. A bare `[self]` capture doesn't do it: the compiler sees
        // an unused capture and is free to drop it.
        let keepAlive = self
        let work = Task.detached {
            do {
                try await SFTPClient(entry: entry).download(remotePath: remotePath, to: url)
                withExtendedLifetime(keepAlive) {}
                completionHandler(nil)
            } catch {
                // Leave nothing half-written at the destination: a truncated
                // file sitting on the Desktop looks like a completed download.
                try? FileManager.default.removeItem(at: url)
                withExtendedLifetime(keepAlive) {}
                completionHandler(error)
            }
        }

        Task { @MainActor in
            let id = TransferCenter.shared.begin(
                entryID: entry.id, remotePath: remotePath,
                label: "Dragging \(name)", total: size,
                cancel: { work.cancel() }
            )
            // Progress comes from watching the destination grow — batch
            // `sftp -q` reports none, and the listing already told us the size.
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    let written = (try? FileManager.default
                        .attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
                    if let written { TransferCenter.shared.update(id, transferred: written) }
                }
            }
            await work.value
            poll.cancel()
            TransferCenter.shared.finish(id)
        }
    }
}

/// A transparent AppKit layer over a file row that owns **all** of its mouse
/// handling: click to select, double-click to activate, and drag to start a
/// file promise.
///
/// Deliberately one owner rather than SwiftUI gestures plus an AppKit drag.
/// Mixing the two is what produced this project's long-running sidebar
/// click/drag jank — a row that is both a gesture target and a drag source
/// ends up with each swallowing the other's mouse-down. Right-clicks are
/// passed through untouched so the SwiftUI `.contextMenu` beneath still works.
struct RemoteFileDragSource: NSViewRepresentable {
    let file: RemoteFile
    /// nil for rows that shouldn't be draggable (directories).
    let spec: (entry: SessionEntry, remotePath: String, name: String)?
    let onClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        view.configure(with: self)
        return view
    }

    func updateNSView(_ view: MouseView, context: Context) {
        view.configure(with: self)
    }

    final class MouseView: NSView, NSDraggingSource {
        private var source: RemoteFileDragSource?
        private var mouseDownAt: NSPoint?
        private var draggingStarted = false

        /// `NSFilePromiseProvider.delegate` is a **weak** reference, so a
        /// delegate created inline for the drag deallocates the moment the
        /// method returns — the provider is then left with no delegate and the
        /// drop silently does nothing (the drag itself still looks perfect,
        /// copy badge and all). Held here until the drag session ends; the
        /// download outlives that by capturing the delegate strongly.
        private static var activeDelegates: [RemoteFilePromiseDelegate] = []

        func configure(with source: RemoteFileDragSource) {
            self.source = source
        }

        /// Right- and control-clicks fall through to the SwiftUI row below, so
        /// the context menu keeps working without reimplementing it in AppKit.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent {
                switch event.type {
                case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                    return nil
                case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                    if event.modifierFlags.contains(.control) { return nil }
                default:
                    break
                }
            }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownAt = event.locationInWindow
            draggingStarted = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !draggingStarted, let start = mouseDownAt, let source, let spec = source.spec
            else { return }
            // A few points of slop so a slightly unsteady click doesn't
            // become a drag — and, more importantly, doesn't kick off a
            // multi-gigabyte transfer nobody asked for.
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            guard (dx * dx + dy * dy) > 9 else { return }
            // Dragging the same file out again while it's still coming down
            // would start a second transfer competing with the first for the
            // one connection — what turned a stalled-looking 18GB drag into
            // three of them.
            let alreadyRunning = MainActor.assumeIsolated {
                TransferCenter.shared.isTransferring(
                    remotePath: spec.remotePath, entryID: spec.entry.id
                )
            }
            guard !alreadyRunning else { return }
            draggingStarted = true
            beginPromiseDrag(spec: spec, size: source.file.size, event: event)
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownAt = nil }
            guard !draggingStarted, let source else { return }
            if event.clickCount >= 2 {
                source.onDoubleClick()
            } else {
                source.onClick()
            }
        }

        private func beginPromiseDrag(
            spec: (entry: SessionEntry, remotePath: String, name: String),
            size: Int, event: NSEvent
        ) {
            // An unrecognised extension (.gguf) yields a *dynamic* UTI, which
            // some drop targets won't accept. Plain data is safe, and the
            // promise reports the exact filename separately, so nothing gets
            // its extension rewritten the way NSItemProvider used to do.
            let resolved = UTType(filenameExtension: (spec.name as NSString).pathExtension)
            let type = (resolved?.isDynamic ?? true) ? UTType.data : resolved!

            let delegate = RemoteFilePromiseDelegate(
                entry: spec.entry, remotePath: spec.remotePath, name: spec.name, size: size
            )
            Self.activeDelegates.append(delegate)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
            let item = NSDraggingItem(pasteboardWriter: provider)

            let icon = NSWorkspace.shared.icon(for: type)
            icon.size = NSSize(width: 32, height: 32)
            item.setDraggingFrame(
                NSRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32),
                contents: icon
            )
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        /// By now the drop has already asked for the file, and the download
        /// task holds the delegate itself, so releasing our reference here is
        /// safe and keeps drags from accumulating for the life of the app.
        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            Self.activeDelegates.removeAll()
        }
    }
}
