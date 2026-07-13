import Darwin
import Foundation
import XCTest
@testable import Portside

final class SerialTests: XCTestCase {

    // MARK: - SessionEntry / SerialTarget

    func testSubtitleShowsDeviceAndSummary() {
        var entry = SessionEntry(name: "console")
        entry.kind = .serial
        entry.serial = SerialTarget(devicePath: "/dev/cu.usbserial-0001", baudRate: 9600,
                                    dataBits: 8, parity: .none, stopBits: 1)
        XCTAssertEqual(entry.subtitle, "cu.usbserial-0001 · 9600 8N1")
    }

    func testSubtitleWithNoDeviceChosen() {
        var entry = SessionEntry(name: "console")
        entry.kind = .serial
        entry.serial = SerialTarget()
        XCTAssertEqual(entry.subtitle, "no device")
    }

    func testSummaryReflectsParityAndStopBits() {
        var target = SerialTarget(devicePath: "/dev/cu.x", baudRate: 115200)
        target.parity = .even
        target.stopBits = 2
        XCTAssertEqual(target.summary, "115200 8E2")
    }

    func testSerialSessionNeitherUsesLocalTransportNorHostRouting() {
        // usesLocalTransport is the container/kubernetes "runs on this Mac"
        // path; serial has its own branch in SessionManager.connect and must
        // not be swept into that one by an over-broad kind check.
        var entry = SessionEntry(name: "console")
        entry.kind = .serial
        entry.serial = SerialTarget(devicePath: "/dev/cu.usbserial-0001")
        XCTAssertFalse(entry.usesLocalTransport)
    }

    func testFileBrowserUnsupportedOnSerial() {
        var entry = SessionEntry(name: "console")
        entry.kind = .serial
        XCTAssertFalse(entry.supportsFileBrowser)
    }

    func testPostConnectCommandReusesRunOnConnect() {
        var entry = SessionEntry(name: "console")
        entry.kind = .serial
        entry.runOnConnect = "   "
        XCTAssertNil(entry.postConnectCommand, "whitespace-only run-on-connect should not fire")
        entry.runOnConnect = "help"
        XCTAssertEqual(entry.postConnectCommand, "help")
    }

    func testDecodingOldLibraryWithoutSerialKey() throws {
        let old = #"{"name": "legacy", "hostname": "10.0.0.5"}"#
        let entry = try JSONDecoder().decode(SessionEntry.self, from: Data(old.utf8))
        XCTAssertNil(entry.serial)
        XCTAssertEqual(entry.kind, .host)
    }

