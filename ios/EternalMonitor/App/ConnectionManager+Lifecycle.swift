import Foundation
import UIKit

@MainActor extension ConnectionManager {
    func refreshUSBAvailability() {
        let allowed = UserDefaults.standard.flag(forKey: "allowUSB")
        guard allowed, isForeground, !usbPaused else {
            usbListener?.stop()
            usbListener = nil
            usbStatus = allowed ? "USB: disconnected" : "USB: off"
            if !allowed, mediaLink?.isUSB == true { beginReconnect(.usbTurnedOff) }
            return
        }
        guard usbListener == nil else { return }
        let listener = USBListener(port: E2E.usbListenPort)
        usbListener = listener
        listener.onState = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.usbListener === listener else { return }
                if self.mediaLink?.isUSB == true { return }
                switch state {
                case .listening: self.usbStatus = "USB: waiting for a cable"
                case .failed(let message): self.usbStatus = "USB: unavailable"; self.record(.warning, "usb", message)
                case .stopped: self.usbStatus = "USB: disconnected"
                }
            }
        }
        listener.onAccepted = { [weak self, weak listener] link in
            Task { @MainActor in
                guard let self, let listener, self.usbListener === listener else { link.stop(); return }
                self.acceptUSBLink(link)
            }
        }
        listener.start()
    }

    func acceptUSBLink(_ link: FramedLink) {
        guard isForeground, !usbPaused, mediaLink?.isUSB != true else { link.stop(); return }
        endReconnectCycle()
        if state != .disconnected {
            E2E.linkSwitch(from: "udp", to: "usb")
            disconnect(.superseded)
        }
        connect(target: .usb(link))
    }

    func resumeUSBConnections() {
        noPictureStreak.restartCount()
        usbStoppedForNoPicture = false
        usbPaused = false
        refreshUSBAvailability()
    }

    func prepareForBackground() {
        guard state != .disconnected, backgroundGoodbyeTask == .invalid else { return }
        backgroundGoodbyeTask = UIApplication.shared.beginBackgroundTask(withName: "EternalMonitor goodbye") { [weak self] in
            self?.endBackgroundGoodbye()
        }
        E2E.emit("E2E_BACKGROUND_PREPARED task=\(backgroundGoodbyeTask.rawValue)")
    }

    func endBackgroundGoodbye() {
        let task = backgroundGoodbyeTask
        backgroundGoodbyeTask = .invalid
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        E2E.emit("E2E_BACKGROUND_ENDED task=\(task.rawValue)")
    }

    func handleAppBackgrounded() {

        prepareForBackground()
        isForeground = false
        usbListener?.stop()
        usbListener = nil

        let cycleOutcome = reconnectCycleID == nil ? nil : reconnectFailure ?? .reconnectFailed
        endReconnectCycle()
        if cycleOutcome != nil { resumeOnForeground = true }
        guard state != .disconnected else {
            if let cycleOutcome { problem = cycleOutcome }
            endBackgroundGoodbye()
            return
        }
        resumeOnForeground = true
        record(.info, "ctrl", "App backgrounded — sending BYE and disconnecting")
        let goodbye = backgroundGoodbyeTask
        disconnect(.appBackground)
        if let cycleOutcome { problem = cycleOutcome }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.backgroundGoodbyeTask == goodbye else { return }
            self.endBackgroundGoodbye()
        }
    }

    func handleAppForegrounded() {
        endBackgroundGoodbye()
        isForeground = true
        usbPaused = usbStoppedForNoPicture
        refreshUSBAvailability()
        guard resumeOnForeground else { return }
        resumeOnForeground = false
        guard UserDefaults.standard.flag(forKey: "autoResumeOnForeground"),
              state == .disconnected,
              let target = lastTarget
        else { return }
        record(.info, "ctrl", "App foregrounded — resuming the interrupted session")
        connect(host: target.host, port: target.port)
    }
}
