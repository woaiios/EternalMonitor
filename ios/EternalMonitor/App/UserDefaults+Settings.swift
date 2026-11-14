import Foundation

extension UserDefaults {

    func flag(forKey key: String) -> Bool {
        object(forKey: key) == nil ? true : bool(forKey: key)
    }

    func frameRatePreference() -> Int {

        let fps = integer(forKey: "targetFPS")
        return [30, 60, 120].contains(fps) ? fps : 120
    }
}
