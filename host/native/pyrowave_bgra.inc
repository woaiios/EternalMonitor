// EternalMonitor's optional C API extension, compiled after pyrowave_c.cpp.
// Upload packed capture pixels once and let PyroWave's GPU scaler do RGB ->
// narrow-range BT.709 YUV420 and optional downscaling before wavelet encode.
extern "C" __declspec(dllexport) pyrowave_result
em_pyrowave_encoder_encode_bgra(pyrowave_encoder encoder, const void *pixels,
                                size_t bytes, int width, int height, size_t stride,
                                const pyrowave_rate_control *rate)
{
    Util::set_thread_logging_interface(&null_logger);
    if (!encoder || !pixels || !rate || width < 64 || height < 64 ||
        width > 8192 || height > 8192 || stride < size_t(width) * 4 ||
        stride > bytes / size_t(height) || encoder->pyro_device->cmd)
        return PYROWAVE_ERROR_INVALID_ARGUMENT;
    auto *device = encoder->device;
    auto &context = encoder->contexts[encoder->context];
    auto &image = context.upload_images[0];
    if (!image || image->get_width() != unsigned(width) || image->get_height() != unsigned(height) ||
        image->get_format() != VK_FORMAT_B8G8R8A8_UNORM)
    {
        auto info = ImageCreateInfo::immutable_2d_image(width, height, VK_FORMAT_B8G8R8A8_UNORM);
        info.misc = IMAGE_MISC_CONCURRENT_QUEUE_ASYNC_TRANSFER_BIT |
                    IMAGE_MISC_CONCURRENT_QUEUE_GRAPHICS_BIT | IMAGE_MISC_CONCURRENT_QUEUE_ASYNC_COMPUTE_BIT;
        info.initial_layout = VK_IMAGE_LAYOUT_UNDEFINED;
        info.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        image = device->create_image(info);
        if (!image) return PYROWAVE_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    if (context.upload_semaphore)
    {
        device->add_wait_semaphore(CommandBuffer::Type::AsyncTransfer,
            std::move(context.upload_semaphore), VK_PIPELINE_STAGE_2_COPY_BIT, true);
        context.upload_semaphore = {};
    }
    auto cmd = device->request_command_buffer(CommandBuffer::Type::AsyncTransfer);
    cmd->image_barrier(*image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_PIPELINE_STAGE_2_COPY_BIT, 0, VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT);
    void *mapped = cmd->update_image(*image, {}, {unsigned(width), unsigned(height), 1},
        stride / 4, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1});
    memcpy(mapped, pixels, stride * size_t(height));
    cmd->image_barrier(*image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_READ_ONLY_OPTIMAL,
        VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT, 0, 0);
    Semaphore uploaded;
    device->submit(cmd, nullptr, 1, &uploaded);
    device->add_wait_semaphore(encoder->pyro_device->queue_type, std::move(uploaded),
        VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, true);
    pyrowave_scaled_encode_info scale = {};
    scale.view.image = image->get_image();
    scale.view.width = width; scale.view.height = height;
    scale.view.image_format = scale.view.view_format = VK_FORMAT_B8G8R8A8_UNORM;
    scale.view.aspect = VK_IMAGE_ASPECT_COLOR_BIT;
    scale.view.swizzle = VK_COMPONENT_SWIZZLE_IDENTITY;
    scale.view.layout = image->get_layout(VK_IMAGE_LAYOUT_READ_ONLY_OPTIMAL);
    scale.input_color_space = scale.output_color_space = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    scale.intermediate_plane_format = VK_FORMAT_R8_UNORM;
    scale.ycbcr_chroma_midpoint = 128.0f / 255.0f;
    scale.ycbcr_range = VK_SAMPLER_YCBCR_RANGE_ITU_NARROW;
    scale.ycbcr_range_bit_depth = 8;
    return pyrowave_encoder_encode_gpu_scaled(encoder, nullptr, nullptr, &scale, rate);
}

struct em_pyrowave_d3d_source {
    pyrowave_image image = nullptr;
    pyrowave_sync_object fence = nullptr;
    ~em_pyrowave_d3d_source() {
        if (image) pyrowave_image_destroy(image);
        if (fence) pyrowave_sync_object_destroy(fence);
    }
};
// Handles are duplicates owned by PyroWave after successful imports.
extern "C" __declspec(dllexport) void *
em_pyrowave_import_d3d11(pyrowave_encoder encoder, pyrowave_os_handle texture,
                         pyrowave_os_handle fence, uint32_t width, uint32_t height)
{
    auto source = std::unique_ptr<em_pyrowave_d3d_source>(new em_pyrowave_d3d_source);
    VkImageCreateInfo vk = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    vk.imageType = VK_IMAGE_TYPE_2D;
    vk.extent = {width, height, 1};
    vk.format = VK_FORMAT_B8G8R8A8_UNORM;
    vk.mipLevels = vk.arrayLayers = 1;
    vk.samples = VK_SAMPLE_COUNT_1_BIT;
    vk.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    vk.tiling = VK_IMAGE_TILING_OPTIMAL;
    pyrowave_image_create_info image = {};
    image.device = encoder->pyro_device;
    image.external_handle = texture;
    image.handle_type = VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_BIT;
    image.image_create_info = &vk;
    if (pyrowave_image_create(&image, &source->image) != PYROWAVE_SUCCESS) return nullptr;
    pyrowave_sync_object_create_info sync = {};
    sync.device = encoder->pyro_device;
    sync.external_handle = fence;
    sync.handle_type = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D11_FENCE_BIT;
    sync.semaphore_type = VK_SEMAPHORE_TYPE_TIMELINE;
    if (pyrowave_sync_object_create(&sync, &source->fence) != PYROWAVE_SUCCESS) return nullptr;
    return source.release();
}
extern "C" __declspec(dllexport) void em_pyrowave_destroy_d3d11(void *opaque) {
    delete static_cast<em_pyrowave_d3d_source *>(opaque);
}
extern "C" __declspec(dllexport) pyrowave_result
em_pyrowave_encode_d3d11_v2(pyrowave_encoder encoder, void *opaque, uint64_t value, uint64_t released,
                         const pyrowave_rate_control *rate)
{
    auto *source = static_cast<em_pyrowave_d3d_source *>(opaque);
    if (!encoder || !source || !rate) return PYROWAVE_ERROR_INVALID_ARGUMENT;
    pyrowave_scaled_encode_info scale = {};
    auto result = pyrowave_image_get_image_view(source->image, VK_IMAGE_ASPECT_COLOR_BIT,
        VK_IMAGE_USAGE_SAMPLED_BIT, &scale.view);
    if (result != PYROWAVE_SUCCESS) return result;
    scale.input_color_space = scale.output_color_space = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    scale.intermediate_plane_format = VK_FORMAT_R8_UNORM;
    scale.ycbcr_chroma_midpoint = 128.0f / 255.0f;
    scale.ycbcr_range = VK_SAMPLER_YCBCR_RANGE_ITU_NARROW;
    scale.ycbcr_range_bit_depth = 8;
    pyrowave_gpu_external_reference ref = {source->image, VK_QUEUE_FAMILY_EXTERNAL};
    pyrowave_gpu_sync_operation acquire = {}, release = {};
    acquire.sync.semaphore = release.sync.semaphore = pyrowave_sync_object_get_semaphore(source->fence);
    acquire.sync.value = value; release.sync.value = released;
    acquire.num_images = release.num_images = 1;
    acquire.images = release.images = &ref;
    return pyrowave_encoder_encode_gpu_scaled(encoder, &acquire, &release, &scale, rate);
}
