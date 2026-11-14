import Foundation
import os
import UIKit

@MainActor extension ConnectionManager {
    func startStatsFlushLoop() {
        statsFlushTask?.cancel()
        statsFlushTask = Task { @MainActor [weak self] in
            var lastSummary = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                let snapshot = self.streamCounters.drain()

                if snapshot.datagrams > 0 || snapshot.assembled > 0 {
                    let firstDatagrams =
                        self.debugState.datagramsReceived == 0 && snapshot.datagrams > 0
                    let firstAssembled =
                        self.debugState.assembledFrames == 0 && snapshot.assembled > 0
                    self.debugState.datagramsReceived += snapshot.datagrams
                    self.debugState.datagramBytesReceived += snapshot.datagramBytes
                    self.debugState.assembledFrames += snapshot.assembled
                    self.debugState.assembledFrameBytes += snapshot.assembledBytes
                    self.debugState.decodePackets += snapshot.parsed

                    if firstDatagrams {
                        let linkName = self.mediaLink?.isUSB == true ? "USB" : "UDP"
                        self.record(
                            .info, linkName.lowercased(),
                            "\(linkName) data flowing (\(snapshot.datagrams) datagrams, \(snapshot.datagramBytes) bytes in first batch)"
                        )

                        if self.state == .connecting && !self.didExtendTimeout {
                            self.didExtendTimeout = true
                            self.armConnectTimeout(seconds: self.timing.connectTimeoutSeconds)
                        }
                    }
                    if firstAssembled {
                        self.record(.info, "assembly", "First frame payload assembled (\(snapshot.assembledBytes) bytes)")
                    }
                }

                self.refreshStatsAndWatchdog()
                if ProcessInfo.processInfo.systemUptime - lastSummary >= 10 {
                    lastSummary = ProcessInfo.processInfo.systemUptime
                    self.recordStreamSummary(reason: "periodic")
                }
            }
        }
    }

    func refreshStatsAndWatchdog() {
        guard let channel = controlChannel else { return }
        audioStats = audioPlayer?.stats ?? AudioStats()
        fps = fpsCounter.currentFPS

        var next = StreamStats()
        next.decodeFps = fps
        let clock = channel.clockSnapshot.withLock { $0 }
        if let rtt = clock.rttUs { next.rttMs = Double(rtt) / 1000.0 }
        if clock.offsetUs != nil { next.e2eMs = lagMs }
        if let counters = frameAssembler?.counters.withLock({ $0 }) {

            if counters.fragsReceived < prevCounters.fragsReceived
                || counters.fragsLost < prevCounters.fragsLost {
                prevCounters = FrameAssembler.Counters()
            }
            let deltaReceived = counters.fragsReceived - prevCounters.fragsReceived
            let deltaLost = counters.fragsLost - prevCounters.fragsLost
            prevCounters = counters
            let total = deltaReceived + deltaLost
            next.lossPercent = total == 0 ? 0 : Double(deltaLost) * 100.0 / Double(total)
            next.framesDropped = counters.framesDropped
            next.fragsRepaired = counters.fragsRepaired
            next.jitterMs = Double(counters.jitterUs) / 1000
        }
        next.bars = StreamStats.bars(lossPercent: next.lossPercent, rttMs: next.rttMs)
        stats = next
        let restoring = state == .connected
            && (videoDecoder?.keyframeWaitUs ?? 0) >= VideoDecoder.showRestoringAfterUs
        if restoring != pictureRestoring { pictureRestoring = restoring }

        guard state == .connected else { return }
        let lastHeartbeat = channel.lastHeartbeatAtUs.withLock { $0 }
        guard lastHeartbeat > 0 else { return }
        let sinceUs = ControlChannel.clientNowUs() &- lastHeartbeat
        if sinceUs > livenessTimeoutUs {
            if !signalLost {
                signalLost = true
                #if DEBUG
                UITestProbe.shared.signalLost()
                #endif
                degradedSinceUs = ControlChannel.clientNowUs()
                record(.warning, "ctrl", "Host heartbeats stopped — signal lost")
            } else if let since = degradedSinceUs,
                      ControlChannel.clientNowUs() &- since > 5_000_000 {

                beginReconnect(.pcStoppedResponding)
            }
        } else if signalLost {
            signalLost = false
            degradedSinceUs = nil
            record(.info, "ctrl", "Signal recovered")
        }
    }

    var attemptTimings: String {
        let now = ProcessInfo.processInfo.systemUptime
        var text = ""
        if let session = hostInfo?.sessionId { text += " session_id=\(session)" }
        text += " ms_since_start=\(Int((now - attemptStartedAt) * 1000))"
        if let accepted = sessionAcceptedAt { text += " ms_since_accept=\(Int((now - accepted) * 1000))" }
        return text
    }

    func recordSummary(_ end: AttemptEnd) {
        let summary = summary(end)
        if summary.nonce != 0 {
            guard !summarizedNonces.contains(summary.nonce) else { return }
            summarizedNonces.append(summary.nonce)
            if summarizedNonces.count > 32 { summarizedNonces.removeFirst() }
        }
        record(.info, "summary", summary.line)
    }

    func summary(_ end: AttemptEnd) -> SessionSummary {
        let now = ProcessInfo.processInfo.systemUptime
        return SessionSummary(
            end: end, isUSB: mediaLink?.isUSB ?? (transportMode == "USB"), sessionId: hostInfo?.sessionId,
            nonce: controlChannel?.helloNonce ?? 0, awaitingPairing: awaitingPairing,
            datagramsReceived: debugState.datagramsReceived, firstFrame: firstFrameAt.map { $0 - summaryStartedAt },
            duration: now - summaryStartedAt)
    }

    nonisolated static func latencyMs(captureUs: UInt64, offsetUs: Int64, nowUs: UInt64) -> Double? {
        guard captureUs > 0 else { return nil }
        let (captureClient, captureOverflow) = Int64(bitPattern: captureUs).subtractingReportingOverflow(offsetUs)
        let (latencyUs, latencyOverflow) = Int64(bitPattern: nowUs).subtractingReportingOverflow(captureClient)
        guard !captureOverflow, !latencyOverflow else { return nil }
        return latencyUs > 0 ? Double(latencyUs) / 1000.0 : 0
    }

    func recordStreamSummary(reason: String) {
        let counters = frameAssembler?.counters.withLock { $0 } ?? .init()
        let clock = controlChannel?.clockSnapshot.withLock { $0 }
        SupportDiagnostics.shared.record("info", "stream", "reason=\(reason) state=\(state) transport=\(transportMode) session_id=\(hostInfo?.sessionId ?? 0) decoded=\(debugState.decodedFrames) assembled=\(debugState.assembledFrames) datagrams=\(debugState.datagramsReceived) bytes=\(debugState.datagramBytesReceived) fps=\(fps) size=\(videoSize) depth=\(videoDecoder?.decodeDepth ?? 0) dropped=\(counters.framesDropped) mismatched_count_frags=\(frameAssembler?.mismatchedCountFragments.withLock { $0 } ?? 0) repaired=\(counters.fragsRepaired) nacks=\(counters.nacksSent) jitter_us=\(counters.jitterUs) rtt_us=\(clock?.rttUs ?? 0) e2e_ms=\(lagMs) audio=\(audioStats) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    }

    func record(_ level: DiagnosticLevel, _ category: String, _ message: String) {
        SupportDiagnostics.shared.record(String(describing: level), category, message)
        E2E.emit("E2E_DIAGNOSTIC category=\(category) message=\(message)")
        diagnostics.append(DiagnosticEntry(level: level, category: category, message: message))
        if diagnostics.count > 80 {
            diagnostics.removeFirst(diagnostics.count - 80)
        }
        Logger(subsystem: "com.eternal.monitor", category: category)
            .log(level: level.osLogType, "\(message, privacy: .public)")
    }
}