    func testSerialTargetRoundTrips() throws {
        var entry = SessionEntry(name: "console")
        entry.kind = .serial
        entry.serial = SerialTarget(devicePath: "/dev/cu.usbserial-0001", baudRate: 57600,
                                    dataBits: 7, parity: .odd, stopBits: 2, flowControl: .rtsCts)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SessionEntry.self, from: data)
        XCTAssertEqual(decoded.serial, entry.serial)
        XCTAssertEqual(decoded.kind, .serial)
    }

    // MARK: - LogManager keying

    func testLogHostKeyUsesDeviceNameForSerial() {
        var entry = SessionEntry(name: "switch-console")
        entry.kind = .serial
        entry.serial = SerialTarget(devicePath: "/dev/cu.usbserial-0001")
        XCTAssertEqual(LogManager.hostKey(for: entry), "cu.usbserial-0001")
    }

    func testLogHostKeyFallsBackToNameWhenNoDevice() {
        var entry = SessionEntry(name: "switch-console")
        entry.kind = .serial
        entry.serial = SerialTarget() // no device chosen yet
        XCTAssertEqual(LogManager.hostKey(for: entry), "switch-console")
    }

    // MARK: - SerialPort.lineSettings (termios flag mapping, no real device)

    func test8N1MapsToRawModeWithoutParityOrExtraStopBit() {
        let target = SerialTarget(devicePath: "/dev/cu.x", baudRate: 9600,
                                  dataBits: 8, parity: .none, stopBits: 1)
        guard let tio = SerialPort.lineSettings(for: target) else {
            return XCTFail("lineSettings returned nil")
        }
        XCTAssertEqual(tio.c_cflag & tcflag_t(CSIZE), tcflag_t(CS8))
        XCTAssertEqual(tio.c_cflag & tcflag_t(PARENB), 0)
        XCTAssertEqual(tio.c_cflag & tcflag_t(CSTOPB), 0)
        XCTAssertEqual(tio.c_cflag & tcflag_t(CRTSCTS), 0)
        XCTAssertEqual(tio.c_iflag & tcflag_t(IXON | IXOFF), 0)
    }

    func testEvenParityAndTwoStopBitsSetExpectedFlags() {
        let target = SerialTarget(devicePath: "/dev/cu.x", baudRate: 9600,
                                  dataBits: 7, parity: .even, stopBits: 2)
        guard let tio = SerialPort.lineSettings(for: target) else {
            return XCTFail("lineSettings returned nil")
        }
        XCTAssertEqual(tio.c_cflag & tcflag_t(CSIZE), tcflag_t(CS7))
        XCTAssertNotEqual(tio.c_cflag & tcflag_t(PARENB), 0)
        XCTAssertEqual(tio.c_cflag & tcflag_t(PARODD), 0)
        XCTAssertNotEqual(tio.c_cflag & tcflag_t(CSTOPB), 0)
    }

    func testOddParitySetsBothParityFlags() {
        let target = SerialTarget(devicePath: "/dev/cu.x", parity: .odd)
        guard let tio = SerialPort.lineSettings(for: target) else {
            return XCTFail("lineSettings returned nil")
        }
        XCTAssertNotEqual(tio.c_cflag & tcflag_t(PARENB), 0)
        XCTAssertNotEqual(tio.c_cflag & tcflag_t(PARODD), 0)
    }

    func testHardwareFlowControlSetsCRTSCTS() {
        let target = SerialTarget(devicePath: "/dev/cu.x", flowControl: .rtsCts)
        guard let tio = SerialPort.lineSettings(for: target) else {
            return XCTFail("lineSettings returned nil")
        }
        XCTAssertNotEqual(tio.c_cflag & tcflag_t(CRTSCTS), 0)
    }

    func testSoftwareFlowControlSetsIXONIXOFF() {
        let target = SerialTarget(devicePath: "/dev/cu.x", flowControl: .xonXoff)
        guard let tio = SerialPort.lineSettings(for: target) else {
            return XCTFail("lineSettings returned nil")
        }
        XCTAssertNotEqual(tio.c_iflag & tcflag_t(IXON), 0)
        XCTAssertNotEqual(tio.c_iflag & tcflag_t(IXOFF), 0)
    }

    // MARK: - SerialPort open failure (no device required)

    func testOpeningMissingDeviceThrowsDescriptiveError() {
        let target = SerialTarget(devicePath: "/dev/cu.portside-does-not-exist")
        XCTAssertThrowsError(try SerialPort(target: target)) { error in
            guard let message = (error as? LocalizedError)?.errorDescription else {
                return XCTFail("expected a LocalizedError")
            }
            XCTAssertTrue(message.contains("/dev/cu.portside-does-not-exist"), message)
        }
    }

    // MARK: - Locator

    func testLocatorSortsBluetoothDevicesLast() {
        // Can't control what's actually plugged in on CI, but the sort rule
        // itself is deterministic and worth locking down: verify it doesn't
        // crash and that the result (if any) is sorted per the rule.
        let devices = SerialPortLocator.list()
        let bluetoothIndices = devices.enumerated().filter {
            $0.element.localizedCaseInsensitiveContains("bluetooth")
        }.map { $0.offset }
        let nonBluetoothIndices = devices.enumerated().filter {
            !$0.element.localizedCaseInsensitiveContains("bluetooth")
        }.map { $0.offset }
        if let firstBT = bluetoothIndices.min(), let lastNonBT = nonBluetoothIndices.max() {
            XCTAssertLessThan(lastNonBT, firstBT, "non-Bluetooth devices should sort before Bluetooth ones")
        }
    }
}
