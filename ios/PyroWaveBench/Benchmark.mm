#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#include "include/PyroWaveBench.h"
#include "vendor/pyrowave_metal.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
void check(pyrowave_result result, const char *operation) {
    if (result != PYROWAVE_SUCCESS)
        throw std::runtime_error(std::string(operation) + ": " + pyrowave_result_to_string(result));
}
struct Codec {
    pyrowave_device device = nullptr;
    pyrowave_encoder encoder = nullptr;
    pyrowave_decoder decoder = nullptr;
    ~Codec() {
        if (decoder) pyrowave_decoder_destroy(decoder);
        if (encoder) pyrowave_encoder_destroy(encoder);
        if (device) pyrowave_device_destroy(device);
    }
};
NSDictionary *distribution(std::vector<double> values) {
    std::sort(values.begin(), values.end());
    auto percentile = [&](double p) { return values[size_t(std::ceil(p * values.size())) - 1]; };
    return @{ @"p50_ms": @(percentile(0.5)), @"p95_ms": @(percentile(0.95)),
              @"p99_ms": @(percentile(0.99)), @"max_ms": @(values.back()) };
}
char *json(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (!data) return strdup("{\"error\":\"JSON serialization failed\"}");
    char *text = static_cast<char *>(malloc(data.length + 1));
    if (!text) return nullptr;
    memcpy(text, data.bytes, data.length);
    text[data.length] = 0;
    return text;
}
}

