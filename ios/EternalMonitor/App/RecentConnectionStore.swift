import Foundation
import Combine

struct RecentConnection: Codable, Identifiable {
    var id: String { "\(isUSB ? "usb" : "udp")|\(host):\(port)" }
    let host: String
    let port: UInt16
    let lastUsed: Date
    let isUSB: Bool
}

extension RecentConnection {

    static func unlisted(_ recents: [RecentConnection], discovered: [DiscoveredHost]) -> [RecentConnection] {
        recents.filter { recent in
            recent.isUSB || !discovered.contains { $0.address == recent.host && $0.port == recent.port }
        }
    }
}

final class RecentConnectionStore: ObservableObject {
    static let shared = RecentConnectionStore()

    @Published var connections: [RecentConnection] = []

    private let key = "recentConnections"

    private init() {
        load()
    }

    func add(host: String, port: UInt16, isUSB: Bool) {
        connections.removeAll { $0.host == host && $0.port == port && $0.isUSB == isUSB }
        connections.insert(
            RecentConnection(host: host, port: port, lastUsed: Date(), isUSB: isUSB),
            at: 0
        )
        if connections.count > 10 { connections = Array(connections.prefix(10)) }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentConnection].self, from: data) else { return }
        connections = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
