//
//  ProcessTerminalView.swift
//
//  SwiftTerm 1.20's `LocalProcessTerminalView` (MacLocalTerminalView.swift),
//  copied into Portside so that Portside, not SwiftTerm, owns the pty and
//  the bytes it produces. SwiftTerm v2 (1.99) feeds process output straight
//  to its renderer on an IO thread and no longer calls `dataReceived`, which
//  is where Portside's logs, command capture, timeline and input guard all
//  hook in (#69). Owning this class keeps that hook under any SwiftTerm.
//
//  Behaviour is unchanged from 1.20 apart from the names.
//
//  Original: Copyright (c) 2019-2026 Miguel de Icaza, MIT License
//  (https://github.com/migueldeicaza/SwiftTerm/blob/main/LICENSE).
//

import Foundation
import AppKit
import SwiftTerm

/// Delegate for the ``ProcessTerminalView`` class that is used to
/// notify the user of process-related changes.
public protocol ProcessTerminalViewDelegate: AnyObject {
    /**
     * This method is invoked to notify that the terminal has been resized to the specified number of columns and rows
     * the user interface code might try to adjut the containing scroll view, or if it is a toplevel window, the window itself
     * - Parameter source: the sending instance
     * - Parameter newCols: the new number of columns that should be shown
     * - Parameter newRow: the new number of rows that should be shown
     */
    func sizeChanged(source: ProcessTerminalView, newCols: Int, newRows: Int)

    /**
     * This method is invoked when the title of the terminal window should be updated to the provided title
     * - Parameter source: the sending instance
     * - Parameter title: the desired title
     */
    func setTerminalTitle(source: ProcessTerminalView, title: String)

    /**
     * Invoked when the OSC command 7 for "current directory has changed" command is sent
     * - Parameter source: the sending instance
     * - Parameter directory: the new working directory
     */
    func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?)

    /**
     * This method will be invoked when the child process started by `startProcess` has terminated.
     * - Parameter source: the local process that terminated
     * - Parameter exitCode: the exit code returned by the process, or nil if this was an error caused during the IO reading/writing
     */
    func processTerminated (source: TerminalView, exitCode: Int32?)
}

/**
 * `ProcessTerminalView` is an AppKit NSView that can be used to host a local process
 * the process is launched inside a pseudo-terminal.
 *
 * Call the `startProcess` to launch the underlying process inside a pseudo terminal.
 *
 * Generally, for the `ProcessTerminalView` to be useful, you will want to disable the sandbox
 * for your application, otherwise the underlying shell will not have access to much - not the majority of
 * commands, not assorted places on the file systems and so on.   For this, you need to disable for your
 * target in "Signing and Capabilities" the sandbox entirely.
 *
 * Note: instances of `ProcessTerminalView` will set the `TerminalView`'s `delegate`
 * property and capture and consume the messages.   The messages that are most likely needed for
 * consumer applications are reposted to the `ProcessTerminalViewDelegate` in
 * `processDelegate`.   If you override the `delegate` directly, you might inadvertently break
 * the internal working of `ProcessTerminalView`.   If you must change the `delegate`
 * make sure that you proxy the values in your implementation to the values set after initializing this instance.
 *
 * If you want additional control over the delegate methods implemented in this class, you can
 * subclass this and override the methods
 */
open class ProcessTerminalView: TerminalView, TerminalViewDelegate, @preconcurrency LocalProcessDelegate {
    
