import Foundation
import Network

/// TCP transport for telnet. Network.framework owns connection lifecycle;
/// TelnetNegotiator keeps protocol bytes out of the terminal stream.
final class TelnetPort {
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onConnected: (() -> Void)?
    var onClosed: ((String?) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "net.timmcg.portside.telnet")
    private var negotiator = TelnetNegotiator()
    private var isClosed = false

    init(target: TelnetTarget) {
        connection = NWConnection(host: NWEndpoint.Host(target.host),
                                  port: NWEndpoint.Port(rawValue: target.resolvedPort) ?? 23,
                                  using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onConnected?()
                self.receiveNext()
            case .failed(let error):
                self.finish("telnet connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        let escaped = TelnetNegotiator.escapeOutgoing(bytes)
        connection.send(content: Data(escaped), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish("telnet write failed: \(error.localizedDescription)") }
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                let result = self.negotiator.consume(data)
                if !result.replies.isEmpty {
                    self.connection.send(content: Data(result.replies), completion: .contentProcessed { _ in })
                }
                if !result.payload.isEmpty { self.onData?(result.payload[...]) }
            }
            if let error {
                self.finish("telnet connection closed: \(error.localizedDescription)")
            } else if complete {
                self.finish("telnet connection closed")
            } else if !self.isClosed {
                self.receiveNext()
            }
        }
    }

    private func finish(_ message: String?) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClosed?(message)
    }
}

/// RFC 854's small command layer. We accept server echo and suppress-go-ahead
/// for normal line discipline and explicitly refuse every other option.
struct TelnetNegotiator {
    private static let iac: UInt8 = 255
    private static let will: UInt8 = 251
    private static let wont: UInt8 = 252
    private static let `do`: UInt8 = 253
    private static let dont: UInt8 = 254
    private static let sb: UInt8 = 250
    private static let se: UInt8 = 240
    private static let echo: UInt8 = 1
    private static let suppressGoAhead: UInt8 = 3

    private enum State { case data, command, option(UInt8), subnegotiation, subnegotiationIAC }
    private var state = State.data

    mutating func consume(_ data: Data) -> (payload: [UInt8], replies: [UInt8]) {
        var payload: [UInt8] = []
        var replies: [UInt8] = []
        for byte in data {
            switch state {
            case .data:
                state = byte == Self.iac ? .command : .data
                if byte != Self.iac { payload.append(byte) }
            case .command:
                switch byte {
                case Self.iac:
                    payload.append(byte)
                    state = .data
                case Self.will, Self.wont, Self.do, Self.dont:
                    state = .option(byte)
                case Self.sb:
                    state = .subnegotiation
                default:
                    state = .data
                }
            case .option(let command):
                replies += reply(to: command, option: byte)
                state = .data
            case .subnegotiation:
                state = byte == Self.iac ? .subnegotiationIAC : .subnegotiation
            case .subnegotiationIAC:
                state = byte == Self.se ? .data : .subnegotiation
            }
        }
        return (payload, replies)
    }

    static func escapeOutgoing(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        bytes.flatMap { $0 == iac ? [iac, iac] : [$0] }
    }

    private func reply(to command: UInt8, option: UInt8) -> [UInt8] {
        let accept = option == Self.echo || option == Self.suppressGoAhead
        let response: UInt8
        switch command {
        case Self.will: response = accept ? Self.do : Self.dont
        case Self.wont: response = Self.dont
        case Self.do: response = option == Self.suppressGoAhead ? Self.will : Self.wont
        case Self.dont: response = Self.wont
        default: return []
        }
        return [Self.iac, response, option]
    }
}
