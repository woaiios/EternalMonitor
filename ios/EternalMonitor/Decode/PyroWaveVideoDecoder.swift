import Foundation
import CoreVideo
import Metal
import QuartzCore
#if SWIFT_PACKAGE
import PyroWaveNative
#endif

enum PyroWaveMetal {
    static let queue: MTLCommandQueue? = {
        guard let pointer = em_pyrowave_copy_metal_command_queue() else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? MTLCommandQueue
    }()
    static let commandKey = "dev.eternalmonitor.pyro.command" as CFString
}

/// A serial, independent-frame Metal decoder. The output is NV12 in an
/// IOSurface, so FrameSlot and the existing Metal renderer stay unchanged.
final class PyroWaveVideoDecoder {
    static var supported: Bool { em_pyrowave_is_supported() != 0 }
    static func recognizes(_ data: Data) -> Bool { data.starts(with: [0x45, 0x50, 0x57, 0x31]) }
    private var handle: UnsafeMutableRawPointer?
    private var dimensions = (0, 0)
    struct Failure: Error, CustomStringConvertible { let description: String }
    deinit { if let handle { em_pyrowave_stream_decoder_destroy(handle) } }

    func decode(_ data: Data, captureUs: UInt64 = 0) throws -> CVPixelBuffer {
        guard data.count >= 20, data.count <= 4 * 1024 * 1024, Self.recognizes(data) else {
            throw Failure(description: "Invalid PyroWave frame envelope")
        }
        let header = Array(data.prefix(16))
        let width = Int(header[4]) | (Int(header[5]) << 8)
        let height = Int(header[6]) | (Int(header[7]) << 8)
        guard (64...4096).contains(width), (64...4096).contains(height), width % 2 == 0, height % 2 == 0 else {
            throw Failure(description: "Unsupported PyroWave frame dimensions")
        }
        var error = [CChar](repeating: 0, count: 512)
        if handle == nil || dimensions != (width, height) {
            if let handle { em_pyrowave_stream_decoder_destroy(handle) }
            handle = error.withUnsafeMutableBufferPointer {
                em_pyrowave_stream_decoder_create(Int32(width), Int32(height), $0.baseAddress, $0.count)
            }
            guard handle != nil else { throw Failure(description: String(cString: error)) }
            dimensions = (width, height)
        }
        let pixel = error.withUnsafeMutableBufferPointer { message in
            data.withUnsafeBytes {
                em_pyrowave_stream_decode_deferred(handle, $0.baseAddress, $0.count, message.baseAddress, message.count)
            }
        }
        guard let pixel else { throw Failure(description: String(cString: error)) }
        let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixel).takeRetainedValue()
        guard let command = CVBufferCopyAttachment(buffer, PyroWaveMetal.commandKey, nil) as? MTLCommandBuffer else {
            throw Failure(description: "Missing decode submission")
        }
        if FrameTrace.sampled(captureUs) {
            command.addCompletedHandler { completed in
                FrameTrace.log("decode_gpu_done", capture: captureUs,
                               fields: "gpu_start_seconds=\(completed.gpuStartTime) gpu_end_seconds=\(completed.gpuEndTime) callback_media_seconds=\(CACurrentMediaTime())")
            }
        }
        command.commit()
        CVBufferRemoveAttachment(buffer, PyroWaveMetal.commandKey)
        return buffer
    }
}