char *em_pyrowave_benchmark(int width, int height, int fps, int frames, int mbps) {
    @autoreleasepool {
        try {
            if (width < 64 || height < 64 || width > 4096 || height > 4096 ||
                (width & 1) || (height & 1) || fps < 30 || fps > 120 ||
                frames < 30 || frames > 1000 || mbps < 50 || mbps > 1000)
                throw std::runtime_error("Invalid benchmark dimensions, rate or sample count");
            id<MTLDevice> mtl = MTLCreateSystemDefaultDevice();
            if (!mtl || !pyrowave_device_is_supported((__bridge void *)mtl))
                throw std::runtime_error("PyroWave needs Apple7 or later and a 32-wide SIMD group");
            id<MTLCommandQueue> queue = [mtl newCommandQueue];
            if (!queue) throw std::runtime_error("Cannot create Metal command queue");
            Codec codec;
            auto cold = Clock::now();
            pyrowave_device_create_info device_info = {};
            device_info.mtl_device = (__bridge void *)mtl;
            check(pyrowave_device_create(&device_info, &codec.device), "device create");
            pyrowave_encoder_create_info enc = {codec.device, width, height, PYROWAVE_CHROMA_SUBSAMPLING_420};
            pyrowave_decoder_create_info dec = {codec.device, width, height, PYROWAVE_CHROMA_SUBSAMPLING_420};
            check(pyrowave_encoder_create(&enc, &codec.encoder), "encoder create");
            check(pyrowave_decoder_create(&dec, &codec.decoder), "decoder create");
            const double cold_ms = elapsed(cold);
            const size_t pixels = size_t(width) * height;
            std::vector<uint8_t> y(pixels), cb(pixels / 4), cr(pixels / 4);
            for (int row = 0; row < height; ++row)
                for (int col = 0; col < width; ++col)
                    y[size_t(row) * width + col] = uint8_t(32 + ((col / 4 + row / 4) % 160) +
                                                         (((col / 32) ^ (row / 32)) & 1) * 32);
            std::fill(cb.begin(), cb.end(), 112);
            std::fill(cr.begin(), cr.end(), 144);
            pyrowave_cpu_buffer input = {};
            input.width = width; input.height = height; input.format = PYROWAVE_CPU_BUFFER_FORMAT_YUV420P;
            input.data[0] = y.data(); input.data[1] = cb.data(); input.data[2] = cr.data();
            input.row_stride_in_bytes[0] = width;
            input.row_stride_in_bytes[1] = input.row_stride_in_bytes[2] = width / 2;
            input.plane_size_in_bytes[0] = y.size();
            input.plane_size_in_bytes[1] = cb.size(); input.plane_size_in_bytes[2] = cr.size();
            const size_t frame_budget = size_t(mbps) * 1000000 / 8 / fps;
            pyrowave_rate_control rate = {frame_budget};
            id<MTLTexture> planes[3];
            pyrowave_gpu_buffers output = {};
            for (int plane = 0; plane < 3; ++plane) {
                auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                    width:plane == 0 ? width : width / 2 height:plane == 0 ? height : height / 2 mipmapped:NO];
                descriptor.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
                descriptor.storageMode = MTLStorageModePrivate;
                planes[plane] = [mtl newTextureWithDescriptor:descriptor];
                if (!planes[plane]) throw std::runtime_error("Cannot allocate decode plane");
                output.planes[plane] = (__bridge void *)planes[plane];
            }
            std::vector<uint8_t> bitstream(frame_budget);
            std::vector<double> encode_ms, parse_ms, gpu_ms, decode_ms;
            size_t total_bytes = 0;
            const int thermal_start = int(NSProcessInfo.processInfo.thermalState);
            // Warm up all pipelines; shader compilation and first dispatch are reported separately.
            for (int index = -15; index < frames; ++index) {
                @autoreleasepool {
                    auto start = Clock::now();
                    check(pyrowave_encoder_encode_cpu(codec.encoder, &input, &rate), "encode");
                    size_t count = 0;
                    check(pyrowave_encoder_compute_num_packets(codec.encoder, frame_budget, &count), "packet count");
                    std::vector<pyrowave_packet> packets(count);
                    check(pyrowave_encoder_packetize(codec.encoder, packets.data(), frame_budget, &count,
                                                     bitstream.data(), bitstream.size()), "packetize");
                    const double encode_duration = elapsed(start);
                    start = Clock::now();
                    pyrowave_decoder_clear(codec.decoder);
                    size_t bytes = 0;
                    for (size_t p = 0; p < count; ++p) {
                        if (packets[p].offset > bitstream.size() || packets[p].size > bitstream.size() - packets[p].offset)
                            throw std::runtime_error("Packet exceeds bitstream allocation");
                        check(pyrowave_decoder_push_packet(codec.decoder, bitstream.data() + packets[p].offset,
                                                            packets[p].size), "parse packet");
                        bytes += packets[p].size;
                    }
                    if (!pyrowave_decoder_decode_is_ready(codec.decoder, false))
                        throw std::runtime_error("Encoded frame did not reassemble");
                    const double parse_duration = elapsed(start);
                    id<MTLCommandBuffer> command = [queue commandBuffer];
                    if (!command) throw std::runtime_error("Cannot create command buffer");
                    check(pyrowave_decoder_decode_gpu_buffer(codec.decoder, (__bridge void *)command, &output), "decode");
                    [command commit];
                    [command waitUntilCompleted];
                    if (command.status != MTLCommandBufferStatusCompleted)
                        throw std::runtime_error(command.error.localizedDescription.UTF8String ?: "GPU decode failed");
                    const double wall = elapsed(start);
                    const double gpu = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
                    if (index >= 0) {
                        encode_ms.push_back(encode_duration); parse_ms.push_back(parse_duration);
                        gpu_ms.push_back(gpu); decode_ms.push_back(wall); total_bytes += bytes;
                    }
                }
            }
            // Read back only once, outside the timing loop, to detect blank or corrupt output.
            const size_t stride = (size_t(width) + 255) & ~size_t(255);
            id<MTLBuffer> readback = [mtl newBufferWithLength:stride * height options:MTLResourceStorageModeShared];
            if (!readback) throw std::runtime_error("Cannot allocate output verification buffer");
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
            [blit copyFromTexture:planes[0] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(width, height, 1) toBuffer:readback destinationOffset:0
           destinationBytesPerRow:stride destinationBytesPerImage:stride * height];
            [blit endEncoding]; [command commit]; [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted)
                throw std::runtime_error("Output verification GPU copy failed");
            double mae = 0;
            const uint8_t *decoded = static_cast<const uint8_t *>(readback.contents);
            for (int row = 0; row < height; ++row)
                for (int col = 0; col < width; ++col)
                    mae += std::abs(int(decoded[size_t(row) * stride + col]) - int(y[size_t(row) * width + col]));
            mae /= double(pixels);
            return json(@{ @"schema": @1, @"device": mtl.name, @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
                @"width": @(width), @"height": @(height), @"fps_target": @(fps), @"frames": @(frames),
                @"target_mbps": @(mbps), @"frame_budget_bytes": @(frame_budget),
                @"actual_payload_mbps": @(double(total_bytes) / frames * fps * 8 / 1000000),
                @"cold_pipeline_ms": @(cold_ms), @"metal_encode_and_packetize": distribution(encode_ms),
                @"cpu_parse": distribution(parse_ms), @"decode_gpu": distribution(gpu_ms),
                @"decode_parse_submit_wait": distribution(decode_ms), @"luma_mae_8bit": @(mae),
                @"thermal_start": @(thermal_start), @"thermal_end": @(int(NSProcessInfo.processInfo.thermalState)),
                @"scope": @"Synthetic SDR 4:2:0 Metal round trip, excludes USB, rendering and display scanout" });
        } catch (const std::exception &error) {
            return json(@{ @"error": [NSString stringWithUTF8String:error.what()] });
        }
    }
}
void em_pyrowave_free(char *result) { free(result); }

