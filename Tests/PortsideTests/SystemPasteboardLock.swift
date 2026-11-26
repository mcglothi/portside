import Foundation

/// `swift test --parallel` runs test classes in separate processes, and they all
/// share `NSPasteboard.general`. A test that sets the clipboard and then pastes
/// can have another process's snapshot-restore land in between (the 0.40.0
/// release gate failed exactly that way). Tests that touch the general
/// pasteboard hold this cross-process file lock for their duration.
enum SystemPasteboardLock {
    private static let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("portside-tests-general-pasteboard.lock")

    static func acquire() -> Int32 {
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        return fd
    }

    static func release(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}
