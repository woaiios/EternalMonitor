import SwiftUI
import MetalKit
import CoreVideo
import os

/// SwiftUI wrapper for MTKView that renders decoded video frames via Metal.
///
/// Draw-on-demand: the view is paused and redraws only when a new decoded
/// frame lands in the `FrameSlot` (or the drawable size changes) instead of
/// free-running at 120 Hz re-encoding the same texture.
struct MetalView: UIViewRepresentable {
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var settings: AppSettings

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Redraw only when told to — new frame or size change.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        if let layer = view.layer as? CAMetalLayer {
            layer.maximumDrawableCount = 2
            layer.presentsWithTransaction = false
        }
        // On-demand drawing ignores this, so it only matters if the view is
        // ever unpaused: never cap the panel (ProMotion runs at 120 Hz).
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        view.backgroundColor = UIColor(red: 0.024, green: 0.027, blue: 0.031, alpha: 1) // Theme.void
        view.clearColor = MTLClearColor(red: 0.024, green: 0.027, blue: 0.031, alpha: 1)

        let renderer = MetalRenderer(device: device, view: view)
        renderer.pictureFit = settings.pictureFit
        context.coordinator.renderer = renderer
        context.coordinator.frameSlot = connectionManager.frameSlot
        context.coordinator.attach(view: view)
        view.delegate = context.coordinator

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Draw-on-demand makes preferredFramesPerSecond irrelevant: presentation
        // cadence follows decoded frames (naturally capped by the stream fps).
        // Fit or Fill changed: redraw the held frame now, not at the next one.
        if let renderer = context.coordinator.renderer, renderer.pictureFit != settings.pictureFit {
            renderer.pictureFit = settings.pictureFit
            renderer.invalidatePicture()
            uiView.setNeedsDisplay()
        }
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate, CAMetalDisplayLinkDelegate {
        var renderer: MetalRenderer?
        /// Direct reference to the shared FrameSlot — avoids crossing @MainActor boundary on the render thread.
        var frameSlot: FrameSlot?

        private weak var view: MTKView?
        private var memoryWarning: NSObjectProtocol?
        private var displayLink: CAMetalDisplayLink?
        private var cadenceLink: CADisplayLink?
        /// Coalesces redraw requests: many decoded frames between two main-loop
        /// turns become one setNeedsDisplay.
        private let redrawPending = OSAllocatedUnfairLock(initialState: false)

        func attach(view: MTKView) {
            self.view = view
            renderer?.onNeedsDraw = { [weak self] in self?.scheduleRedraw() }
            if ProcessInfo.processInfo.arguments.contains("--manual-metal") {
                let cadence = CADisplayLink(target: self, selector: #selector(cadenceTick(_:)))
                cadence.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
                cadence.add(to: .main, forMode: .common)
                cadenceLink = cadence
            } else {
                let displayLink = CAMetalDisplayLink(metalLayer: view.layer as! CAMetalLayer)
                displayLink.delegate = self
                displayLink.preferredFrameLatency = 1
                displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
                displayLink.add(to: .main, forMode: .common)
                self.displayLink = displayLink
                view.enableSetNeedsDisplay = false
            }
            frameSlot?.onFrameStored = { [weak self] in
                self?.scheduleRedraw()
            }
            // The next decoded frame redraws within a frame period, or the
            // PC's idle keepalive; the screen keeps showing the last one.
            memoryWarning = NotificationCenter.default.addObserver(
                // UIKit posts this on the main thread, where draws run.
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.renderer?.releaseCachedFrame()
            }
        }

        func detach() {
            displayLink?.invalidate()
            cadenceLink?.invalidate()
            cadenceLink = nil
            displayLink = nil
            renderer?.onNeedsDraw = nil
            frameSlot?.onFrameStored = nil
            view = nil
            if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
            memoryWarning = nil
        }

        /// Called from the VideoToolbox callback thread on every stored frame.
        private func scheduleRedraw() {
            let shouldSchedule = redrawPending.withLock { pending -> Bool in
                if pending { return false }
                pending = true
                return true
            }
            guard shouldSchedule else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.redrawPending.withLock { $0 = false }
                // Draw the latest picture immediately on the main queue;
                // UIKit invalidation otherwise waits for another display pass.
                if self.displayLink == nil { self.view?.draw() }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Redraw the held frame with the letterbox recomputed for the new size.
            renderer?.invalidatePicture()
            view.setNeedsDisplay()
        }

        private var tickNumber = 0
        private let lateMicroseconds: Double = {
            let spec = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--metal-late-us=") }
            return min(7500, max(-2000, spec.flatMap { Double($0.split(separator: "=").last ?? "") } ?? -400))
        }()
        @objc private func cadenceTick(_ link: CADisplayLink) {
            tickNumber += 1
            if tickNumber % 120 == 0 { FrameTrace.displayPeriod(link.targetTimestamp - link.timestamp) }
        }
        func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
            tickNumber += 1
            if tickNumber % 120 == 0 { FrameTrace.displayPeriod(update.targetPresentationTimestamp - update.targetTimestamp) }
            // The callback can arrive a full CPU frame before its deadline.
            // Latch the newest decoded picture late instead of aging it here.
            let delay = max(0, update.targetTimestamp + lateMicroseconds / 1_000_000 - CACurrentMediaTime())
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, update] in
                self?.renderUpdate(update)
            }
        }

        private func renderUpdate(_ update: CAMetalDisplayLink.Update) {
            guard let renderer, let view else { return }
            renderer.draw(in: view, pixelBuffer: frameSlot?.take(),
                          providedDrawable: update.drawable, targetTime: update.targetPresentationTimestamp,
                          deadlineTime: update.targetTimestamp)
        }

        func draw(in view: MTKView) {
            guard let renderer else { return }
            let pixelBuffer = frameSlot?.take()
            renderer.draw(in: view, pixelBuffer: pixelBuffer)
        }
    }
}

