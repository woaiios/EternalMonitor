import Foundation
import os

enum ConnectionTarget {
    case udp(host: String, port: UInt16)
    case usb(FramedLink)
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

enum DiagnosticLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let level: DiagnosticLevel
    let category: String
    let message: String
}

struct ConnectionDebugState {
    var host = ""
    var port: UInt16 = 0
    var listenerReadyPort: UInt16?
    var helloAttempts = 0
    var datagramsReceived = 0
    var datagramBytesReceived = 0
    var assembledFrames = 0
    var assembledFrameBytes = 0
    var decodePackets = 0
    var decodedFrames = 0
    var lastDecodedTimestampUs: UInt64 = 0

    func timeoutSummary(handshakeDone: Bool) -> String {
        if listenerReadyPort == nil {
            return "Receiver never became ready."
        }
        if helloAttempts == 0 {
            return "Listener came up, but HELLO registration never sent."
        }
        if datagramsReceived == 0 {
            if handshakeDone {
                return "Session accepted by \(host):\(port), but no video datagrams arrived."
            }
            return "HELLO sent \(helloAttempts)x to \(host):\(port), but no datagrams came back."
        }
        if assembledFrames == 0 {
            return "Received \(datagramsReceived) datagrams (\(datagramBytesReceived) bytes), but no complete frame was reassembled."
        }
        if decodePackets == 0 {
            return "Reassembled \(assembledFrames) frame payloads, but none could be parsed as FramePacket."
        }
        if decodedFrames == 0 {
            return "Parsed \(decodePackets) packets and assembled \(assembledFrames) payloads, but VideoToolbox produced no frames."
        }
        return "Received \(decodedFrames) decoded frames, but the connection did not transition cleanly."
    }

    func timeoutLevel(handshakeDone: Bool, answeredHereBefore: Bool) -> DiagnosticLevel {
        let unanswered = listenerReadyPort != nil && helloAttempts > 0 && datagramsReceived == 0 && !handshakeDone
        return unanswered && !answeredHereBefore ? .warning : .error
    }
}

extension DiagnosticLevel {
    var osLogType: OSLogType {
        switch self {
        case .info:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        }
    }
}
