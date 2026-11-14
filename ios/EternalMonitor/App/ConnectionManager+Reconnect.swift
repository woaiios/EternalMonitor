import Foundation

@MainActor extension ConnectionManager {
    func beginReconnect(_ reason: ConnectionProblem.LostReason, failure: ConnectionProblem? = nil,
                                end: AttemptEnd? = nil) {
        let target = lastTarget
        let auto = UserDefaults.standard.flag(forKey: "autoReconnect")

        let logged: String
        switch reason {
        case .pcStoppedResponding: logged = "host stopped responding"
        case .cableUnplugged: logged = failure == nil ? "USB disconnected" : "USB link failed"
        case .usbTurnedOff: logged = "USB connections turned off"
        }
        record(.warning, "ctrl", "Connection lost (\(logged))")
        switch reason {
        case .pcStoppedResponding: disconnect(end ?? .pcStoppedResponding)
        case .cableUnplugged: disconnect(end ?? (failure == nil ? .cableUnplugged : .usbLinkFailed))
        case .usbTurnedOff: disconnect(end ?? .usbTurnedOff)
        }
        guard auto, let target else {
            problem = (failure ?? .lost(reason)).withoutReconnecting
            return
        }
        startReconnectCycle(to: target, failure: failure)
    }

    func startReconnectCycle(to target: (host: String, port: UInt16), failure: ConnectionProblem? = nil) {
        endReconnectCycle()
        let cycleID = UUID()
        reconnectCycleID = cycleID
        reconnectFailure = failure
        reconnectTask = Task { @MainActor [weak self] in
            for attempt in 1...6 {
                guard let self, self.reconnectCycleID == cycleID else { return }
                self.reconnectAttempt = attempt
                self.problem = .reconnecting(attempt: attempt, of: 6)
                try? await Task.sleep(for: .seconds(self.timing.reconnectBackoffSeconds(attempt)))
                guard self.reconnectCycleID == cycleID else { return }
                self.startAttempt(.udp(host: target.host, port: target.port))

                try? await Task.sleep(for: .seconds(self.timing.connectTimeoutSeconds + self.timing.reconnectGraceSeconds))
                while self.reconnectCycleID == cycleID, self.state == .connecting {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard self.reconnectCycleID == cycleID else { return }
                self.reconnectFailure = ConnectionProblem.kept(self.reconnectFailure, after: self.problem)
            }
            guard let self, self.reconnectCycleID == cycleID else { return }
            let kept = self.reconnectFailure
            self.endReconnectCycle()
            self.problem = (kept ?? .reconnectFailed).afterTheCycle
        }
    }

    func endReconnectCycle() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectCycleID = nil
        reconnectFailure = nil
        reconnectAttempt = 0
    }

    func armConnectTimeout(seconds: Double) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled && self.state == .connecting {
                let debug = self.debugState
                let handshakeDone = self.hostInfo != nil
                let isUSB = self.transportMode == "USB"
                let level = debug.timeoutLevel(handshakeDone: handshakeDone,
                                               answeredHereBefore: self.acceptedAddresses.contains("\(debug.host):\(debug.port)"))
                self.record(level, "timeout", debug.timeoutSummary(handshakeDone: handshakeDone) + self.attemptTimings)

                if handshakeDone { self.noPictureStreak.endedWithoutPicture() }
                self.problem = self.noPictureStreak.shown(.timeout(
                    listenerReady: debug.listenerReadyPort != nil, helloAttempts: debug.helloAttempts,
                    handshakeDone: handshakeDone, datagramsReceived: debug.datagramsReceived,
                    isUSB: isUSB, host: debug.host), at: isUSB ? nil : "\(debug.host):\(debug.port)")

                self.disconnect(.connectTimeout)
                if handshakeDone && self.noPictureStreak.stopsReconnecting { self.stopAutomaticAttempts(isUSB: isUSB) }
            }
        }
    }

    func stopsAfterClosingWithoutPicture() -> Bool {
        guard state == .connecting, hostInfo != nil else { return false }
        noPictureStreak.endedWithoutPicture()
        guard noPictureStreak.stopsReconnecting else { return false }
        let isUSB = transportMode == "USB"
        record(.warning, "ctrl", "Connection closed by the PC before a picture" + attemptTimings)
        disconnect(.closedBeforePicture)
        problem = .noPicture
        stopAutomaticAttempts(isUSB: isUSB)
        return true
    }

    func stopAutomaticAttempts(isUSB: Bool) {
        record(.warning, "connection", "Stopped reconnecting after \(noPictureStreak.timeouts) no-picture timeouts in a row")
        endReconnectCycle()
        if isUSB {
            usbPaused = true
            usbStoppedForNoPicture = true
            usbListener?.stop()
            usbListener = nil
            usbStatus = "USB: disconnected"
        }
    }
}
