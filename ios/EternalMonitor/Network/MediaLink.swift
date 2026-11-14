import Foundation
import os

/// Explicit local-only per-frame tracing, sampled by the wire capture clock.
enum FrameTrace {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--frame-trace")
    static let key = "dev.eternalmonitor.trace.capture" as CFString
    private static let queue = DispatchQueue(label: "dev.eternalmonitor.frame-trace", qos: .utility)
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("frame-trace.log")
    private static let file: FileHandle? = {
        guard enabled else { return nil }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    static func sampled(_ capture: UInt64) -> Bool { enabled && capture != 0 && capture % 30 == 0 }
    static func start() { if enabled { _ = file } }
    static func log(_ event: String, capture: UInt64, fields: String = "") {
        guard sampled(capture), let file else { return }
        let now = ControlChannel.clientNowUs()
        let line = "event=\(event) capture_us=\(capture) client_us=\(now) \(fields)\n"
        queue.async { try? file.write(contentsOf: Data(line.utf8)) }
    }
}

/// Control and video share one link. Both implementations use the same
/// datagram decoder and session filter on their serial control queue.
/// Why a media link failed. `message` is the support-log wording; the app
/// decides what to tell the user from `kind` and `underlying`.
struct LinkError: Error, CustomStringConvertible {
    enum Kind: Equatable {
        case invalidConfiguration
        case resolve
        case pathUnavailable
        case localNetworkDenied
        case connectionFailed
        case receive
        case send
        case timeout
        case protocolMismatch
    }

    let kind: Kind
    let message: String
    var underlying: Error?

    init(_ kind: Kind, _ message: String, underlying: Error? = nil) {
        self.kind = kind
        self.message = message
        self.underlying = underlying
    }

    var description: String { message }
}

protocol MediaLink: AnyObject {
    var datagrams: MediaDatagrams { get }
    var controlQueue: DispatchQueue { get }
    var isUSB: Bool { get }
    var onConnectionEstablished: (() -> Void)? { get set }
    var onError: ((LinkError) -> Void)? { get set }
    var onListenerReady: ((UInt16) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    @discardableResult func start(host: String) -> Bool
    func send(_ data: Data)
    func stop()
}

extension MediaLink {
    var isUSB: Bool { false }
    var assembler: FrameAssembler? {
        get { datagrams.assembler }
        set { datagrams.assembler = newValue }
    }
    var onControlDatagram: ((Data) -> Void)? {
        get { datagrams.onControlDatagram }
        set { datagrams.onControlDatagram = newValue }
    }
    var onDatagramReceived: ((Int) -> Void)? {
        get { datagrams.onDatagramReceived }
        set { datagrams.onDatagramReceived = newValue }
    }
    var onDatagramIgnored: ((String) -> Void)? {
        get { datagrams.onDatagramIgnored }
        set { datagrams.onDatagramIgnored = newValue }
    }
    var onAudioPacket: ((AudioHeader, Data) -> Void)? {
        get { datagrams.onAudioPacket }
        set { datagrams.onAudioPacket = newValue }
    }
    func setAcceptedSessionId(_ id: UInt32) { datagrams.setAcceptedSessionId(id) }
    var legacyLookingDatagrams: Int { datagrams.legacyLookingDatagrams }
}

final class MediaDatagrams {
    var assembler: FrameAssembler?
    var onControlDatagram: ((Data) -> Void)?
    var onDatagramReceived: ((Int) -> Void)?
    var onDatagramIgnored: ((String) -> Void)?
    var onAudioPacket: ((AudioHeader, Data) -> Void)?
    private let acceptedSessionId = OSAllocatedUnfairLock<UInt32>(initialState: 0)
    private let unknownDatagramCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Media for another session was reported for this one. A PC streaming
    /// before its acceptance arrives, or still streaming an old session,
    /// sends it at the frame rate.
    private let reportedForeignSession = OSAllocatedUnfairLock<Bool>(initialState: false)

    func setAcceptedSessionId(_ id: UInt32) {
        acceptedSessionId.withLock { $0 = id }
        reportedForeignSession.withLock { $0 = false }
    }
    var legacyLookingDatagrams: Int { unknownDatagramCount.withLock { $0 } }
    func reset() {
        acceptedSessionId.withLock { $0 = 0 }
        unknownDatagramCount.withLock { $0 = 0 }
        reportedForeignSession.withLock { $0 = false }
    }

    func handle(_ data: Data) {
        switch Wire.classify(data) {
        case .media:
            onDatagramReceived?(data.count)
            guard let (header, payloadRange) = MediaHeader.decode(data) else {
                onDatagramIgnored?("Dropped malformed media datagram (\(data.count) bytes)")
                return
            }
            let expected = acceptedSessionId.withLock { $0 }
            guard header.sessionId == expected, expected != 0 else {
                let reported = reportedForeignSession.withLock { reported in
                    defer { reported = true }
                    return reported
                }
                if !reported { onDatagramIgnored?("Dropped media for foreign session \(header.sessionId)") }
                return
            }
            if header.fragIndex == 0 && !header.isRetransmit {
                FrameTrace.log("receive_first", capture: header.captureTimestampUs,
                               fields: "epoch=\(header.streamEpoch) seq=\(header.frameSeq)")
            }
            assembler?.addFragment(
                seq: header.frameSeq,
                index: header.fragIndex,
                count: header.fragCount,
                epoch: header.streamEpoch,
                isKeyframe: header.isKeyframe,
                captureTimestampUs: header.captureTimestampUs,
                payload: data.subdata(in: payloadRange),
                isRetransmit: header.isRetransmit
            )
        case .control:
            onControlDatagram?(data)
        case .audio:
            guard let (header, payloadRange) = AudioHeader.decode(data) else { return }
            let expected = acceptedSessionId.withLock { $0 }
            guard expected != 0, header.sessionId == expected else { return }
            onAudioPacket?(header, data.subdata(in: payloadRange))
        case .legacyHello:
            // The host never sends this; ignore.
            break
        case .unknown:
            if data.count >= 16 {
                // Looks like v1 media from an old host — count it so the app
                // can say "update the Windows host" instead of "no host found".
                unknownDatagramCount.withLock { $0 += 1 }
            }
            onDatagramIgnored?("Ignored unrecognized datagram (\(data.count) bytes)")
        }
    }
}
