import SwiftUI
import MetalKit
import CoreVideo
import os

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
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        if let layer = view.layer as? CAMetalLayer {
            layer.maximumDrawableCount = 3
            layer.presentsWithTransaction = false
        }
        view.backgroundColor = UIColor(red: 0.024, green: 0.027, blue: 0.031, alpha: 1)
        view.clearColor = MTLClearColor(red: 0.024, green: 0.027, blue: 0.031, alpha: 1)

        let renderer = MetalRenderer(device: device, view: view)
        renderer.pictureFit = settings.pictureFit
        context.coordinator.renderer = renderer
        context.coordinator.frameSlot = connectionManager.frameSlot
        context.coordinator.attach(view: view)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer,
              renderer.pictureFit != settings.pictureFit else { return }
        renderer.pictureFit = settings.pictureFit
        DispatchQueue.main.async { [weak uiView] in uiView?.draw() }
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: MetalRenderer?
        var frameSlot: FrameSlot?

        private weak var view: MTKView?
        private var memoryWarning: NSObjectProtocol?
        private let drawPending = OSAllocatedUnfairLock(initialState: false)

        func attach(view: MTKView) {
            self.view = view
            view.delegate = self
            frameSlot?.onFrameStored = { [weak self] in self?.scheduleDraw() }
            memoryWarning = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.renderer?.releaseCachedFrame()
            }
        }

        func detach() {
            view = nil
            if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
            memoryWarning = nil
        }

        private func scheduleDraw() {
            let first = drawPending.withLock { pending -> Bool in
                if pending { return false }
                pending = true
                return true
            }
            guard first else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.drawPending.withLock { $0 = false }
                self.view?.draw()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            DispatchQueue.main.async { [weak view] in view?.draw() }
        }

        func draw(in view: MTKView) {
            guard let renderer else { return }
            renderer.draw(in: view, pixelBuffer: frameSlot?.take())
        }
    }
}

// MARK: - Metal Renderer

private struct FrameTextures {
    let luma: MTLTexture
    let chroma: MTLTexture
    let cvLuma: CVMetalTexture
    let cvChroma: CVMetalTexture
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    let matrixIndex: UInt32
}

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
    var _padding: UInt32 = 0
}

final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private(set) var textureCache: CVMetalTextureCache?
    private var currentFrame: FrameTextures?
    var pictureFit: PictureFit = .fit
    #if DEBUG
    var completedHandlerGate: (() -> Void)?
    #endif

    init(device: MTLDevice, view: MTKView) {
        self.device = device

        guard let queue = PyroWaveMetal.queue ?? device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        self.commandQueue = queue

        #if SWIFT_PACKAGE
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

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
    }

    deinit { currentFrame = nil }

    func draw(in view: MTKView, pixelBuffer: CVPixelBuffer?) {
        var drewNewFrame = false
        if let pixelBuffer, let frame = makeFrameTextures(from: pixelBuffer) {
            currentFrame = frame
            drewNewFrame = true
            if let cache = textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
        }

        guard let frame = currentFrame,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
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

        let inFlight = InFlightFrame(frame, cache: textureCache)
        if drewNewFrame,
           let capture = CVBufferCopyAttachment(frame.pixelBuffer, FrameTrace.key, nil) as? NSNumber {
            let captureUs = capture.uint64Value
            FrameTrace.log("render_submit", capture: captureUs,
                           fields: "callback_media_seconds=\(CACurrentMediaTime())")
            commandBuffer.addCompletedHandler { completed in
                FrameTrace.log("render_gpu_done", capture: captureUs,
                               fields: "gpu_start_seconds=\(completed.gpuStartTime) gpu_end_seconds=\(completed.gpuEndTime) callback_media_seconds=\(CACurrentMediaTime())")
            }
            drawable.addPresentedHandler { presented in
                FrameTrace.log("presented", capture: captureUs,
                               fields: "presented_seconds=\(presented.presentedTime) callback_media_seconds=\(CACurrentMediaTime())")
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

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    var holdsFrame: Bool { currentFrame != nil }

    func releaseCachedFrame() {
        currentFrame = nil
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    static func aspectFitScale(video: CGSize, drawable: CGSize) -> SIMD2<Float> {
        guard video.width > 0, video.height > 0, drawable.width > 0, drawable.height > 0 else {
            return SIMD2<Float>(1, 1)
        }
        let videoAspect = video.width / video.height
        let drawableAspect = drawable.width / drawable.height
        if videoAspect > drawableAspect {
            return SIMD2<Float>(1, Float(drawableAspect / videoAspect))
        } else {
            return SIMD2<Float>(Float(videoAspect / drawableAspect), 1)
        }
    }

    static func aspectFillScale(video: CGSize, drawable: CGSize) -> SIMD2<Float> {
        guard video.width > 0, video.height > 0, drawable.width > 0, drawable.height > 0 else {
            return SIMD2<Float>(1, 1)
        }
        let videoAspect = video.width / video.height
        let drawableAspect = drawable.width / drawable.height
        if videoAspect > drawableAspect {
            return SIMD2<Float>(Float(videoAspect / drawableAspect), 1)
        } else {
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
            matrixIndex = 0
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
