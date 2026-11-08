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
    pub fn convert(&mut self, _: &RawFrame) -> Result<(), String> {
        Err("PyroWave encoding requires Windows".into())
    }
    pub fn encode(&mut self, _: u32, _: u32) -> Result<Vec<u8>, String> {
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

    /// One horizontal band of a picture, converted by one thread. Bands start
    /// on even rows, so each band's 4:2:0 chroma lines average the same input
    /// rows a full-frame conversion would.
    struct Band {
        y: usize,
        rows: usize,
    }

    /// `height` split into `wanted` even-row bands that cover it exactly.
    fn bands(height: u32, wanted: usize) -> Vec<Band> {
        assert_eq!(height % 2, 0, "PyroWave requires an even height");
        let chroma_rows = (height / 2) as usize;
        let count = wanted.clamp(1, chroma_rows);
        let base = chroma_rows / count;
        let extra = chroma_rows % count;
        let mut bands = Vec::with_capacity(count);
        let mut y = 0;
        for index in 0..count {
            let rows = (base + usize::from(index < extra)) * 2;
            bands.push(Band { y, rows });
            y += rows;
        }
        debug_assert_eq!(y, height as usize);
        bands
    }

    /// How many threads convert one frame: at native iPad resolution a
    /// single-threaded conversion costs more than the 8.33 ms a 120 fps
    /// frame has. `ETERNAL_PYROWAVE_THREADS` overrides the default.
    fn convert_threads() -> usize {
        let default = std::thread::available_parallelism()
            .map_or(4, |count| count.get())
            .clamp(1, 8);
        std::env::var("ETERNAL_PYROWAVE_THREADS")
            .ok()
            .and_then(|value| value.trim().parse::<usize>().ok())
            .filter(|count| (1..=32).contains(count))
            .unwrap_or(default)
    }

    /// One band's conversion, sent to its thread.
    struct Job {
        src: *const u8,
        row_stride: usize,
        rows: usize,
        dst: [*mut u8; 3],
        dst_stride: [libc::c_int; 3],
    }
    // SAFETY: the encoder thread owns the capture rows and output planes a job
    // points at, and waits for every job of a frame to report back before it
    // reads the planes or hands the capture buffer back.
    unsafe impl Send for Job {}

    /// `SwsContext` is not `Send` in ffmpeg-next; this one is moved into a
    /// thread and only ever used there.
    struct Owned(ffmpeg_next::software::scaling::Context);
    unsafe impl Send for Owned {}

    impl Owned {
        fn context(&mut self) -> &mut ffmpeg_next::software::scaling::Context {
            &mut self.0
        }
    }

    /// BGRA rows converted into one YUV420P frame, one thread per band.
    struct Sliced {
        jobs: Vec<std::sync::mpsc::Sender<Job>>,
        results: std::sync::mpsc::Receiver<Result<(), String>>,
        threads: Vec<std::thread::JoinHandle<()>>,
        bands: Vec<Band>,
        frame: ffmpeg_next::frame::Video,
        width: u32,
        height: u32,
    }

    impl Sliced {
        fn new(width: u32, height: u32, wanted: usize) -> Result<Self, String> {
            let bands = bands(height, wanted);
            let (results, result_rx) = std::sync::mpsc::channel();
            let mut jobs = Vec::with_capacity(bands.len());
            let mut threads = Vec::with_capacity(bands.len());
            for (index, band) in bands.iter().enumerate() {
                let scaler =
                    crate::encoder::input::band_conversion_context(width, band.rows as u32)
                        .map_err(|error| format!("PyroWave band converter: {error}"))?;
                let (sender, receiver) = std::sync::mpsc::channel::<Job>();
                let results = results.clone();
                let mut scaler = Owned(scaler);
                let handle = std::thread::Builder::new()
                    .name(format!("pyrowave-convert-{index}"))
                    .spawn(move || {
                        while let Ok(job) = receiver.recv() {
                            let src = [
                                job.src,
                                std::ptr::null(),
                                std::ptr::null(),
                                std::ptr::null(),
                            ];
                            let src_stride = [job.row_stride as libc::c_int, 0, 0, 0];
                            // sws_scale reads `job.rows` rows of `job.row_stride`
                            // from `job.src`, which lies inside the capture
                            // buffer, and writes each plane at `job.dst`.
                            let written = unsafe {
                                ffmpeg_next::ffi::sws_scale(
                                    scaler.context().as_mut_ptr(),
                                    src.as_ptr(),
                                    src_stride.as_ptr(),
                                    0,
                                    job.rows as libc::c_int,
                                    job.dst.as_ptr(),
                                    job.dst_stride.as_ptr(),
                                )
                            };
                            let outcome = if written < 0 {
                                Err(format!("PyroWave band conversion failed: {written}"))
                            } else {
                                Ok(())
                            };
                            if results.send(outcome).is_err() {
                                return;
                            }
                        }
                    })
                    .map_err(|error| format!("PyroWave conversion thread: {error}"))?;
                jobs.push(sender);
                threads.push(handle);
            }
            Ok(Self {
                jobs,
                results: result_rx,
                threads,
                bands,
                frame: ffmpeg_next::frame::Video::new(
                    ffmpeg_next::format::Pixel::YUV420P,
                    width,
                    height,
                ),
                width,
                height,
            })
        }

        /// Converts `rows` (capture's snug BGRA picture) into this frame and
        /// returns when every band is done.
        fn convert(&mut self, rows: &[u8]) -> Result<(), String> {
            let row_bytes = self.width as usize * 4;
            let frame_bytes = row_bytes * self.height as usize;
            if rows.len() < frame_bytes {
                return Err("PyroWave input frame is shorter than its size".into());
            }
            // swscale reads up to FRAME_PADDING past the last row; capture's
            // buffers have that much, anything else is copied once.
            let padded;
            let rows = if rows.len() < frame_bytes + crate::capture::FRAME_PADDING {
                let mut copy = vec![0u8; frame_bytes + crate::capture::FRAME_PADDING];
                copy[..frame_bytes].copy_from_slice(&rows[..frame_bytes]);
                padded = copy;
                &padded[..]
            } else {
                rows
            };
            let frame = unsafe { self.frame.as_mut_ptr() };
            let data = unsafe { (*frame).data };
            let strides = unsafe {
                [
                    (*frame).linesize[0] as usize,
                    (*frame).linesize[1] as usize,
                    (*frame).linesize[2] as usize,
                ]
            };
            for (sender, band) in self.jobs.iter().zip(&self.bands) {
                let chroma_y = band.y / 2;
                let job = Job {
                    src: unsafe { rows.as_ptr().add(band.y * row_bytes) },
                    row_stride: row_bytes,
                    rows: band.rows,
                    dst: [
                        unsafe { data[0].add(band.y * strides[0]) },
                        unsafe { data[1].add(chroma_y * strides[1]) },
                        unsafe { data[2].add(chroma_y * strides[2]) },
                    ],
                    dst_stride: [
                        strides[0] as libc::c_int,
                        strides[1] as libc::c_int,
                        strides[2] as libc::c_int,
                    ],
                };
                if sender.send(job).is_err() {
                    return Err("PyroWave conversion thread stopped".into());
                }
            }
            let mut failure = None;
            for _ in 0..self.jobs.len() {
                match self.results.recv() {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => {
                        failure.get_or_insert(error);
                    }
                    Err(_) => return Err("PyroWave conversion threads stopped".into()),
                }
            }
            match failure {
                Some(error) => Err(error),
                None => Ok(()),
            }
        }

        fn frame(&self) -> &ffmpeg_next::frame::Video {
            &self.frame
        }
    }

    impl Drop for Sliced {
        fn drop(&mut self) {
            self.jobs.clear();
            for thread in self.threads.drain(..) {
                let _ = thread.join();
            }
        }
    }
    pub(crate) struct Encoder {
        api: Api,
        device: Handle,
        encoder: Handle,
        width: u32,
        height: u32,
        convert: Sliced,
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
            let convert = Sliced::new(width, height, convert_threads())?;
            let mut state = Self {
                api: Api::load()?,
                device: std::ptr::null_mut(),
                encoder: std::ptr::null_mut(),
                width,
                height,
                convert,
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
        /// Converts `raw` into the encoder's YUV420P input picture; [`encode`]
        /// then encodes it. Split from `encode` so the pipeline can report and
        /// budget conversion and encoding separately.
        ///
        /// [`encode`]: Self::encode
        pub fn convert(&mut self, raw: &RawFrame) -> Result<(), String> {
            self.convert.convert(&raw.data)
        }
        pub fn encode(&mut self, bitrate: u32, fps: u32) -> Result<Vec<u8>, String> {
            let frame = self.convert.frame();
            let input = CpuBuffer {
                data: std::array::from_fn(|p| frame.data(p).as_ptr() as Handle),
                strides: std::array::from_fn(|p| frame.stride(p)),
                sizes: std::array::from_fn(|p| frame.data(p).len()),
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

    #[cfg(test)]
    mod tests {
        use super::*;

        fn pattern(bytes: &mut [u8], row_bytes: usize) {
            for (index, byte) in bytes.iter_mut().enumerate() {
                *byte = (index * 131 + index / row_bytes * 29) as u8;
            }
        }

        #[test]
        fn bands_tile_the_picture_on_even_rows() {
            for height in [18u32, 64, 1080, 1668] {
                for wanted in [1usize, 2, 3, 5, 8, 32] {
                    let bands = bands(height, wanted);
                    let mut y = 0;
                    for band in &bands {
                        assert_eq!(band.y, y);
                        assert_eq!(band.rows % 2, 0, "{height} in {wanted}");
                        y += band.rows;
                    }
                    assert_eq!(y, height as usize, "{height} in {wanted}");
                    assert!(bands.len() <= wanted);
                }
            }
        }

        /// Luma rows must match; swscale's chroma dithering is indexed by the
        /// row's position in the picture, so bands may round a chroma sample
        /// the other way by one.
        fn assert_same(
            expected: &ffmpeg_next::frame::Video,
            actual: &ffmpeg_next::frame::Video,
            label: &str,
        ) {
            for plane in 0..3 {
                let tolerance = if plane == 0 { 0 } else { 1 };
                let visible = expected.plane_width(plane) as usize;
                for y in 0..expected.plane_height(plane) as usize {
                    let line = |frame: &ffmpeg_next::frame::Video| {
                        let start = y * frame.stride(plane);
                        frame.data(plane)[start..start + visible].to_vec()
                    };
                    let (want, got) = (line(expected), line(actual));
                    if tolerance == 0 {
                        assert_eq!(want, got, "{label} plane {plane} row {y}");
                        continue;
                    }
                    for (x, (want, got)) in want.iter().zip(&got).enumerate() {
                        assert!(
                            want.abs_diff(*got) <= tolerance,
                            "{label} plane {plane} row {y} x {x}: {want} vs {got}"
                        );
                    }
                }
            }
        }

        /// Bands converted on their own threads give the picture a full-frame
        /// conversion gives, at widths whose rows align and don't.
        #[test]
        fn band_conversion_matches_a_full_frame_conversion() {
            ffmpeg_next::init().unwrap();
            for (width, height) in [(2388u32, 1668u32), (1920, 1080), (96, 64), (102, 18)] {
                let row_bytes = width as usize * 4;
                let frame_bytes = row_bytes * height as usize;
                let mut rows = crate::capture::frame_buffer(frame_bytes);
                pattern(&mut rows[..frame_bytes], row_bytes);
                let mut scaler = crate::encoder::input::conversion_context(
                    ffmpeg_next::format::Pixel::YUV420P,
                    width,
                    height,
                )
                .unwrap()
                .unwrap();
                let mut whole =
                    ffmpeg_next::frame::Video::new(ffmpeg_next::format::Pixel::YUV420P, width, height);
                crate::encoder::input::convert_packed_bgra(&mut scaler, &rows, &mut whole).unwrap();
                for wanted in [1usize, 3, 8] {
                    let mut sliced = Sliced::new(width, height, wanted).unwrap();
                    sliced.convert(&rows).unwrap();
                    assert_same(
                        &whole,
                        sliced.frame(),
                        &format!("{width}x{height} in {wanted} bands"),
                    );
                }
            }
        }
    }
}
