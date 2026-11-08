import UIKit
import Metal
import QuartzCore

/// A separate UIKit + Metal executable: no streaming, decoder, SwiftUI or
/// networking. Every frame clears a native-resolution drawable to a changing
/// muted color. Both GPU and presentation times use the Mach media clock.
@main
final class BenchApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = true
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = BenchController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

private final class BenchView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metal: CAMetalLayer { layer as! CAMetalLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        metal.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metal.drawableSize = CGSize(width: bounds.width * metal.contentsScale,
                                    height: bounds.height * metal.contentsScale)
    }
}

private final class BenchLog {
    static let shared = BenchLog()
    private let queue = DispatchQueue(label: "native-present.log", qos: .utility)
    private let file: FileHandle
    private init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("native-present.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try! FileHandle(forWritingTo: url)
    }
    func write(_ values: [String: Any]) {
        queue.async { [self] in
            guard var bytes = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
            bytes.append(10)
            try? file.write(contentsOf: bytes)
        }
    }
}

private final class BenchController: UIViewController, CAMetalDisplayLinkDelegate {
    private var bench: BenchView { view as! BenchView }
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var metalLink: CAMetalDisplayLink?
    private var caLink: CADisplayLink?
    private var nextID = 0
    private var started = false
    private var startTime = 0.0
    private var finished = false
    private let mode = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--mode=") }?
        .split(separator: "=").last.map(String.init) ?? "cadirect"
    private let duration = Double(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--seconds=") }?
        .split(separator: "=").last ?? "30") ?? 30
    private let fps = Int(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--fps=") }?
        .split(separator: "=").last ?? "120") ?? 120
    private let drawables = Int(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--drawables=") }?
        .split(separator: "=").last ?? "2") == 3 ? 3 : 2
    private let lead = min(5000, max(500, Double(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--lead-us=") }?
        .split(separator: "=").last ?? "2500") ?? 2500)) / 1_000_000

    override func loadView() { view = BenchView() }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        bench.metal.device = device
        bench.metal.pixelFormat = .bgra8Unorm
        bench.metal.framebufferOnly = true
        bench.metal.maximumDrawableCount = drawables
        bench.metal.presentsWithTransaction = false
        bench.layoutIfNeeded()
        startTime = CACurrentMediaTime()
        BenchLog.shared.write(["event": "metadata", "mode": mode, "fps_requested": fps,
            "start": startTime, "duration": duration, "device": device.name, "drawables": drawables,
            "lead_us": lead * 1_000_000,
            "os": UIDevice.current.systemVersion, "maximum_fps": UIScreen.main.maximumFramesPerSecond,
            "width": bench.metal.drawableSize.width, "height": bench.metal.drawableSize.height,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue])
        let range = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        if mode.hasPrefix("metal") {
            let link = CAMetalDisplayLink(metalLayer: bench.metal)
            link.delegate = self
            link.preferredFrameLatency = 1
            link.preferredFrameRateRange = range
            link.add(to: .main, forMode: .common)
            metalLink = link
        } else {
            let link = CADisplayLink(target: self, selector: #selector(caTick(_:)))
            link.preferredFrameRateRange = range
            link.add(to: .main, forMode: .common)
            caLink = link
        }
    }

    private func expired() -> Bool {
        if finished { return true }
        if CACurrentMediaTime() - startTime < duration { return false }
        finished = true
        metalLink?.invalidate(); caLink?.invalidate()
        BenchLog.shared.write(["event": "finished", "time": CACurrentMediaTime(),
                               "submitted": nextID, "thermal": ProcessInfo.processInfo.thermalState.rawValue])
        return true
    }
    @objc private func caTick(_ link: CADisplayLink) {
        guard !expired() else { return }
        let callback = CACurrentMediaTime()
        let target = link.targetTimestamp
        if mode == "calate" {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, target - lead - callback)) { [weak self] in
                self?.render(drawable: nil, callback: callback, deadline: target, target: target, metal: false)
            }
        } else {
            render(drawable: nil, callback: callback, deadline: target, target: target, metal: false)
        }
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard !expired() else { return }
        let callback = CACurrentMediaTime()
        if mode == "metallate" {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, update.targetTimestamp - lead - callback)) { [weak self, update] in
                self?.render(drawable: update.drawable, callback: callback,
                             deadline: update.targetTimestamp, target: update.targetPresentationTimestamp, metal: true)
            }
        } else {
            render(drawable: update.drawable, callback: callback,
                   deadline: update.targetTimestamp, target: update.targetPresentationTimestamp, metal: true)
        }
    }
    private func render(drawable supplied: CAMetalDrawable?, callback: Double,
                        deadline: Double, target: Double, metal: Bool) {
        let begin = CACurrentMediaTime()
        guard let drawable = supplied ?? bench.metal.nextDrawable() else { return }
        let acquired = CACurrentMediaTime()
        guard let command = queue.makeCommandBuffer() else { return }
        nextID += 1; let id = nextID
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // Slow, continuous changes rather than rapid flashing.
        let phase = (begin - startTime) * 0.6
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.2 + 0.08 * sin(phase), green: 0.2 + 0.08 * cos(phase), blue: 0.25, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        command.addCompletedHandler { completed in
            BenchLog.shared.write(["event": "gpu", "id": id, "start": completed.gpuStartTime,
                "end": completed.gpuEndTime, "status": completed.status.rawValue,
                "callback": CACurrentMediaTime()])
        }
        drawable.addPresentedHandler { presented in
            BenchLog.shared.write(["event": "presented", "id": id,
                "time": presented.presentedTime, "callback": CACurrentMediaTime()])
        }
        if metal {
            command.commit(); drawable.present()
        } else {
            command.present(drawable); command.commit()
        }
        BenchLog.shared.write(["event": "submit", "id": id, "callback": callback,
            "begin": begin, "acquired": acquired, "submit_end": CACurrentMediaTime(),
            "deadline": deadline, "target": target])
    }
}