// MARK: - Metal Renderer

/// Everything one draw needs, bundled so the pixel buffer and its texture
/// wrappers provably outlive GPU sampling: the command buffer's completion
/// handler retains this until the pass finishes. (Retaining only the raw
/// MTLTexture let VideoToolbox recycle the backing IOSurface mid-draw —
/// tearing and green frames.)
private struct FrameTextures {
    let luma: MTLTexture
    let chroma: MTLTexture
    let cvLuma: CVMetalTexture
    let cvChroma: CVMetalTexture
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    /// 0 = BT.709, 1 = BT.601 — matches the shader's DisplayUniforms.
    let matrixIndex: UInt32
}

/// One draw's textures, held by its command buffer's completion handler
/// together with the texture cache that made them. A CVMetalTexture doesn't
/// keep its cache alive, and CoreVideo crashes if the cache is destroyed
/// while a completion handler is still releasing its textures, as when the
/// picture closes with GPU work outstanding. So the textures go first.
private final class InFlightFrame {
    private var frame: FrameTextures?
    private let cache: CVMetalTextureCache?

    init(_ frame: FrameTextures, cache: CVMetalTextureCache?) {
        self.frame = frame
        self.cache = cache
    }

    deinit { frame = nil }
}

private struct DisplayUniforms {
    var scale: SIMD2<Float>
    var matrixIndex: UInt32
    // std140-ish padding so the struct matches the Metal-side layout.
    var _padding: UInt32 = 0
}

