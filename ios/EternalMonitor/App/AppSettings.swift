import Foundation
import Combine

final class AppSettings: ObservableObject {
    @Published var playPCaudio: Bool {
        didSet { UserDefaults.standard.set(playPCaudio, forKey: "playPCaudio") }
    }
    @Published var allowUSB: Bool {
        didSet { UserDefaults.standard.set(allowUSB, forKey: "allowUSB") }
    }
    @Published var showHUD: Bool {
        didSet { UserDefaults.standard.set(showHUD, forKey: "showHUD") }
    }

    @Published var keepScreenAwake: Bool {
        didSet { UserDefaults.standard.set(keepScreenAwake, forKey: "keepScreenAwake") }
    }

    @Published var autoResumeOnForeground: Bool {
        didSet { UserDefaults.standard.set(autoResumeOnForeground, forKey: "autoResumeOnForeground") }
    }

    @Published var controlPC: Bool {
        didSet { UserDefaults.standard.set(controlPC, forKey: "controlPC") }
    }
    @Published var drawingMode: Bool {
        didSet { UserDefaults.standard.set(drawingMode, forKey: "drawingMode") }
    }
    @Published var commandAsControl: Bool {
        didSet { UserDefaults.standard.set(commandAsControl, forKey: "commandAsControl") }
    }
    @Published var autoReconnect: Bool {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }
    @Published var targetFPS: Int {
        didSet { UserDefaults.standard.set(targetFPS, forKey: "targetFPS") }
    }

    @Published var pictureFit: PictureFit {
        didSet { UserDefaults.standard.set(pictureFit.rawValue, forKey: "pictureFit") }
    }

    @Published var lastHost: String {
        didSet { UserDefaults.standard.set(lastHost, forKey: "lastHost") }
    }
    @Published var lastPort: UInt16 {
        didSet { UserDefaults.standard.set(Int(lastPort), forKey: "lastPort") }
    }

    init() {
        let defaults = UserDefaults.standard
        self.playPCaudio = defaults.flag(forKey: "playPCaudio")
        self.allowUSB = defaults.flag(forKey: "allowUSB")
        self.showHUD = defaults.flag(forKey: "showHUD")
        self.keepScreenAwake = defaults.flag(forKey: "keepScreenAwake")
        self.autoResumeOnForeground =
            defaults.flag(forKey: "autoResumeOnForeground")
        self.controlPC = defaults.flag(forKey: "controlPC")
        self.drawingMode = defaults.bool(forKey: "drawingMode")
        self.commandAsControl = defaults.flag(forKey: "commandAsControl")
        self.autoReconnect = defaults.flag(forKey: "autoReconnect")
        self.targetFPS = defaults.frameRatePreference()
        self.pictureFit = PictureFit(rawValue: defaults.string(forKey: "pictureFit") ?? "") ?? .fit
        self.lastHost = defaults.object(forKey: "lastHost") as? String ?? ""
        let port = defaults.integer(forKey: "lastPort")
        self.lastPort = UInt16(clamping: port)
    }
}
