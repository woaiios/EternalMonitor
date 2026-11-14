import Foundation
@preconcurrency import CoreVideo
import os
import UIKit

@MainActor extension ConnectionManager {
    func startAttempt(_ target: ConnectionTarget) {
        guard state == .disconnected else { return }
        let normalizedHost: String
        let port: UInt16
        let receiver: any MediaLink
        switch target {
        case .udp(let host, let targetPort):
            normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedHost.isEmpty, targetPort != 0 else { return }
            SupportDiagnostics.noteTypedAddress(normalizedHost)
            port = targetPort
            receiver = makeUDPLink(port)
            lastTarget = (normalizedHost, port)
        case .usb(let link):
            normalizedHost = "USB"
            port = 9877
            receiver = link
            if lastTarget == nil, let host = UserDefaults.standard.string(forKey: "lastHost"), !host.isEmpty {
                let savedPort = UserDefaults.standard.integer(forKey: "lastPort")
                lastTarget = (host, UInt16(exactly: savedPort).flatMap { $0 == 0 ? nil : $0 } ?? 9876)
            }
        }
        let isUSB = receiver.isUSB
        let pairingAddress = isUSB ? "USB" : PairingStore.address(host: normalizedHost, port: port)
        let pairingToken = explicitPairingToken ?? ((try? pairingStore.token(address: pairingAddress)) ?? Data(repeating: 0, count: 16))
        explicitPairingToken = nil
        let connectionID = UUID()
        currentAttempt.withLock { $0 = connectionID }
        transportMode = isUSB ? "USB" : "WiFi"
        if isUSB { usbStatus = "USB: connecting" }
        fpsCounter = FPSCounter()

        state = .connecting
        connectionError = nil
        problem = nil
        linkFailure = nil
        versionMismatch = nil
        signalLost = false
        degradedSinceUs = nil
        prevCounters = FrameAssembler.Counters()
        diagnostics.removeAll()
        didExtendTimeout = false
        attemptStartedAt = ProcessInfo.processInfo.systemUptime
        sessionAcceptedAt = nil
        firstFrameAt = nil
        summaryStartedAt = attemptStartedAt
        videoSize = .zero
        let drawing = DrawingProfile(enabled: UserDefaults.standard.bool(forKey: "drawingMode"), isUSB: isUSB)
        sessionDrawingMode = drawing.enabled
        let wantsInput = drawing.enabled || UserDefaults.standard.flag(forKey: "controlPC")
        sessionWantsInput = wantsInput
        let wantsAudio = !drawing.enabled && (audioPreference ?? UserDefaults.standard.flag(forKey: "playPCaudio"))
        sessionWantsAudio = wantsAudio
        audioStats = AudioStats()
        debugState = ConnectionDebugState(host: normalizedHost, port: port)
        record(.info, "connection", "Starting connection attempt=\(connectionID) transport=\(transportMode) to \(normalizedHost):\(port) drawing=\(drawing.enabled) input=\(wantsInput) audio=\(wantsAudio)")

        let decoder = VideoDecoder()
        let metrics = ReceiverMetrics()
        let assembler = FrameAssembler()
        let audio = wantsAudio ? AudioPlayer() : nil

        wireMediaCallbacks(connectionID: connectionID, receiver: receiver, assembler: assembler, audio: audio)
        wireDecoderCallbacks(connectionID: connectionID, normalizedHost: normalizedHost, port: port,
                             isUSB: isUSB, decoder: decoder, metrics: metrics)
        let channel = wireAssemblyAndMakeChannel(connectionID: connectionID, receiver: receiver,
                                                 assembler: assembler, decoder: decoder,
                                                 audio: audio, metrics: metrics)
        wireControlChannelCallbacks(connectionID: connectionID, normalizedHost: normalizedHost,
                                    port: port, isUSB: isUSB, pairingAddress: pairingAddress,
                                    receiver: receiver, assembler: assembler, decoder: decoder,
                                    channel: channel)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let screen = scene?.screen ?? UIScreen.main
        let identity = ControlChannel.ClientIdentity(
            deviceName: UIDevice.current.name,
            screenPxW: UInt16(clamping: Int(screen.nativeBounds.width)),
            screenPxH: UInt16(clamping: Int(screen.nativeBounds.height)),
            screenPtW: UInt16(clamping: Int(screen.bounds.width)),
            screenPtH: UInt16(clamping: Int(screen.bounds.height)),
            refreshHz: UInt8(clamping: screen.maximumFramesPerSecond),
            decoderCaps: Hello2.capDecodeH264 | Hello2.capDecodeHEVC |
                (isUSB && PyroWaveVideoDecoder.supported ? Hello2.capDecodePyroWave : 0),
            featureCaps: Self.featureCaps(wantsInput: wantsInput, wantsAudio: wantsAudio, isUSB: isUSB),
            deviceId: DeviceIdentity.load(),
            preferredFPS: drawing.preferredFPS(UserDefaults.standard.frameRatePreference(), maximum: screen.maximumFramesPerSecond),
            authToken: pairingToken
        )
        record(.info, "connection", "Client capabilities pixels=\(identity.screenPxW)x\(identity.screenPxH) refresh=\(identity.refreshHz) preferred_fps=\(identity.preferredFPS) decoder_caps=\(identity.decoderCaps) feature_caps=\(identity.featureCaps)")
        E2E.emit("E2E_HELLO w=\(identity.screenPxW) h=\(identity.screenPxH) refresh_hz=\(identity.refreshHz)")

        wireLinkCallbacks(connectionID: connectionID, normalizedHost: normalizedHost, port: port,
                          isUSB: isUSB, identity: identity, receiver: receiver, channel: channel)

        self.videoDecoder = decoder
        self.audioPlayer = audio
        self.frameAssembler = assembler
        self.controlChannel = channel
        self.mediaLink = receiver

        guard receiver.start(host: normalizedHost) else {
            connectionError = "Couldn't start streaming on this iPad. Try again."
            record(.error, "connection", "Receiver failed to start")
            disconnect(.receiverFailed)
            return
        }

        startStatsFlushLoop()

        armConnectTimeout(seconds: timing.connectTimeoutSeconds)
    }