final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private(set) var textureCache: CVMetalTextureCache?
    private var currentFrame: FrameTextures?
    private var presentationPending = false
    private var needsPresentation = false
    var onNeedsDraw: (() -> Void)?
    func invalidatePicture() { needsPresentation = true }
    /// Read on the main thread, where the paused MTKView draws.
    var pictureFit: PictureFit = .fit
    #if DEBUG
    /// Tests: runs at the start of each later draw's completion handler, on
    /// Metal's thread, to hold the handler past the renderer's teardown.
    var completedHandlerGate: (() -> Void)?
    #endif

    init(device: MTLDevice, view: MTKView) {
        self.device = device

        guard let queue = PyroWaveMetal.queue ?? device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        self.commandQueue = queue

        // Load shaders
        #if SWIFT_PACKAGE
        // xtool builds on Windows/WSL; compile the same bundled MSL source
        // at runtime instead of requiring Xcode's offline metal compiler.
        let library = Bundle.main.url(forResource: "Shaders", withExtension: "metal")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { try? device.makeLibrary(source: $0, options: nil) }
        #else
        let library = device.makeDefaultLibrary()
        #endif
        guard let library,
              let vertexFunc = library.makeFunction(name: "fullscreen_vertex"),
              let fragmentFunc = library.makeFunction(name: "display_fragment") else {
            fatalError("Failed to load Metal shaders")
        }

        // Pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }

        // Texture cache for zero-copy CVPixelBuffer → MTLTexture
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
    }

    // The held frame's textures go before the cache that made them.
    deinit { currentFrame = nil }

    func draw(in view: MTKView, pixelBuffer: CVPixelBuffer?, providedDrawable: CAMetalDrawable? = nil, targetTime: CFTimeInterval? = nil, deadlineTime: CFTimeInterval? = nil) {
        if let pixelBuffer, let frame = makeFrameTextures(from: pixelBuffer) {
            currentFrame = frame
            needsPresentation = true
            // Let the cache recycle textures released by completed draws.
            if let cache = textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
        }

        // If no frame yet, skip the draw (paused view keeps its clear color).
        guard let frame = currentFrame else { return }
        // Keep replacing the latest frame while one drawable awaits display.
        // Never block the main thread in nextDrawable behind older pictures.
        guard needsPresentation, providedDrawable != nil || !presentationPending else { return }

        let drawable = providedDrawable ?? view.currentDrawable
        let pass: MTLRenderPassDescriptor?
        if let providedDrawable {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = providedDrawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = view.clearColor
            pass = descriptor
        } else { pass = view.currentRenderPassDescriptor }
        guard let drawable,
              let passDescriptor = pass,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        var uniforms = DisplayUniforms(
            scale: Self.scale(
                pictureFit,
                video: CGSize(width: frame.width, height: frame.height),
                drawable: view.drawableSize
            ),
            matrixIndex: frame.matrixIndex
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame.luma, index: 0)
        encoder.setFragmentTexture(frame.chroma, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Keep the pixel buffer + texture wrappers alive until the GPU is done
        // sampling them, and their cache alive until they are released.
        let inFlight = InFlightFrame(frame, cache: textureCache)
        if let capture = CVBufferCopyAttachment(frame.pixelBuffer, FrameTrace.key, nil) as? NSNumber {
            let captureUs = capture.uint64Value
            FrameTrace.log("render_submit", capture: captureUs,
                           fields: "deadline_seconds=\(deadlineTime ?? 0) target_seconds=\(targetTime ?? 0) callback_media_seconds=\(CACurrentMediaTime())")
            commandBuffer.addCompletedHandler { completed in
                FrameTrace.log("render_gpu_done", capture: captureUs,
                               fields: "gpu_start_seconds=\(completed.gpuStartTime) gpu_end_seconds=\(completed.gpuEndTime) callback_media_seconds=\(CACurrentMediaTime())")
            }
            drawable.addPresentedHandler { presented in
                FrameTrace.log("presented", capture: captureUs,
                               fields: "presented_seconds=\(presented.presentedTime) callback_media_seconds=\(CACurrentMediaTime())")
            }
        }
        needsPresentation = false
        presentationPending = true
        drawable.addPresentedHandler { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentationPending = false
                if self.needsPresentation { self.onNeedsDraw?() }
            }
        }
        #if DEBUG
        let gate = completedHandlerGate
        #endif
        commandBuffer.addCompletedHandler { _ in
            #if DEBUG
            gate?()
            #endif
            _ = inFlight
        }

        if providedDrawable != nil {
            // CAMetalDisplayLink owns the deadline. Timed present methods
            // are forbidden for these drawables; commit then present now.
            commandBuffer.commit()
            drawable.present()
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    /// Whether a decoded frame is held for redraws (resize, rotation).
    var holdsFrame: Bool { currentFrame != nil }

    /// Memory warning: drop the held frame and the texture cache's recycled
    /// textures. At 1440p and up each held frame is several megabytes.
    func releaseCachedFrame() {
        currentFrame = nil
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    /// Scale that fits `video` inside `drawable` preserving aspect ratio
    /// (letterbox/pillarbox). Pure and unit-tested.
    static func aspectFitScale(video: CGSize, drawable: CGSize) -> SIMD2<Float> {
        guard video.width > 0, video.height > 0, drawable.width > 0, drawable.height > 0 else {
            return SIMD2<Float>(1, 1)
        }
        let videoAspect = video.width / video.height
        let drawableAspect = drawable.width / drawable.height
        if videoAspect > drawableAspect {
            // Video is wider: full width, shrink height (letterbox).
            return SIMD2<Float>(1, Float(drawableAspect / videoAspect))
        } else {
            // Video is taller: full height, shrink width (pillarbox).
            return SIMD2<Float>(Float(videoAspect / drawableAspect), 1)
        }
    }

    /// Scale that covers `drawable` with `video` preserving aspect ratio: one
    /// axis grows past 1 and the rasterizer clips the quad, trimming those
    /// edges. Pure and unit-tested against `ContentRectMapper`.
    static func aspectFillScale(video: CGSize, drawable: CGSize) -> SIMD2<Float> {
        guard video.width > 0, video.height > 0, drawable.width > 0, drawable.height > 0 else {
            return SIMD2<Float>(1, 1)
        }
        let videoAspect = video.width / video.height
        let drawableAspect = drawable.width / drawable.height
        if videoAspect > drawableAspect {
            // Video is wider: full height, grow width (sides trimmed).
            return SIMD2<Float>(Float(videoAspect / drawableAspect), 1)
        } else {
            // Video is taller: full width, grow height (top/bottom trimmed).
            return SIMD2<Float>(1, Float(drawableAspect / videoAspect))
        }
    }

    static func scale(_ fit: PictureFit, video: CGSize, drawable: CGSize) -> SIMD2<Float> {
        switch fit {
        case .fit: return aspectFitScale(video: video, drawable: drawable)
        case .fill: return aspectFillScale(video: video, drawable: drawable)
        }
    }

    private func makeFrameTextures(from pixelBuffer: CVPixelBuffer) -> FrameTextures? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }

        var cvLuma: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &cvLuma
        ) == kCVReturnSuccess, let cvLuma, let luma = CVMetalTextureGetTexture(cvLuma) else {
            return nil
        }

        var cvChroma: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .rg8Unorm, width / 2, height / 2, 1, &cvChroma
        ) == kCVReturnSuccess, let cvChroma, let chroma = CVMetalTextureGetTexture(cvChroma) else {
            return nil
        }

        let matrixIndex: UInt32
        if let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil),
           CFGetTypeID(attachment) == CFStringGetTypeID(),
           (attachment as! CFString) == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
            matrixIndex = 1
        } else {
            matrixIndex = 0 // BT.709 default
        }

        return FrameTextures(
            luma: luma,
            chroma: chroma,
            cvLuma: cvLuma,
            cvChroma: cvChroma,
            pixelBuffer: pixelBuffer,
            width: width,
            height: height,
            matrixIndex: matrixIndex
        )
    }
}
