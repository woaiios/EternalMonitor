import Foundation
@preconcurrency import CoreVideo
import Combine
import os
import UIKit

@MainActor
final class ConnectionManager: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var fps: Double = 0
    @Published var transportMode: String = "WiFi"
    @Published var connectionError: String?

    @Published var problem: ConnectionProblem?

    var linkFailure: ConnectionProblem?

    @Published var versionMismatch: VersionMismatch?
    @Published var pairingPrompt: PairingSheetModel?

    nonisolated static func featureCaps(wantsInput: Bool, wantsAudio: Bool, isUSB: Bool) -> UInt16 {
        (wantsInput ? Hello2.featureWantsInput : 0) | (wantsAudio ? Hello2.featureWantsAudio : 0)
            | (isUSB ? 0 : Hello2.featureSupportsNack) | Hello2.featureChecksUpdates
    }
    var awaitingPairing = false
    var explicitPairingToken: Data?
    let pairingStore = PairingStore.shared
    @Published var diagnostics: [DiagnosticEntry] = []

    @Published var stats = StreamStats()

    @Published var signalLost = false

    @Published var pictureRestoring = false

    @Published var reconnectAttempt = 0

    var isIdleOnConnect: Bool {
        state == .disconnected && problem == nil && connectionError == nil && reconnectAttempt == 0
    }

    @Published var videoSize: CGSize = .zero

    @Published var sessionWantsInput = false
    @Published var sessionDrawingMode = false
    @Published var sessionWantsAudio = false
    @Published var audioStats = AudioStats()

    @Published var hostInfo: ControlChannel.SessionInfo?

    @Published var feedbackAsk = FeedbackAsk()

    var streamingSince: Date?

    @Published var hostStreamConfig: StreamConfig?

    @Published var usbStatus = "USB: waiting for a cable"
    var mediaLink: (any MediaLink)?
    var usbListener: USBListener?
    var isForeground = true
    var usbPaused = false

    var usbStoppedForNoPicture = false
    let currentAttempt = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    var frameAssembler: FrameAssembler?
    var controlChannel: ControlChannel?
    var videoDecoder: VideoDecoder?
    var audioPlayer: AudioPlayer?
    var audioPreference: Bool?
    var timeoutTask: Task<Void, Never>?
    var statsFlushTask: Task<Void, Never>?

    let streamCounters = StreamCounters()
    var debugState = ConnectionDebugState()

    var didExtendTimeout = false

    var noPictureStreak = NoPictureStreak()

    var acceptedAddresses = Set<String>()

    var attemptStartedAt: TimeInterval = 0
    var sessionAcceptedAt: TimeInterval?
    var firstFrameAt: TimeInterval?

    var summaryStartedAt: TimeInterval = 0

    var summarizedNonces: [UInt32] = []

    let frameSlot = FrameSlot()

    let controlChannelBox = ControlChannelBox()
    var fpsCounter = FPSCounter()
    var lastLagPublishUs: UInt64 = 0

    var lagMs: Double = 0
    var lastTarget: (host: String, port: UInt16)?
    var livenessTimeoutUs: UInt64 = 3_000_000
    var degradedSinceUs: UInt64?
    var reconnectTask: Task<Void, Never>?

    var reconnectCycleID: UUID?

    var reconnectFailure: ConnectionProblem?
    var prevCounters = FrameAssembler.Counters()

    var resumeOnForeground = false
    var backgroundGoodbyeTask: UIBackgroundTaskIdentifier = .invalid

    static let connectionTimeoutSeconds: UInt64 = 10

    struct Timing {
        var connectTimeoutSeconds = Double(RemoteConfig.launch.firstFrameTimeoutSeconds
            ?? Int(ConnectionManager.connectionTimeoutSeconds))
        var reconnectGraceSeconds = 2.0
        var reconnectBackoffSeconds: (Int) -> Double = { attempt in Double(min(1 << (attempt - 1), 15)) }
    }
    var timing: Timing

    var makeUDPLink: (UInt16) -> any MediaLink

    init(timing: Timing = Timing(), udpReceiver: @escaping (UInt16) -> any MediaLink = { UDPReceiver(port: $0) }) {
        self.timing = timing
        self.makeUDPLink = udpReceiver
    }

    var latestFrame: CVPixelBuffer? {
        frameSlot.take()
    }

    var inputSequence = InputEventSequencer()
    var sessionHasKeyboard: Bool {
        sessionWantsInput && (hostInfo?.hostCaps ?? 0) & HelloAck.hostCapKeyboard != 0
    }
    var sessionHasPen: Bool {
        sessionWantsInput && (hostInfo?.hostCaps ?? 0) & HelloAck.hostCapPen != 0
    }

    func sendInputs(_ events: [WireInputEvent]) {
        guard sessionWantsInput else { return }
        controlChannelBox.value?.sendInputs(inputSequence.packets(events,
            timeUs: ControlChannel.clientNowUs(), reliable: mediaLink?.isUSB == true))
    }

    func connect(host: String, port: UInt16, token: Data? = nil) {
        guard state == .disconnected else { return }
        explicitPairingToken = token
        if let token {
            do { try pairingStore.save(token: token, hostName: "", address: PairingStore.address(host: host, port: port)) }
            catch { record(.warning, "pairing", "Could not save the scanned pairing on this iPad.") }
        }
        connect(target: .udp(host: host, port: port))
    }

    func submitPairing() {
        guard awaitingPairing, let code = pairingPrompt?.submit() else { return }

        recordSummary(.retriedWithCode)
        summaryStartedAt = ProcessInfo.processInfo.systemUptime
        controlChannel?.retryPairing(code: code)
    }

    func pairingSheetDismissed() {
        if awaitingPairing { cancel() }
    }

    func forgetPairedHosts() {
        do { try pairingStore.forgetAll() }
        catch { connectionError = "Could not remove saved pairings from this iPad." }
    }

    func connect(target: ConnectionTarget) {
        guard state == .disconnected else { return }
        if case .udp(let host, let port) = target,
           host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || port == 0 { return }
        endReconnectCycle()
        if case .udp(let host, _) = target, let typed = ConnectionProblem.typedAddress(host) {
            connectionError = nil
            problem = typed
            record(.warning, "connection", "Not connecting: the typed address looks like the pairing code")
            return
        }
        startAttempt(target)
    }

    func cancel() {
        if mediaLink?.isUSB == true {
            usbPaused = true
            usbListener?.stop()
            usbListener = nil
            usbStatus = "USB: disconnected"
        }
        timeoutTask?.cancel()
        endReconnectCycle()
        disconnect()
    }

    func retry() {
        guard state == .disconnected else { return }
        let cable = transportMode == "USB" || problem == .usbFailed
        endReconnectCycle()
        noPictureStreak.restartCount()
        problem = nil
        connectionError = nil
        if cable {
            resumeUSBConnections()
        } else if let target = lastTarget {
            connect(host: target.host, port: target.port)
        }
    }

    func reconnectToApply() {
        guard state == .connected else { return }
        let isUSB = mediaLink?.isUSB == true
        let target = lastTarget
        disconnect()
        if !isUSB, let target { connect(host: target.host, port: target.port) }
    }

    func refreshAudioPreference(_ enabled: Bool) {
        audioPreference = enabled
        guard !sessionDrawingMode || state == .disconnected else { return }
        if !enabled || sessionWantsAudio {
            audioPlayer?.setEnabled(enabled)
            audioStats.playing = false
        } else if state != .disconnected {

            let isUSB = mediaLink?.isUSB == true
            let target = lastTarget
            disconnect()
            if !isUSB, let target { connect(host: target.host, port: target.port) }
        }
    }

    func finishFeedbackAsk() {
        feedbackAsk.finish()
    }

    var feedbackContext: Feedback.Context {
        Feedback.Context.current(
            pcVersion: PCVersions.version(address: lastTarget?.host, name: hostInfo?.hostName),
            connection: state == .disconnected ? nil : (transportMode == "USB" ? "USB" : "Wi-Fi")
        )
    }

    func disconnect(_ end: AttemptEnd = .userDisconnect) {
        if state != .disconnected {
            recordStreamSummary(reason: "disconnect=\(end.name)")
            record(.info, "connection", "Disconnect state=\(state) reason=\(end.name)")
            recordSummary(end)
        }
        awaitingPairing = false
        pairingPrompt = nil
        currentAttempt.withLock { $0 = nil }
        timeoutTask?.cancel()
        timeoutTask = nil
        statsFlushTask?.cancel()
        statsFlushTask = nil
        didExtendTimeout = false

        controlChannel?.sendBye(end.bye)
        controlChannel?.stop()
        mediaLink?.stop()
        videoDecoder?.shutdown()
        audioPlayer?.stop()
        frameAssembler?.reset()
        _ = streamCounters.drain()

        controlChannel = nil
        controlChannelBox.value = nil
        mediaLink = nil
        fpsCounter = FPSCounter()
        frameAssembler = nil
        videoDecoder = nil
        audioPlayer = nil
        sessionWantsAudio = false
        audioStats = AudioStats()

        if state == .connected, let since = streamingSince {
            feedbackAsk.sessionEnded(after: Date().timeIntervalSince(since))
        }
        streamingSince = nil
        state = .disconnected
        fps = 0
        lagMs = 0
        stats = StreamStats()
        signalLost = false
        pictureRestoring = false
        degradedSinceUs = nil
        prevCounters = FrameAssembler.Counters()
        hostInfo = nil
        hostStreamConfig = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
