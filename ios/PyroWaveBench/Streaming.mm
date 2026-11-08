#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#include "include/PyroWaveBench.h"
#include "vendor/pyrowave_metal.h"
#include <memory>
#include <stdexcept>
#include <cstdio>
#include <cstring>

namespace {
id<MTLCommandQueue> shared_queue() {
    static id<MTLCommandQueue> value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [MTLCreateSystemDefaultDevice() newCommandQueue]; });
    return value;
}
void require(bool ok, const char *text) { if (!ok) throw std::runtime_error(text); }
void checked(pyrowave_result code, const char *text) { require(code == PYROWAVE_SUCCESS, text); }
void failure(char *target, size_t capacity, const char *text) {
    if (target && capacity) snprintf(target, capacity, "%s", text);
}
struct StreamDecoder {
    int width = 0, height = 0;
    pyrowave_device device = nullptr;
    pyrowave_decoder decoder = nullptr;
    id<MTLDevice> metal;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pack;
    id<MTLTexture> planes[3];
    CVPixelBufferPoolRef pool = nullptr;
    CVMetalTextureCacheRef cache = nullptr;
    ~StreamDecoder() {
        // Drain only at teardown. Decode and render are ordered on one queue.
        id<MTLCommandBuffer> drain = [queue commandBuffer];
        [drain commit]; [drain waitUntilCompleted];
        if (decoder) pyrowave_decoder_destroy(decoder);
        if (device) pyrowave_device_destroy(device);
        if (pool) CFRelease(pool);
        if (cache) CFRelease(cache);
    }
    void initialize(int w, int h) {
        require(w >= 64 && h >= 64 && w <= 4096 && h <= 4096 && !(w & 1) && !(h & 1), "Invalid PyroWave dimensions");
        width = w; height = h;
        metal = MTLCreateSystemDefaultDevice();
        require(metal && pyrowave_device_is_supported((__bridge void *)metal), "Unsupported PyroWave Metal device");
        queue = shared_queue();
        require(queue != nil, "Cannot create PyroWave command queue");
        pyrowave_device_create_info create = {};
        create.mtl_device = (__bridge void *)metal;
        checked(pyrowave_device_create(&create, &device), "Cannot create PyroWave Metal device");
        pyrowave_decoder_create_info info = {device, w, h, PYROWAVE_CHROMA_SUBSAMPLING_420};
        checked(pyrowave_decoder_create(&info, &decoder), "Cannot create PyroWave decoder");
        for (int p = 0; p < 3; ++p) {
            auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                width:p == 0 ? w : w / 2 height:p == 0 ? h : h / 2 mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            desc.storageMode = MTLStorageModePrivate;
            planes[p] = [metal newTextureWithDescriptor:desc];
            require(planes[p] != nil, "Cannot allocate PyroWave decode planes");
        }
        // GPU-only planar -> NV12 packing lets the existing renderer consume
        // the result without reading decoded pixels onto the CPU.
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void pack_nv12(texture2d<half,access::read> y [[texture(0)]],"
            "texture2d<half,access::read> cb [[texture(1)]],texture2d<half,access::read> cr [[texture(2)]],"
            "texture2d<half,access::write> out_y [[texture(3)]],texture2d<half,access::write> out_uv [[texture(4)]],"
            "uint2 p [[thread_position_in_grid]]) {"
            "if(p.x>=y.get_width()||p.y>=y.get_height())return;out_y.write(y.read(p),p);"
            "if(((p.x|p.y)&1u)==0u){uint2 c=p/2u;out_uv.write(half4(cb.read(c).r,cr.read(c).r,0,1),c);}}";
        NSError *error = nil;
        id<MTLLibrary> library = [metal newLibraryWithSource:source options:nil error:&error];
        require(library != nil, "Cannot compile PyroWave NV12 packing kernel");
        pack = [metal newComputePipelineStateWithFunction:[library newFunctionWithName:@"pack_nv12"] error:&error];
        require(pack != nil, "Cannot create PyroWave packing pipeline");
        NSDictionary *attributes = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
            (id)kCVPixelBufferMetalCompatibilityKey: @YES, (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        require(CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, (__bridge CFDictionaryRef)attributes, &pool) == kCVReturnSuccess,
                "Cannot create PyroWave pixel buffer pool");
        require(CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, metal, nullptr, &cache) == kCVReturnSuccess,
                "Cannot create PyroWave texture cache");
    }
    CVPixelBufferRef decode(const void *data, size_t size, bool deferred) {
        require(data && size >= 20 && size <= 4 * 1024 * 1024, "Invalid PyroWave frame size");
        const uint8_t *bytes = static_cast<const uint8_t *>(data);
        auto u16 = [&](size_t at) { return uint32_t(bytes[at]) | (uint32_t(bytes[at + 1]) << 8); };
        auto u32 = [&](size_t at) { return u16(at) | (u16(at + 2) << 16); };
        require(!memcmp(bytes, "EPW1", 4) && u16(4) == uint32_t(width) && u16(6) == uint32_t(height) && u32(8) == 1,
                "PyroWave frame format or dimensions changed");
        uint32_t count = u32(12);
        require(count > 0 && count <= 4096, "Invalid PyroWave packet count");
        pyrowave_decoder_clear(decoder);
        size_t offset = 16;
        for (uint32_t p = 0; p < count; ++p) {
            require(size - offset >= 4, "Truncated PyroWave packet length");
            size_t length = u32(offset); offset += 4;
            require(length > 0 && length <= size - offset, "Truncated PyroWave packet");
            checked(pyrowave_decoder_push_packet(decoder, bytes + offset, length), "Malformed PyroWave bitstream");
            offset += length;
        }
        require(offset == size && pyrowave_decoder_decode_is_ready(decoder, false), "Incomplete PyroWave frame");
        CVPixelBufferRef pixel = nullptr;
        require(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess,
                "Cannot allocate PyroWave output buffer");
        CVMetalTextureRef luma = nullptr, chroma = nullptr;
        try {
            NSDictionary *usage = @{(id)kCVMetalTextureUsage: @(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite)};
            require(CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, (__bridge CFDictionaryRef)usage,
                MTLPixelFormatR8Unorm, width, height, 0, &luma) == kCVReturnSuccess, "Cannot wrap PyroWave output luma");
            require(CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, (__bridge CFDictionaryRef)usage,
                MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &chroma) == kCVReturnSuccess, "Cannot wrap PyroWave output chroma");
            id<MTLCommandBuffer> command = [queue commandBuffer];
            require(command != nil, "Cannot create PyroWave decode submission");
            pyrowave_gpu_buffers output = {};
            for (int p = 0; p < 3; ++p) output.planes[p] = (__bridge void *)planes[p];
            checked(pyrowave_decoder_decode_gpu_buffer(decoder, (__bridge void *)command, &output), "PyroWave GPU decode failed");
            id<MTLComputeCommandEncoder> pass = [command computeCommandEncoder];
            require(pass != nil, "Cannot create PyroWave packing pass");
            [pass setComputePipelineState:pack];
            for (int p = 0; p < 3; ++p) [pass setTexture:planes[p] atIndex:p];
            [pass setTexture:CVMetalTextureGetTexture(luma) atIndex:3];
            [pass setTexture:CVMetalTextureGetTexture(chroma) atIndex:4];
            [pass dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [pass endEncoding];
            // Dropped outputs must not return to the pool before GPU packing.
            CFRetain(pixel); CFRetain(luma); CFRetain(chroma); CFRetain(cache);
            CVMetalTextureCacheRef held_cache = cache;
            [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                CFRelease(pixel); CFRelease(luma); CFRelease(chroma); CFRelease(held_cache);
            }];
            if (deferred) {
                CVBufferSetAttachment(pixel, CFSTR("dev.eternalmonitor.pyro.command"),
                                      (__bridge CFTypeRef)command, kCVAttachmentMode_ShouldNotPropagate);
            } else {
                [command commit]; [command waitUntilCompleted];
                require(command.status == MTLCommandBufferStatusCompleted, "Decode command failed");
            }
            CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            CFRelease(luma); CFRelease(chroma);
            return pixel;
        } catch (...) {
            if (luma) CFRelease(luma);
            if (chroma) CFRelease(chroma);
            CFRelease(pixel);
            throw;
        }
    }
};
}
void *em_pyrowave_copy_metal_command_queue(void) {
    return (__bridge_retained void *)shared_queue();
}
int em_pyrowave_is_supported(void) {
    return pyrowave_device_is_supported((__bridge void *)MTLCreateSystemDefaultDevice()) ? 1 : 0;
}
void *em_pyrowave_stream_decoder_create(int width, int height, char *error, size_t error_size) {
    @autoreleasepool { try {
        auto decoder = std::unique_ptr<StreamDecoder>(new StreamDecoder);
        decoder->initialize(width, height);
        return decoder.release();
    } catch (const std::exception &e) { failure(error, error_size, e.what()); return nullptr; } }
}
void em_pyrowave_stream_decoder_destroy(void *decoder) { delete static_cast<StreamDecoder *>(decoder); }
void *em_pyrowave_stream_decode(void *decoder, const void *data, size_t size, char *error, size_t error_size) {
    @autoreleasepool { try {
        require(decoder != nullptr, "Missing PyroWave decoder");
        return static_cast<StreamDecoder *>(decoder)->decode(data, size, false);
    } catch (const std::exception &e) { failure(error, error_size, e.what()); return nullptr; } }
}
void *em_pyrowave_stream_decode_deferred(void *decoder, const void *data, size_t size, char *error, size_t error_size) {
    @autoreleasepool { try {
        require(decoder != nullptr, "Missing PyroWave decoder");
        return static_cast<StreamDecoder *>(decoder)->decode(data, size, true);
    } catch (const std::exception &e) { failure(error, error_size, e.what()); return nullptr; } }
}
