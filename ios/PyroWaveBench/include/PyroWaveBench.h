#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Returns owned UTF-8 JSON, including errors. Call em_pyrowave_free afterward.
char *em_pyrowave_benchmark(int width, int height, int fps, int frames, int mbps);
char *em_pyrowave_check_frame(const void *data, size_t size);
int em_pyrowave_is_supported(void);
// Retained id<MTLCommandQueue>; decode and render share its ordering.
void *em_pyrowave_copy_metal_command_queue(void);
void *em_pyrowave_stream_decoder_create(int width, int height, char *error, size_t error_size);
void em_pyrowave_stream_decoder_destroy(void *decoder);
// Returns a retained CVPixelBufferRef as an opaque pointer. Swift takes the
// retained value exactly once. Decode, resize and destroy must be serialized.
void *em_pyrowave_stream_decode(void *decoder, const void *data, size_t size, char *error, size_t error_size);
// Output carries an uncommitted MTLCommandBuffer attachment. Caller installs
// callbacks, commits on the shared queue, then removes the attachment.
void *em_pyrowave_stream_decode_deferred(void *decoder, const void *data, size_t size, char *error, size_t error_size);
void em_pyrowave_free(char *result);
#ifdef __cplusplus
}
#endif
