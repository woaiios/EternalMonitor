import SwiftUI
import Network
import PyroWaveNative

// Local-only USB service. The host reaches this port through Apple's paired
// usbmux connection; no results or screen content leave the cable.
final class BenchService: @unchecked Sendable {
    static let shared = BenchService()
    private let network = DispatchQueue(label: "pyrowave.bench.usb")
    private let worker = DispatchQueue(label: "pyrowave.bench.gpu", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var state = "ready"
    private var results: [[String: Any]] = []
    private var running = false

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["state": state, "results": results]
    }
    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 9878)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.network ?? .global())
                self?.readCommand(connection, buffered: Data())
            }
            listener.stateUpdateHandler = { [weak self] status in
                if case .failed(let error) = status { self?.setState("USB listener: \(error)") }
            }
            self.listener = listener
            listener.start(queue: network)
        } catch { setState("USB listener: \(error)") }
    }
    private func setState(_ text: String) { lock.lock(); state = text; lock.unlock() }
    private func reply(_ connection: NWConnection, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func readCommand(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffered; buffer.append(data ?? Data())
            guard buffer.count <= 256 else { connection.cancel(); return }
            guard buffer.last == 10 else {
                if done { connection.cancel() } else { self.readCommand(connection, buffered: buffer) }
                return
            }
            let fields = String(decoding: buffer, as: UTF8.self).split(whereSeparator: { $0.isWhitespace })
            if fields == ["STATUS"] { self.reply(connection, self.snapshot()) }
            else if fields.count == 6, fields[0] == "RUN",
                    let width = Int32(fields[1]), let height = Int32(fields[2]), let fps = Int32(fields[3]),
                    let frames = Int32(fields[4]), let mbps = Int32(fields[5]) {
                self.reply(connection, ["accepted": self.run(width: width, height: height, fps: fps, frames: frames, mbps: mbps)])
            } else if fields.count == 2, fields[0] == "VALIDATE", let count = Int(fields[1]),
                      (20...4 * 1024 * 1024).contains(count) {
                connection.send(content: Data("READY\n".utf8), completion: .contentProcessed { error in
                    if error == nil { self.readFixture(connection, remaining: count, buffered: Data()) }
                    else { connection.cancel() }
                })
            } else if fields.count == 2, fields[0] == "SINK", let count = Int(fields[1]),
                      (1...64 * 1024 * 1024).contains(count) {
                connection.send(content: Data("READY\n".utf8), completion: .contentProcessed { error in
                    if error == nil { self.sink(connection, remaining: count, total: count, start: ProcessInfo.processInfo.systemUptime) }
                    else { connection.cancel() }
                })
            } else { self.reply(connection, ["error": "Unknown or invalid command"]) }
        }
    }
    private func readFixture(_ connection: NWConnection, remaining: Int, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(256 * 1024, remaining)) { [weak self] data, _, done, error in
            guard let self, error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            var buffer = buffered; buffer.append(data)
            let rest = remaining - data.count
            if rest == 0 {
                self.worker.async {
                    let pointer = buffer.withUnsafeBytes { em_pyrowave_check_frame($0.baseAddress, $0.count) }
                    guard let pointer else { self.reply(connection, ["error": "Cannot allocate fixture report"]); return }
                    let data = Data(String(cString: pointer).utf8)
                    em_pyrowave_free(pointer)
                    let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["error": "Invalid fixture report"]
                    self.reply(connection, result)
                }
            } else if !done { self.readFixture(connection, remaining: rest, buffered: buffer) }
            else { connection.cancel() }
        }
    }
    private func sink(_ connection: NWConnection, remaining: Int, total: Int, start: Double) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(256 * 1024, remaining)) { [weak self] data, _, done, error in
            guard let self, error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            let rest = remaining - data.count
            if rest == 0 {
                let seconds = ProcessInfo.processInfo.systemUptime - start
                self.reply(connection, ["bytes": total, "receiver_seconds": seconds,
                                        "receiver_mbps": Double(total) * 8 / seconds / 1_000_000])
            } else if !done { self.sink(connection, remaining: rest, total: total, start: start) }
            else { connection.cancel() }
        }
    }
    @discardableResult
    func run(width: Int32, height: Int32, fps: Int32, frames: Int32, mbps: Int32) -> Bool {
        lock.lock()
        guard !running else { lock.unlock(); return false }
        running = true; state = "running \(width)×\(height) @ \(fps), \(mbps) Mbps"; lock.unlock()
        worker.async {
            let pointer = em_pyrowave_benchmark(width, height, fps, frames, mbps)
            let result: [String: Any]
            if let pointer {
                let data = Data(String(cString: pointer).utf8)
                em_pyrowave_free(pointer)
                result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["error": "Invalid native report"]
            } else { result = ["error": "Cannot allocate native report"] }
            self.lock.lock()
            self.results.append(result)
            self.state = result["error"] == nil ? "complete" : "failed"
            self.running = false
            self.lock.unlock()
        }
        return true
    }
}

@main
struct PyroWaveBenchApp: App {
    @State private var status = "Starting USB benchmark service"
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("PyroWave USB benchmark").font(.title)
                    Text("Synthetic frames only. Measures GPU decoding separately from USB throughput. Keep this app in the foreground during testing.")
                    Button("Run 1080p 120 Hz") {
                        BenchService.shared.run(width: 1920, height: 1080, fps: 120, frames: 300, mbps: 340)
                    }
                    Button("Run native 2388 × 1668, 120 Hz") {
                        BenchService.shared.run(width: 2388, height: 1668, fps: 120, frames: 300, mbps: 436)
                    }
                    Text(status).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }.padding(32)
            }
            .task {
                UIApplication.shared.isIdleTimerDisabled = true
                BenchService.shared.start()
                while !Task.isCancelled {
                    if let data = try? JSONSerialization.data(withJSONObject: BenchService.shared.snapshot(), options: [.prettyPrinted, .sortedKeys]) {
                        status = String(decoding: data, as: UTF8.self)
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }
}