char *em_pyrowave_check_frame(const void *data, size_t size) {
    @autoreleasepool {
        try {
            if (!data || size < 20 || size > 4 * 1024 * 1024)
                throw std::runtime_error("Invalid fixture size");
            const uint8_t *bytes = static_cast<const uint8_t *>(data);
            auto u16 = [&](size_t at) { return uint32_t(bytes[at]) | (uint32_t(bytes[at + 1]) << 8); };
            auto u32 = [&](size_t at) { return u16(at) | (u16(at + 2) << 16); };
            if (memcmp(bytes, "EPW1", 4) || u32(8) != 1)
                throw std::runtime_error("Unsupported fixture format or colorspace");
            int width = int(u16(4)), height = int(u16(6));
            uint32_t packets = u32(12);
            if (width < 64 || height < 64 || width > 4096 || height > 4096 ||
                (width & 1) || (height & 1) || packets == 0 || packets > 4096)
                throw std::runtime_error("Invalid fixture dimensions or packet count");
            id<MTLDevice> mtl = MTLCreateSystemDefaultDevice();
            if (!mtl || !pyrowave_device_is_supported((__bridge void *)mtl))
                throw std::runtime_error("Unsupported Metal device");
            Codec codec;
            check(pyrowave_create_default_device(&codec.device), "device create");
            pyrowave_decoder_create_info info = {codec.device, width, height, PYROWAVE_CHROMA_SUBSAMPLING_420};
            check(pyrowave_decoder_create(&info, &codec.decoder), "decoder create");
            size_t offset = 16;
            for (uint32_t p = 0; p < packets; ++p) {
                if (size - offset < 4) throw std::runtime_error("Truncated packet size");
                size_t count = u32(offset); offset += 4;
                if (count == 0 || count > size - offset) throw std::runtime_error("Truncated packet");
                check(pyrowave_decoder_push_packet(codec.decoder, bytes + offset, count), "parse Vulkan packet");
                offset += count;
            }
            if (offset != size || !pyrowave_decoder_decode_is_ready(codec.decoder, false))
                throw std::runtime_error("Incomplete Vulkan frame or trailing data");
            id<MTLTexture> planes[3];
            pyrowave_gpu_buffers output = {};
            for (int plane = 0; plane < 3; ++plane) {
                auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                    width:plane == 0 ? width : width / 2 height:plane == 0 ? height : height / 2 mipmapped:NO];
                desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
                desc.storageMode = MTLStorageModePrivate;
                planes[plane] = [mtl newTextureWithDescriptor:desc];
                if (!planes[plane]) throw std::runtime_error("Cannot allocate decode plane");
                output.planes[plane] = (__bridge void *)planes[plane];
            }
            id<MTLCommandQueue> queue = [mtl newCommandQueue];
            id<MTLCommandBuffer> command = [queue commandBuffer];
            if (!command) throw std::runtime_error("Cannot allocate decode command");
            check(pyrowave_decoder_decode_gpu_buffer(codec.decoder, (__bridge void *)command, &output), "decode Vulkan frame");
            [command commit]; [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted) throw std::runtime_error("GPU decode failed");
            double gpu_ms = (command.GPUEndTime - command.GPUStartTime) * 1000;
            // Validate every luma pixel against the deterministic Windows fixture.
            size_t stride = (size_t(width) + 255) & ~size_t(255);
            id<MTLBuffer> buffer = [mtl newBufferWithLength:stride * height options:MTLResourceStorageModeShared];
            command = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
            if (!buffer || !blit) throw std::runtime_error("Cannot allocate validation readback");
            [blit copyFromTexture:planes[0] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(width, height, 1) toBuffer:buffer destinationOffset:0
                destinationBytesPerRow:stride destinationBytesPerImage:stride * height];
            [blit endEncoding]; [command commit]; [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted) throw std::runtime_error("Validation readback failed");
            const uint8_t *decoded = static_cast<const uint8_t *>(buffer.contents);
            double mae = 0;
            for (int row = 0; row < height; ++row)
                for (int col = 0; col < width; ++col) {
                    int expected = 32 + ((col / 4 + row / 4) % 160) + (((col / 32) ^ (row / 32)) & 1) * 32;
                    mae += std::abs(int(decoded[size_t(row) * stride + col]) - expected);
                }
            mae /= double(width) * height;
            // Exercise the production GPU-only NV12 packing path too.
            char stream_error[512] = {};
            void *stream = em_pyrowave_stream_decoder_create(width, height, stream_error, sizeof(stream_error));
            if (!stream) throw std::runtime_error(stream_error);
            CVPixelBufferRef pixel = static_cast<CVPixelBufferRef>(em_pyrowave_stream_decode(stream, data, size, stream_error, sizeof(stream_error)));
            em_pyrowave_stream_decoder_destroy(stream);
            if (!pixel) throw std::runtime_error(stream_error);
            if (CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
                CFRelease(pixel); throw std::runtime_error("Cannot inspect packed NV12 output");
            }
            const auto *packed = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixel, 0));
            const auto *uv = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixel, 1));
            const size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0);
            const size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1);
            double packed_mae = 0, chroma_mae = 0;
            for (int row = 0; row < height; ++row)
                for (int col = 0; col < width; ++col) {
                    int expected = 32 + ((col / 4 + row / 4) % 160) + (((col / 32) ^ (row / 32)) & 1) * 32;
                    packed_mae += std::abs(int(packed[size_t(row) * y_stride + col]) - expected);
                }
            for (int row = 0; row < height / 2; ++row)
                for (int col = 0; col < width; ++col)
                    chroma_mae += std::abs(int(uv[size_t(row) * uv_stride + col]) - (col % 2 == 0 ? 112 : 144));
            packed_mae /= double(width) * height;
            chroma_mae /= double(width) * height / 2;
            CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly); CFRelease(pixel);
            return json(@{ @"width": @(width), @"height": @(height), @"packets": @(packets),
                @"encoded_bytes": @(size), @"decode_gpu_ms": @(gpu_ms), @"luma_mae_8bit": @(mae),
                @"nv12_luma_mae_8bit": @(packed_mae), @"nv12_chroma_mae_8bit": @(chroma_mae),
                @"pattern_check_passed": @(mae < 5.0 && packed_mae < 5.0 && chroma_mae < 5.0),
                @"scope": @"Windows Vulkan to iPad Metal synthetic fixture, including production NV12 output" });
        } catch (const std::exception &error) {
            return json(@{ @"error": [NSString stringWithUTF8String:error.what()] });
        }
    }
}
