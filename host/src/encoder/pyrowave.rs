//! USB-only experimental PyroWave encoder. H.264/HEVC remains the fallback.
//! The DLL is built from the pinned upstream source and loaded from the app
//! directory with restricted dependency lookup; it is never downloaded at runtime.
use crate::capture::RawFrame;

pub(super) fn requested() -> bool {
    cfg!(windows) && std::env::var("ETERNAL_PYROWAVE").is_ok_and(|value| value == "1")
}

pub(crate) fn bitrate_bps() -> u32 {
    std::env::var("ETERNAL_PYROWAVE_MBPS")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|value| (100..=1000).contains(value))
        .unwrap_or(350)
        * 1_000_000
}

#[cfg(windows)]
pub(super) use native::Encoder;
#[cfg(not(windows))]
pub(super) struct Encoder;
#[cfg(not(windows))]
impl Encoder {
    pub fn new(_: u32, _: u32) -> Result<Self, String> {
        Err("PyroWave encoding requires Windows".into())
    }
    pub fn dimensions(&self) -> (u32, u32) {
        (0, 0)
    }
    pub fn encode(&mut self, _: &RawFrame, _: u32, _: u32) -> Result<Vec<u8>, String> {
        Err("PyroWave encoding requires Windows".into())
    }
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::{ffi::c_void, os::windows::ffi::OsStrExt};
    type Handle = *mut c_void;
    #[repr(C)]
    struct EncoderInfo {
        device: Handle,
        width: i32,
        height: i32,
        chroma: i32,
    }
    #[repr(C)]
    struct CpuBuffer {
        data: [Handle; 3],
        strides: [usize; 3],
        sizes: [usize; 3],
        width: i32,
        height: i32,
        format: i32,
    }
    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct Packet {
        offset: usize,
        size: usize,
    }
    #[repr(C)]
    struct Rate {
        maximum_bitstream_size: usize,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn LoadLibraryExW(path: *const u16, file: Handle, flags: u32) -> Handle;
        fn GetProcAddress(module: Handle, name: *const u8) -> Handle;
        fn FreeLibrary(module: Handle) -> i32;
    }
    struct Library(Handle);
    impl Drop for Library {
        fn drop(&mut self) {
            unsafe {
                FreeLibrary(self.0);
            }
        }
    }
    impl Library {
        unsafe fn function<T: Copy>(&self, name: &[u8]) -> Result<T, String> {
            let pointer = GetProcAddress(self.0, name.as_ptr());
            if pointer.is_null() {
                return Err(format!(
                    "Missing PyroWave entry point {}",
                    String::from_utf8_lossy(name)
                ));
            }
            assert_eq!(std::mem::size_of::<T>(), std::mem::size_of::<Handle>());
            Ok(std::mem::transmute_copy(&pointer))
        }
    }
    struct Api {
        _library: Library,
        create: unsafe extern "C" fn(u32, u32, Handle, Handle, Handle, i32, *mut Handle) -> i32,
        device_destroy: unsafe extern "C" fn(Handle),
        queue: unsafe extern "C" fn(Handle, i32) -> i32,
        encoder_create: unsafe extern "C" fn(*const EncoderInfo, *mut Handle) -> i32,
        encoder_destroy: unsafe extern "C" fn(Handle),
        encode: unsafe extern "C" fn(Handle, *const CpuBuffer, *const Rate) -> i32,
        count: unsafe extern "C" fn(Handle, usize, *mut usize) -> i32,
        packetize:
            unsafe extern "C" fn(Handle, *mut Packet, usize, *mut usize, Handle, usize) -> i32,
    }
    impl Api {
        fn load() -> Result<Self, String> {
            let path = std::env::current_exe()
                .map_err(|e| e.to_string())?
                .with_file_name("libpyrowave-shared-1.dll");
            let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            let handle =
                unsafe { LoadLibraryExW(wide.as_ptr(), std::ptr::null_mut(), 0x100 | 0x800) };
            if handle.is_null() {
                return Err(format!(
                    "Cannot load {}: {}",
                    path.display(),
                    std::io::Error::last_os_error()
                ));
            }
            let library = Library(handle);
            unsafe {
                let version: unsafe extern "C" fn(*mut u32, *mut u32, *mut u32) =
                    library.function(b"pyrowave_get_api_version\0")?;
                let (mut major, mut minor, mut patch) = (0, 0, 0);
                version(&mut major, &mut minor, &mut patch);
                if major != 1 {
                    return Err(format!("Unsupported PyroWave API {major}.{minor}.{patch}"));
                }
                Ok(Self {
                    create: library.function(b"pyrowave_create_device_by_compat\0")?,
                    device_destroy: library.function(b"pyrowave_device_destroy\0")?,
                    queue: library.function(b"pyrowave_device_set_queue_type\0")?,
                    encoder_create: library.function(b"pyrowave_encoder_create\0")?,
                    encoder_destroy: library.function(b"pyrowave_encoder_destroy\0")?,
                    encode: library.function(b"pyrowave_encoder_encode_cpu\0")?,
                    count: library.function(b"pyrowave_encoder_compute_num_packets\0")?,
                    packetize: library.function(b"pyrowave_encoder_packetize\0")?,
                    _library: library,
                })
            }
        }
    }
    fn checked(code: i32, operation: &str) -> Result<(), String> {
        if code == 0 {
            Ok(())
        } else {
            Err(format!("PyroWave {operation} failed: {code}"))
        }
    }
    pub(crate) struct Encoder {
        api: Api,
        device: Handle,
        encoder: Handle,
        width: u32,
        height: u32,
        scaler: ffmpeg_next::software::scaling::Context,
        frame: ffmpeg_next::frame::Video,
        output: Vec<u8>,
    }
    impl Drop for Encoder {
        fn drop(&mut self) {
            unsafe {
                if !self.encoder.is_null() {
                    (self.api.encoder_destroy)(self.encoder);
                }
                if !self.device.is_null() {
                    (self.api.device_destroy)(self.device);
                }
            }
        }
    }
    impl Encoder {
        pub fn dimensions(&self) -> (u32, u32) {
            (self.width, self.height)
        }
        pub fn new(width: u32, height: u32) -> Result<Self, String> {
            if !(64..=4096).contains(&width)
                || !(64..=4096).contains(&height)
                || width % 2 != 0
                || height % 2 != 0
            {
                return Err("PyroWave requires even dimensions between 64 and 4096".into());
            }
            let scaler = super::super::input::conversion_context(
                ffmpeg_next::format::Pixel::YUV420P,
                width,
                height,
            )
            .map_err(|e| e.to_string())?
            .ok_or("No BGRA to YUV converter")?;
            let frame =
                ffmpeg_next::frame::Video::new(ffmpeg_next::format::Pixel::YUV420P, width, height);
            let mut state = Self {
                api: Api::load()?,
                device: std::ptr::null_mut(),
                encoder: std::ptr::null_mut(),
                width,
                height,
                scaler,
                frame,
                output: Vec::new(),
            };
            let vendor = match std::env::var("ETERNAL_PYROWAVE_GPU").as_deref() {
                Ok("amd") => 0x1002,
                Ok("nvidia") => 0x10de,
                _ => 0,
            };
            unsafe {
                checked(
                    (state.api.create)(
                        vendor,
                        0,
                        std::ptr::null_mut(),
                        std::ptr::null_mut(),
                        std::ptr::null_mut(),
                        256,
                        &mut state.device,
                    ),
                    "device create",
                )?;
                checked(
                    (state.api.queue)(state.device, 2),
                    "async compute queue selection",
                )?;
                let info = EncoderInfo {
                    device: state.device,
                    width: width as i32,
                    height: height as i32,
                    chroma: 0,
                };
                checked(
                    (state.api.encoder_create)(&info, &mut state.encoder),
                    "encoder create",
                )?;
            }
            Ok(state)
        }
        pub fn encode(
            &mut self,
            raw: &RawFrame,
            bitrate: u32,
            fps: u32,
        ) -> Result<Vec<u8>, String> {
            super::super::input::convert_packed_bgra(&mut self.scaler, &raw.data, &mut self.frame)
                .map_err(|e| e.to_string())?;
            let input = CpuBuffer {
                data: std::array::from_fn(|p| self.frame.data(p).as_ptr() as Handle),
                strides: std::array::from_fn(|p| self.frame.stride(p)),
                sizes: std::array::from_fn(|p| self.frame.data(p).len()),
                width: self.width as i32,
                height: self.height as i32,
                format: 1,
            };
            // Leave room for framing in the existing 1 MiB USB queue, even
            // at the smallest supported media datagram size.
            let budget =
                (u64::from(bitrate) / 8 / u64::from(fps.max(1))).clamp(4096, 768 * 1024) as usize;
            let rate = Rate {
                maximum_bitstream_size: budget,
            };
            self.output.resize(budget, 0);
            let mut count = 0;
            unsafe {
                checked((self.api.encode)(self.encoder, &input, &rate), "encode")?;
                checked(
                    (self.api.count)(self.encoder, budget, &mut count),
                    "packet count",
                )?;
            }
            if count == 0 || count > 4096 {
                return Err("Invalid PyroWave packet count".into());
            }
            let mut packets = vec![Packet::default(); count];
            unsafe {
                checked(
                    (self.api.packetize)(
                        self.encoder,
                        packets.as_mut_ptr(),
                        budget,
                        &mut count,
                        self.output.as_mut_ptr().cast(),
                        budget,
                    ),
                    "packetize",
                )?;
            }
            if count > packets.len() {
                return Err("PyroWave exceeded packet allocation".into());
            }
            let mut data = Vec::with_capacity(budget + 16 + 4 * count);
            data.extend_from_slice(b"EPW1");
            data.extend_from_slice(&(self.width as u16).to_le_bytes());
            data.extend_from_slice(&(self.height as u16).to_le_bytes());
            data.extend_from_slice(&1u32.to_le_bytes()); // SDR 4:2:0, video range.
            data.extend_from_slice(&(count as u32).to_le_bytes());
            for packet in packets.into_iter().take(count) {
                let end = packet
                    .offset
                    .checked_add(packet.size)
                    .ok_or("Packet size overflow")?;
                if packet.size == 0 || end > self.output.len() {
                    return Err("Invalid PyroWave packet range".into());
                }
                data.extend_from_slice(&(packet.size as u32).to_le_bytes());
                data.extend_from_slice(&self.output[packet.offset..end]);
            }
            Ok(data)
        }
    }
}
