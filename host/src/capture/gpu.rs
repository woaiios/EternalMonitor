//! Bounded D3D11 texture/fence handoff. The encoder imports the same adapter
//! by LUID; CPU pixels and cross-adapter resource sharing are not involved.
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc,
};
use windows::core::{Interface, PCWSTR};
use windows::Win32::Foundation::HANDLE;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::{
    Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC},
    IDXGIResource1,
};

static FAILED: AtomicBool = AtomicBool::new(false);
pub fn requested() -> bool {
    !FAILED.load(Ordering::Relaxed)
        && std::env::var("ETERNAL_PYROWAVE_GPU_CAPTURE").as_deref() == Ok("1")
}
pub fn disable() {
    FAILED.store(true, Ordering::Relaxed);
}

#[derive(Debug)]
pub struct Texture {
    pub texture: ID3D11Texture2D,
    pub fence: ID3D11Fence,
    pub texture_handle: OwnedHandle,
    pub fence_handle: OwnedHandle,
    pub luid: [u8; 8],
    pub width: u32,
    pub height: u32,
    next: AtomicU64,
    release: AtomicU64,
}
impl Texture {
    pub fn reserve_release(&self) -> u64 {
        self.next.fetch_add(1, Ordering::Relaxed)
    }
    pub fn committed_release(&self, value: u64) {
        // A rejected encode must not leave capture waiting on a value that
        // was never submitted to Vulkan.
        self.release.store(value, Ordering::Release);
    }
}
#[derive(Debug)]
pub struct GpuFrame {
    pub resource: Arc<Texture>,
    pub value: u64,
}
pub struct Pool {
    device: ID3D11Device,
    device5: ID3D11Device5,
    context: ID3D11DeviceContext,
    context4: ID3D11DeviceContext4,
    luid: [u8; 8],
    pub dimensions: (u32, u32),
    textures: Vec<Arc<Texture>>,
}
impl Pool {
    pub fn new(
        device: &ID3D11Device,
        context: &ID3D11DeviceContext,
        luid: [u8; 8],
        width: u32,
        height: u32,
    ) -> windows::core::Result<Self> {
        Ok(Self {
            device: device.clone(),
            device5: device.cast()?,
            context: context.clone(),
            context4: context.cast()?,
            luid,
            dimensions: (width, height),
            textures: Vec::new(),
        })
    }
    fn allocate(&self) -> windows::core::Result<Arc<Texture>> {
        unsafe {
            let (width, height) = self.dimensions;
            let desc = D3D11_TEXTURE2D_DESC {
                Width: width,
                Height: height,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC {
                    Count: 1,
                    Quality: 0,
                },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: (D3D11_BIND_SHADER_RESOURCE.0 | D3D11_BIND_RENDER_TARGET.0) as u32,
                CPUAccessFlags: 0,
                MiscFlags: (D3D11_RESOURCE_MISC_SHARED_NTHANDLE.0 | D3D11_RESOURCE_MISC_SHARED.0)
                    as u32,
            };
            let mut texture = None;
            self.device
                .CreateTexture2D(&desc, None, Some(&mut texture))?;
            let texture = texture.unwrap();
            let resource: IDXGIResource1 = texture.cast()?;
            let shared = resource.CreateSharedHandle(None, 0x10000000, PCWSTR::null())?;
            let texture_handle = OwnedHandle::from_raw_handle(shared.0);
            let mut fence = None;
            self.device5
                .CreateFence(0, D3D11_FENCE_FLAG_SHARED, &mut fence)?;
            let fence: ID3D11Fence = fence.unwrap();
            let shared = fence.CreateSharedHandle(None, 0x10000000, PCWSTR::null())?;
            Ok(Arc::new(Texture {
                texture,
                fence,
                texture_handle,
                fence_handle: OwnedHandle::from_raw_handle(shared.0),
                luid: self.luid,
                width,
                height,
                next: AtomicU64::new(1),
                release: AtomicU64::new(0),
            }))
        }
    }
    pub fn copy(
        &mut self,
        source: &ID3D11Texture2D,
    ) -> windows::core::Result<Option<Arc<GpuFrame>>> {
        let available = self
            .textures
            .iter()
            .find(|t| Arc::strong_count(t) == 1)
            .cloned();
        let resource = match available {
            Some(value) => value,
            None if self.textures.len() < 4 => {
                let value = self.allocate()?;
                self.textures.push(value.clone());
                value
            }
            None => return Ok(None),
        };
        let value = resource.next.fetch_add(1, Ordering::Relaxed);
        unsafe {
            let released = resource.release.load(Ordering::Acquire);
            if released != 0 {
                self.context4.Wait(&resource.fence, released)?;
            }
            self.context.CopyResource(&resource.texture, source);
            self.context4.Signal(&resource.fence, value)?;
            self.context.Flush();
        }
        Ok(Some(Arc::new(GpuFrame { resource, value })))
    }
}
pub fn raw_handle(value: &OwnedHandle) -> HANDLE {
    HANDLE(value.as_raw_handle())
}