    public internal(set) var process: LocalProcess!

    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        setup ()
    }

    /// Creates a local process terminal view with explicit startup options for the underlying `Terminal`
    public override init (frame: CGRect, font: NSFont? = nil, options: TerminalOptions)
    {
        super.init (frame: frame, font: font, options: options)
        setup ()
    }

    public required init? (coder: NSCoder)
    {
        super.init (coder: coder)
        setup ()
    }

    func setup ()
    {
        terminalDelegate = self
        // Delivered on the main queue, as SwiftTerm 1.x did by default:
        // everything in Portside's receive path (logs, capture, timeline,
        // guard, shadow) assumes it. v2's default is a private queue, and
        // with it the delivery thread raced the main thread over the command
        // capture and crashed (EXC_BAD_ACCESS in CommandOutputCapture).
        process = LocalProcess (delegate: self, dispatchQueue: .main)
    }
    
    /**
     * The `processDelegate` is used to deliver messages and information relevant t
     */
    public weak var processDelegate: ProcessTerminalViewDelegate?
    
    /**
     * This method is invoked to notify the client of the new columsn and rows that have been set by the UI
     */
    open func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard process.running else {
            return
        }
        var size = getWindowSize()
        let _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        
        processDelegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
    }
    
    public func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String (bytes: content, encoding: .utf8) {
            let pasteBoard = NSPasteboard.general
            pasteBoard.clearContents()
            pasteBoard.writeObjects([str as NSString])
        }
    }
    
    public func clipboardRead(source: TerminalView) -> Data? {
        guard let str = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        return str.data(using: .utf8)
    }
    
    /**
     * Invoke this method to notify the processDelegate of the new title for the terminal window
     */
    public func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle (source: self, title: title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    /**
     * Invoked when the user activates a link, override to handle the link yourself
     */
    open func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        TerminalView.openDefaultLink(link)   // what SwiftTerm's internal openLink does
    }

    /**
     * This method is invoked when input from the user needs to be sent to the client
     * Implementation of the TerminalViewDelegate method
     */
    open func send(source: TerminalView, data: ArraySlice<UInt8>)
    {
        if !ptyWriter.write(data) {
            process.send (data: data)
        }
    }

    /// Writes to the pty for us; see `PtyWriter`.
    let ptyWriter = PtyWriter()
    
    /**
     * Use this method to toggle the logging of data coming from the host, or pass nil to stop
     */
    public func setHostLogging (directory: String?)
    {
        process.setHostLogging (directory: directory)
    }
    
    /// Implementation of the TerminalViewDelegate method
    open func scrolled(source: TerminalView, position: Double) {
        // noting
    }

    open func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        //
    }
    
    /**
     * Launches a child process inside a pseudo-terminal.
     * - Parameter executable: The executable to launch inside the pseudo terminal, defaults to /bin/bash
     * - Parameter args: an array of strings that is passed as the arguments to the underlying process
     * - Parameter environment: an array of environment variables to pass to the child process, if this is null, this picks a good set of defaults from `Terminal.getEnvironmentVariables`.
     * - Parameter execName: If provided, this is used as the Unix argv[0] parameter, otherwise, the executable is used as the args [0], this is used when the intent is to set a different process name than the file that backs it.
     * - Parameter currentDirectory: If provided, the process will be launched with this as the current working directory.
     */
    public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil)
    {
        // A nil environment keeps the LocalProcess default (TERM=xterm-256color);
        // hosts that want options.termName in the child's environment pass
        // Terminal.getEnvironmentVariables(termName:) explicitly
        process.startProcess(executable: executable, args: args, environment: environment, execName: execName, currentDirectory: currentDirectory)
        ptyWriter.attach(process.childfd)
    }

    /**
     Terminate the process.
     */
    public func terminate() {
        ptyWriter.detach()
        process.terminate()
    }

    /**
     * Implements the LocalProcessDelegate method.
     */
    open func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        ptyWriter.detach()
        processDelegate?.processTerminated(source: self, exitCode: exitCode)
    }
    
    /**
     * Implements the LocalProcessDelegate.dataReceived method
     */
    open func dataReceived(slice: ArraySlice<UInt8>) {
        feed (byteArray: slice)
    }
    
    /**
     * Implements the LocalProcessDelegate.getWindowSize method
     */
    open func getWindowSize () -> winsize
    {
        // Cell size: SwiftTerm's own is internal. `cellSizeInPixels(source:)`
        // is the public form, already scaled for the display; under v2 it
        // reads a cached value and ignores `source`, which a view no longer
        // hands out, so a placeholder stands in for it.
        let dims = terminalDimensions
        let cell = cellSizeInPixels(source: Self.sizeQueryPlaceholder) ?? (width: 0, height: 0)
        let pxW = min(cell.width * dims.cols, Int(UInt16.max))
        let pxH = min(cell.height * dims.rows, Int(UInt16.max))
        return winsize(ws_row: UInt16(dims.rows), ws_col: UInt16(dims.cols), ws_xpixel: UInt16(pxW), ws_ypixel: UInt16(pxH))
    }
}

extension ProcessTerminalView {
    /// See `getWindowSize`: an argument SwiftTerm's cell-size query requires
    /// and no longer reads.
    static let sizeQueryPlaceholder = Terminal(delegate: PlaceholderTerminalDelegate())
}

private final class PlaceholderTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Writes input to the pty: keystrokes, pastes, and the terminal's own
/// replies to the program, in order.
///
/// SwiftTerm 2's `LocalProcess.send` queues writes on a `DispatchIO` channel.
/// On macOS 15 those writes never completed — programs drew but never saw a
/// key (#73, CI). This holds its own duplicate of the pty descriptor and
/// writes with `write(2)` on a serial queue, waiting with `poll` when the
/// pty is full, so a program that isn't reading can't block the main thread.
final class PtyWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "portside.pty-writer")
    private let lock = NSLock()
    private var fd: Int32 = -1

    /// Starts writing to `master`, a pty master descriptor. Ignores an
    /// invalid one, which leaves `write` returning false.
    func attach(_ master: Int32) {
        detach()
        guard master >= 0 else { return }
        let copy = dup(master)
        guard copy >= 0 else { return }
        lock.withLock { fd = copy }
    }

    /// Stops writing; anything still queued is dropped.
    func detach() {
        let old = lock.withLock { () -> Int32 in defer { fd = -1 }; return fd }
        guard old >= 0 else { return }
        // Closed on the queue, after any write already in progress.
        queue.async { close(old) }
    }

    /// Queues `data`; false when there's no pty to write to.
    func write(_ data: ArraySlice<UInt8>) -> Bool {
        let target = lock.withLock { fd }
        guard target >= 0 else { return false }
        guard !data.isEmpty else { return true }
        let bytes = Array(data)
        queue.async { [self] in
            var pending = bytes[...]
            while !pending.isEmpty {
                // Detached (or reattached) meanwhile: the rest is for a
                // process that's gone.
                guard lock.withLock({ fd }) == target else { return }
                let n = pending.withUnsafeBytes { Darwin.write(target, $0.baseAddress, $0.count) }
                if n > 0 { pending = pending.dropFirst(n); continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN {
                    var p = pollfd(fd: target, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 250)
                    continue
                }
                return  // EIO and the like: the other side has gone
            }
        }
        return true
    }
}
