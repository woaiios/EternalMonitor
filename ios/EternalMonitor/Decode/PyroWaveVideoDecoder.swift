import Foundation
import CoreVideo
#if SWIFT_PACKAGE
import PyroWaveNative
#endif

/// A serial, independent-frame Metal decoder. The output is NV12 in an
/// IOSurface, so FrameSlot and the existing Metal renderer stay unchanged.
final class PyroWaveVideoDecoder {
    static var supported: Bool { em_pyrowave_is_supported() != 0 }
    static func recognizes(_ data: Data) -> Bool { data.starts(with: [0x45, 0x50, 0x57, 0x31]) }
    private var handle: UnsafeMutableRawPointer?
    private var dimensions = (0, 0)
    struct Failure: Error, CustomStringConvertible { let description: String }
    deinit { if let handle { em_pyrowave_stream_decoder_destroy(handle) } }

    func decode(_ data: Data) throws -> CVPixelBuffer {
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
                em_pyrowave_stream_decode(handle, $0.baseAddress, $0.count, message.baseAddress, message.count)
            }
        }
        guard let pixel else { throw Failure(description: String(cString: error)) }
        return Unmanaged<CVPixelBuffer>.fromOpaque(pixel).takeRetainedValue()
    }
}