    private func wireMediaCallbacks(connectionID: UUID, receiver: any MediaLink,
                                    assembler: FrameAssembler, audio: AudioPlayer?) {
        audio?.onError = { [weak self] message in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.record(.warning, "audio", message)
            }
        }
        receiver.onAudioPacket = { [weak self, weak audio] header, opus in
            guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
            audio?.receive(header: header, opus: opus)
        }

        assembler.onDiagnostic = { [weak self] message in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.record(.warning, "assembly", message)
            }
        }
        assembler.onInfo = { [weak self] message in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.record(.info, "assembly", message)
            }
        }
    }

    private func wireDecoderCallbacks(connectionID: UUID, normalizedHost: String, port: UInt16,
                                      isUSB: Bool, decoder: VideoDecoder, metrics: ReceiverMetrics) {
        decoder.onFrameDecoded = { [weak self] pixelBuffer, timestampUs, sequence in
            guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }

            guard self.frameSlot.set(pixelBuffer, sequence: sequence) else {
                Logger(subsystem: "com.eternal.monitor", category: "decode").debug("Refused frame \(sequence) output after a newer one")
                return
            }

            let ts = timestampUs
            metrics.recordDecoded(at: ControlChannel.clientNowUs(), captureUs: ts)
            let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
            let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
            Task { @MainActor in
                guard self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.debugState.decodedFrames += 1
                self.debugState.lastDecodedTimestampUs = ts
                if self.debugState.decodedFrames == 1 {
                    self.firstFrameAt = ProcessInfo.processInfo.systemUptime
                    self.record(.info, "decode", "First frame decoded successfully" + self.attemptTimings)
                    self.timeoutTask?.cancel()
                    self.noPictureStreak = NoPictureStreak()
                    self.state = .connected
                    self.streamingSince = Date()

                    self.endReconnectCycle()
                    self.transportMode = isUSB ? "USB" : "WiFi"

                    UIApplication.shared.isIdleTimerDisabled =
                        UserDefaults.standard.flag(forKey: "keepScreenAwake")
                    E2E.firstFrame(width: frameWidth, height: frameHeight, link: isUSB ? "usb" : "udp")
                    RecentConnectionStore.shared.add(host: isUSB ? (self.hostInfo?.hostName ?? "USB host") : normalizedHost,
                        port: port, isUSB: isUSB)
                    if !isUSB {
                        UserDefaults.standard.set(normalizedHost, forKey: "lastHost")
                        UserDefaults.standard.set(Int(port), forKey: "lastPort")
                    }
                }
                self.fpsCounter.tick()
                if E2E.enabled && self.debugState.decodedFrames % 60 == 0 {
                    E2E.stats(
                        decoded: self.debugState.decodedFrames,
                        width: frameWidth,
                        height: frameHeight,
                        fps: self.fpsCounter.currentFPS,
                        counters: self.frameAssembler?.counters.withLock { $0 } ?? .init(),
                        decodeDepth: self.videoDecoder?.decodeDepth ?? 0
                    )
                }
                if self.signalLost { self.signalLost = false }
                self.degradedSinceUs = nil
                if Int(self.videoSize.width) != frameWidth || Int(self.videoSize.height) != frameHeight {
                    self.videoSize = CGSize(width: frameWidth, height: frameHeight)
                }
                let uiNow = ControlChannel.clientNowUs()
                if uiNow &- self.lastLagPublishUs >= 200_000,
                   let offset = self.controlChannelBox.value?.clockSnapshot.withLock({ $0.offsetUs }),
                   let lag = Self.latencyMs(captureUs: ts, offsetUs: offset, nowUs: ControlChannel.clientNowUs()) {
                    self.lagMs = lag
                    self.lastLagPublishUs = uiNow
                }
            }
        }

        decoder.onNeedsKeyframe = { [weak self, weak controlChannelBox] in
            guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
            controlChannelBox?.value?.sendKeyframeRequest(
                streamEpoch: 0, lastCompleteSeq: 0, reason: .decodeError
            )
        }

        decoder.onRestartStream = { [weak self, weak controlChannelBox] in
            guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
            controlChannelBox?.value?.sendKeyframeRequest(streamEpoch: 0, lastCompleteSeq: 0, reason: .resume)
        }

        decoder.onStalled = { [weak self] in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }), self.state == .connected else { return }
                self.record(.warning, "decode", "Picture held 5 s without a keyframe — reconnecting")
                self.beginReconnect(.pcStoppedResponding, end: .pictureStalled)
            }
        }

        decoder.onEvent = { [weak self] message in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.record(.info, "decode", message)
            }
        }
        decoder.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else {

                    SupportDiagnostics.shared.record("error", "decode", message)
                    return
                }
                self.record(.error, "decode", message)
            }
        }
    }

    private func wireAssemblyAndMakeChannel(connectionID: UUID, receiver: any MediaLink,
                                            assembler: FrameAssembler, decoder: VideoDecoder,
                                            audio: AudioPlayer?, metrics: ReceiverMetrics) -> ControlChannel {
        assembler.onFrameAssembled = { [weak self, weak decoder, weak assembler] data, seq, captureTsUs, isKeyframe in
            guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
            let clock = controlChannelBox.value?.clockSnapshot.withLock { $0 }
            FrameTrace.log("assembled", capture: captureTsUs,
                           fields: "seq=\(seq) offset_us=\(clock?.offsetUs.map(String.init) ?? "unknown") rtt_us=\(clock?.rttUs.map(String.init) ?? "unknown")")
            self.streamCounters.recordAssembled(bytes: data.count)
            self.streamCounters.recordParsed()
            decoder?.decode(packet: FramePacket(
                seq: seq,
                timestampUs: captureTsUs,
                data: data,
                width: 0,
                height: 0,
                isKeyframe: isKeyframe,

                streamEpoch: assembler?.counters.withLock { $0.streamEpoch } ?? 0
            ))
        }

        receiver.assembler = assembler

        let channel = ControlChannel(queue: receiver.controlQueue, send: { [weak receiver] data in
            receiver?.send(data)
        })
        controlChannelBox.value = channel
        assembler.rttUs = { [weak channel] in channel?.clockSnapshot.withLock { $0.rttUs } ?? 10_000 }
        assembler.onNack = { [weak channel] nack in channel?.sendNack(nack) }
        assembler.onNeedsKeyframe = { [weak channel] epoch, seq in
            channel?.sendKeyframeRequest(streamEpoch: epoch, lastCompleteSeq: seq, reason: .gapLoss)
        }
        channel.reportProvider = { [weak assembler, weak channel, weak decoder, weak audio] in
            var report = metrics.makeReport(assembler: assembler?.counters.withLock { $0 } ?? .init(),
                decodeDepth: decoder?.decodeDepth ?? 0,
                clock: channel?.clockSnapshot.withLock { $0 } ?? .init(),
                now: ControlChannel.clientNowUs())
            let stats = audio?.stats ?? AudioStats()
            report.audioPacketsLost = UInt32(clamping: stats.lost)
            report.audioBufferMs = UInt16(clamping: stats.bufferMs)
            return report
        }
        return channel
    }

    private func wireControlChannelCallbacks(connectionID: UUID, normalizedHost: String,
                                             port: UInt16, isUSB: Bool, pairingAddress: String,
                                             receiver: any MediaLink, assembler: FrameAssembler,
                                             decoder: VideoDecoder, channel: ControlChannel) {
        channel.onHelloAttempt = { [weak self] attempt, total in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.debugState.helloAttempts = attempt
                self.record(.info, "ctrl", "HELLO2 attempt \(attempt)/\(total) to \(normalizedHost):\(port)")
            }
        }
        channel.onDiagnostic = { [weak self] message in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.record(.info, "ctrl", message)
            }
        }
        channel.onSessionEstablished = { [weak self, weak receiver, weak assembler, weak decoder] info in
            assembler?.repairEnabled = !isUSB && info.hostCaps & HelloAck.hostCapNack != 0
            decoder?.setFrameSeqContiguous(info.hostCaps & HelloAck.hostCapContiguousFrameSeq != 0)
            assembler?.framePeriodUs = 1_000_000 / UInt64(max(1, info.streamConfig.fps))
            receiver?.setAcceptedSessionId(info.sessionId)
            let acceptedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.sessionAcceptedAt = acceptedAt
                self.acceptedAddresses.insert("\(normalizedHost):\(port)")
                self.noPictureStreak.answered(by: info.hostName, pairingToken: info.authToken,
                                              at: isUSB ? nil : "\(normalizedHost):\(port)")
                self.livenessTimeoutUs = UInt64(info.livenessTimeoutMs) * 1000
                self.hostInfo = info
                if self.awaitingPairing {
                    self.awaitingPairing = false
                    self.pairingPrompt = nil
                    self.armConnectTimeout(seconds: self.timing.connectTimeoutSeconds)
                }
                if PairingStore.valid(info.authToken) {
                    do { try self.pairingStore.save(token: info.authToken, hostName: info.hostName, address: pairingAddress) }
                    catch { self.record(.warning, "pairing", "Pairing was not saved on this iPad. Pair again next time.") }
                }
                if isUSB { self.usbStatus = "USB: connected to \(info.hostName)" }
                self.hostStreamConfig = info.streamConfig
                self.record(
                    .info, "ctrl",
                    "Connected to \(info.hostName) session_id=\(info.sessionId) host_caps=\(info.hostCaps) liveness_ms=\(info.livenessTimeoutMs) config=\(info.streamConfig)"
                )
            }
        }
        channel.onRejected = { [weak self, weak channel] status in

            let mismatch = channel?.lastMismatch
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }

                if status != .busy { self.endReconnectCycle() }
                if status == .unauthorized || status == .rateLimited {
                    self.timeoutTask?.cancel()
                    self.didExtendTimeout = true
                    if status == .unauthorized {
                        do { try self.pairingStore.remove(address: pairingAddress) }
                        catch { self.record(.warning, "pairing", "Could not clear an expired pairing on this iPad.") }
                    }
                    self.awaitingPairing = true
                    let prompt = self.pairingPrompt ?? PairingSheetModel()
                    prompt.reject(status)
                    self.pairingPrompt = prompt
                    self.record(.info, "pairing", status == .rateLimited ? "Pairing rate limited for 60 seconds" : "Pairing code required")
                    return
                }
                switch status {
                case .busy:
                    self.problem = .pcBusy
                case .versionUnsupported:
                    self.versionMismatch = mismatch
                    self.connectionError = self.versionMismatch?.message ?? VersionMismatch.unknownMessage
                default:
                    self.connectionError = "Your PC turned down the connection."
                }
                self.record(.error, "ctrl", self.connectionError ?? self.problem?.title ?? "rejected")
                self.disconnect(.pcRefused)
            }
        }
        channel.onHandshakeTimeout = { [weak self, weak receiver] in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                if self.awaitingPairing {
                    self.pairingPrompt?.timedOut()
                    return
                }
                if let receiver, receiver.legacyLookingDatagrams > 0 {
                    self.endReconnectCycle()
                    self.versionMismatch = .pcLegacy
                    self.connectionError = VersionMismatch.pcLegacy.message
                    self.record(.error, "ctrl", "Legacy v1 host detected")
                    self.disconnect(.legacyPC)
                } else {
                    self.record(.warning, "ctrl", "HELLO2 handshake got no reply yet")
                }
            }
        }
        channel.onBye = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.record(.info, "ctrl", "Host BYE (\(reason))")
                let failure = ConnectionProblem.pcGoodbye(reason)
                switch reason {
                case .hostShuttingDown:

                    if self.reconnectCycleID != nil {
                        self.disconnect(.pcGoodbye)
                        self.reconnectFailure = failure
                        self.problem = failure
                    } else {
                        self.beginReconnect(.pcStoppedResponding, failure: failure, end: .pcGoodbye)
                    }
                case .userDisconnect, .superseded:

                    self.endReconnectCycle()
                    self.disconnect(.pcGoodbye)
                    self.problem = failure
                default:

                    if self.reconnectCycleID != nil {
                        self.disconnect(.pcGoodbye)
                        self.problem = failure
                    } else {
                        self.beginReconnect(.pcStoppedResponding, failure: failure, end: .pcGoodbye)
                    }
                }
            }
        }
        channel.onHeartbeat = { [weak self, weak assembler] heartbeat in
            assembler?.framePeriodUs = 1_000_000 / UInt64(max(1, heartbeat.streamConfig.fps))
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.hostStreamConfig = heartbeat.streamConfig
            }
        }
        channel.onStreamConfig = { [weak self, weak assembler] config in
            assembler?.framePeriodUs = 1_000_000 / UInt64(max(1, config.fps))
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.hostStreamConfig = config
            }
        }
    }

    private func wireLinkCallbacks(connectionID: UUID, normalizedHost: String, port: UInt16,
                                   isUSB: Bool, identity: ControlChannel.ClientIdentity,
                                   receiver: any MediaLink, channel: ControlChannel) {
        receiver.onControlDatagram = { [weak channel] data in
            channel?.handleControl(data)
        }

        receiver.onListenerReady = { [weak self, weak channel] actualPort in
            channel?.startHandshake(listenPort: actualPort, identity: identity)
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.debugState.listenerReadyPort = actualPort
                self.record(.info, isUSB ? "usb" : "udp", isUSB ? "USB tunnel ready" : "Socket ready on ephemeral port \(actualPort)")
            }
        }
        receiver.onDatagramReceived = { [streamCounters] byteCount in

            streamCounters.recordDatagram(bytes: byteCount)
        }
        receiver.onDatagramIgnored = { [weak self] message in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.record(.warning, isUSB ? "usb" : "udp", message)
            }
        }
        receiver.onConnectionEstablished = { [weak self] in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                self.record(.info, isUSB ? "usb" : "udp", "Accepted stream from selected host")
            }
        }
        receiver.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }

                let waiting = error.kind == .pathUnavailable || error.kind == .localNetworkDenied
                self.record(waiting ? .warning : .error, isUSB ? "usb" : "udp", "state=\(self.state) \(error.message)")
                let failure = ConnectionProblem.linkFailure(error, isUSB: isUSB, host: normalizedHost)

                guard self.state == .connecting else {
                    if isUSB { self.linkFailure = failure }
                    return
                }
                guard isUSB else {
                    self.disconnect(.linkFailed)
                    self.problem = failure
                    return
                }

                self.usbStatus = "USB: waiting for a cable"
                if self.stopsAfterClosingWithoutPicture() { return }
                self.beginReconnect(.cableUnplugged, failure: failure)
            }
        }

        receiver.onClosed = { [weak self] in
            Task { @MainActor in
                guard let self, self.currentAttempt.withLock({ $0 == connectionID }) else { return }
                if isUSB { self.usbStatus = "USB: waiting for a cable" }
                if self.stopsAfterClosingWithoutPicture() { return }

                self.beginReconnect(.cableUnplugged, failure: self.linkFailure)
            }
        }
    }
}
