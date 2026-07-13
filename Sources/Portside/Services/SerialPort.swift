import Darwin
import Foundation

/// Bridges a local serial device (/dev/cu.*) to the terminal: opens the fd,
/// applies the line settings, pumps reads through a DispatchSource, and
/// serializes writes. No child process — this *is* the transport.
final class SerialPort {
    enum SerialError: LocalizedError {
        case openFailed(path: String, errno: Int32)
        case configureFailed(path: String, errno: Int32)

        var errorDescription: String? {
            switch self {
            case .openFailed(let path, let code):
                return "cannot open \(path): \(String(cString: strerror(code))) (is the device connected and free?)"
            case .configureFailed(let path, let code):
                return "cannot configure \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Bytes read from the device. Invoked on an internal queue — hop to the
    /// main thread before touching the terminal view.
    var onData: ((ArraySlice<UInt8>) -> Void)?
    /// The port stopped: nil for a clean close, a message for device loss
    /// (USB adapter yanked mid-session is the common case).
    var onClosed: ((String?) -> Void)?

    private let fd: Int32
    private let path: String
    private let readSource: DispatchSourceRead
    private let writeQueue = DispatchQueue(label: "net.timmcg.portside.serial-write")
    private let stateLock = NSLock()
    private var closed = false

    init(target: SerialTarget) throws {
        path = target.devicePath
        // O_NONBLOCK so open doesn't hang waiting for carrier detect on a
        // line with no DCD wired (most console cables); cleared right after.
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.openFailed(path: path, errno: errno) }

        // Claim the device exclusively so a second session (or screen) can't
        // interleave bytes with ours, then return reads/writes to blocking.
        _ = ioctl(fd, TIOCEXCL)
        guard fcntl(fd, F_SETFL, 0) != -1,
              var tio = SerialPort.lineSettings(for: target, fd: fd),
              tcsetattr(fd, TCSANOW, &tio) != -1
        else {
            let code = errno
            Darwin.close(fd)
            throw SerialError.configureFailed(path: path, errno: code)
        }

        readSource = DispatchSource.makeReadSource(fileDescriptor: fd,
                                                   queue: DispatchQueue(label: "net.timmcg.portside.serial-read"))
        readSource.setEventHandler { [weak self] in self?.pumpReads() }
        readSource.activate()
    }

    /// The termios block for a target's line settings, seeded from the
    /// device's current state. Split out (and fd-optional) so tests can
    /// check flag mapping without a real device.
    static func lineSettings(for target: SerialTarget, fd: Int32 = -1) -> termios? {
        var tio = termios()
        if fd >= 0, tcgetattr(fd, &tio) == -1 { return nil }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)

        tio.c_cflag &= ~tcflag_t(CSIZE)
        tio.c_cflag |= tcflag_t(target.dataBits == 7 ? CS7 : CS8)

        switch target.parity {
        case .none:
            tio.c_cflag &= ~tcflag_t(PARENB)
        case .even:
            tio.c_cflag |= tcflag_t(PARENB)
            tio.c_cflag &= ~tcflag_t(PARODD)
        case .odd:
            tio.c_cflag |= tcflag_t(PARENB | PARODD)
        }

        if target.stopBits == 2 {
            tio.c_cflag |= tcflag_t(CSTOPB)
        } else {
            tio.c_cflag &= ~tcflag_t(CSTOPB)
        }

        tio.c_cflag &= ~tcflag_t(CRTSCTS)
        tio.c_iflag &= ~tcflag_t(IXON | IXOFF)
        switch target.flowControl {
        case .none: break
        case .rtsCts: tio.c_cflag |= tcflag_t(CRTSCTS)
        case .xonXoff: tio.c_iflag |= tcflag_t(IXON | IXOFF)
        }

        // Block reads until at least one byte arrives; the DispatchSource
        // only fires when data is waiting, so this never stalls the queue.
        withUnsafeMutableBytes(of: &tio.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        cfsetspeed(&tio, speed_t(target.baudRate))
        return tio
    }

    /// Writes terminal input out the wire, preserving order and riding out
    /// partial writes (flow control can drain slowly at low baud).
    func write(_ data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        writeQueue.async { [self] in
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { buf in
                    Darwin.write(fd, buf.baseAddress, buf.count)
                }
                if n > 0 {
                    offset += n
                } else if n == -1 && errno == EINTR {
                    continue
                } else {
                    return  // device gone; the read side reports it
                }
            }
        }
    }

    /// Idempotent teardown; safe from any thread.
    func close() {
        finish(message: nil)
    }

    deinit {
        finish(message: nil)
    }

    private func pumpReads() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n > 0 {
            onData?(buffer[0..<n])
        } else if n == 0 || (n == -1 && errno != EAGAIN && errno != EINTR) {
            // EOF or a real error — a USB adapter unplugged lands here.
            finish(message: "\(path) disconnected")
        }
    }

    private func finish(message: String?) {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()

        readSource.cancel()
        Darwin.close(fd)
        onClosed?(message)
    }
}

/// Lists candidate serial devices. Callout (cu.*) devices only — tty.* block
/// on carrier detect and are the wrong half of the pair for initiating.
enum SerialPortLocator {
    static func list() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") }
            .sorted { a, b in
                // Real adapters before the Bluetooth endpoints every Mac has.
                let aBT = a.localizedCaseInsensitiveContains("bluetooth")
                let bBT = b.localizedCaseInsensitiveContains("bluetooth")
                if aBT != bBT { return bBT }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { "/dev/" + $0 }
    }
}
