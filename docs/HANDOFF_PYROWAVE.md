# PyroWave USB 串流交接

更新：2026-11-08，Windows 工作目录 `D:\lab\EternalMonitor`。

## 用户目标与当前结论

用户要求先检查后门、关闭自动诊断，再让 NVIDIA 负责游戏，AMD 核显承担串流编码；希望采用本机 `D:\lab\pyrowave` 的高带宽、低压缩等待实现。最新决定是**先跑通，后优化**，并授权 commit、push 和留下本交接文件。

**完整串流已经跑通。** PC 实际桌面 1920×1080 → AMD Vulkan PyroWave → USB → iPad Metal 解码 → 原有 Metal 渲染器。用户已明确确认“能看到，画面正常”。这不是只跑通合成 benchmark。当前仍有 CPU 读回、BGRA→YUV420 转换及上传；尚未实现 GPU 纹理直通，也没有证明“不影响游戏帧率”。

PyroWave 使用 GPU compute，不是 AMD AMF 固定功能视频编码器。选择 AMD 可把 PyroWave compute 放到核显；NVIDIA→CPU→AMD 的传输成本仍在。无需物理显示器可以以后通过虚拟显示实现，但编码器仍需要游戏渲染后的帧，不能凭设置直接替代取帧。

## 当前机器与设备

- Ryzen 7 9800X3D / RTX 5090 / AMD Radeon(TM) Graphics，双 GPU 已启用。
- iPad Pro A2759（M2、11 英寸），USB 信任和开发者模式已具备。
- 换线后 USB hub EX_V2 实测为 **SuperSpeedPlus**，不是原来的 USB 2.0；`scripts/win/Get-IpadUsbLink.ps1` 可重新查询。
- 执行 iOS 任务必须先读 `D:\lab\AGENTS.md` 和 `D:\lab\xtool\README.md`。
- Windows 已有 xtool + WSL Ubuntu-24.04 / 用户 dev，能构建、签名、安装、启动真机 App。不要再要求用户找 Mac。
- 当前预览安装 ID：`XTL-UH6S3NYDHH.dev.eternalmonitor.PyroWavePreview`，不覆盖原版 App。
- 已卸载本次自建的独立 PyroWaveBench，给主程序腾出免费签名的 App 名额。用户的 Hello/WDA 保留。

## 本机扩展屏验证（2026-11-08）

- 本机 VDD 绑定 RTX 5090 时，Windows 没有把虚拟屏接入桌面；将 `C:\VirtualDisplayDriver\vdd_settings.xml` 的 `gpu/friendlyname` 设置为 `AMD Radeon(TM) Graphics` 后，虚拟屏成功接入。该配置是本机系统文件，不在 Git 中，也不代表其他机器一定需要 AMD。
- EternalMonitor 的 `vdd_match_resolution` 已启用；连接此 iPad 后，虚拟屏实测为 2388×1668、120 Hz。游戏移动到虚拟屏后，采集约 110 fps，PyroWave 编码及接收约 60 多 fps，尚未达到 120 fps。
- 本机有两个 `Root\MttVDD` 设备：`ROOT\DISPLAY\0002` 供 EternalMonitor 使用，`ROOT\DISPLAY\0003` 已停用。为避免再次启用重复设备，本机的 `EternalMonitor VDD Enable/Disable` 计划任务使用 Program Files 中仅匹配 `0002` 的脚本；这些机器专属任务不包含在仓库中。
- 要复现 GPU 绑定，先备份 VDD 设置文件，再按实际设备名称修改 `gpu/friendlyname`；确认 EternalMonitor 没有覆盖该用户指定名称。切换驱动或设备可能改变 Windows 显示布局，需在目标机器重新验证，不应直接照搬本机实例编号。

## 启停与即时状态

离开前保留真实桌面串流，使用 AMD / 350 Mbps 上限 / 请求 60fps。主机实际帧率由取帧、桌面变化、客户端偏好等决定；`-Fps 120` 不会覆盖 iPad 的 60fps 偏好。

```powershell
# 运行前确认没有本安装的旧进程；新脚本会拒绝重复启动
powershell -ExecutionPolicy Bypass -File scripts/win/Run-PyroWave.ps1

# 合成连续帧，单独验证完整协议路径（默认 1080p）
powershell -ExecutionPolicy Bypass -File scripts/win/Run-PyroWave.ps1 -Synthetic

# 只停止该脚本跟踪且路径、创建时间仍匹配的进程；发 Ctrl+C 正常退出
powershell -ExecutionPolicy Bypass -File scripts/win/Run-PyroWave.ps1 -Stop

# 启动已安装的 iPad 预览，不依赖 WDA
& "$env:APPDATA\npm\ios.exe" launch XTL-UH6S3NYDHH.dev.eternalmonitor.PyroWavePreview --tunnel-info-port=28100
```

主机本地日志：`%APPDATA%\EternalMonitor\logs\eternal-host-session.log`。日志中的 `USB PyroWave encoder active`、`codec=PyroWave (USB)` 和 Receiver report 可确认实际选中 PyroWave。`decode_fps_x10` / `latency_ms_x10` 分别除以 10；后者是时钟校准后的 **capture-to-decode**，不是屏幕响应或输入到显示延迟。

WDA 按用户要求保持停止，8100 转发也已停止。旧 WDA 曾启动失败；已用 xtool 重签并重装，随后 runwda 日志出现设备授权成功，但**没有完成 HTTP/UI 验证**，不能说恢复可用。用户允许之后再单独测试。不要为了串流重新启动 WDA。开发者 userspace tunnel（28100）与 WDA 是不同通道，仍保留用于 go-ios 启动 App。

## 代码入口与协议

- `host/src/encoder/pyrowave.rs`：动态加载 exe 旁的 `libpyrowave-shared-1.dll`，检查 C API 主版本 1；指定 AMD/NVIDIA vendor，异步 compute 队列，CPU YUV420 上传、编码、packetize。
- `host/src/encoder/mod.rs`：仅 `ETERNAL_PYROWAVE=1` + USB + 新客户端能力位才选 PyroWave。DLL/驱动/编码失败后在当前 pipeline generation 回退 H.264/HEVC；离开 PyroWave 重开常规编码器并要求 IDR。Wi-Fi/旧客户端继续使用已有编码。
- `ETERNAL_PYROWAVE_GPU=amd|nvidia|auto`，未设置该变量时使用 auto；启动脚本默认 amd。`ETERNAL_PYROWAVE_MBPS` 100–1000，默认 350（码率上限，不是保证实际占满）。
- `proto/src/v2/control.rs` / iOS `WireProtocol.swift`：codec 2、decoder cap `1<<3`。媒体分片与 USB 长度封装沿用旧协议。
- EPW1 access unit：小端 `magic[4]="EPW1", width:u16, height:u16, flags:u32=1, packet_count:u32`，后接多组 `packet_length:u32 + upstream packet`。flags 1 表示 SDR YUV420 video-range，每帧独立。
- `ios/PyroWaveBench/Streaming.mm`：生产解码桥，Metal 解码到三个平面，再 GPU 打包到 NV12 CVPixelBuffer/IOSurface，带 BT.709 附件。输入尺寸、长度、包数有边界检查。
- `ios/EternalMonitor/Decode/PyroWaveVideoDecoder.swift` / `VideoDecoder.swift`：识别 EPW1，串行 native decoder，排队时丢旧的独立帧；输出仍进入现有 FrameSlot、MetalView。当前每帧同步 waitUntilCompleted，后续可优化。
- `ios/Package.swift`、`xtool.yml`：主程序 Windows/WSL 真机构建入口；`scripts/prepare_ios_xtool.py` 从已有 xcstrings 生成忽略的资源目录，Metal shader 在 SwiftPM 构建下运行时编译。

## 本次实测与边界

本地证据全部留在忽略的 `build/pyrowave/`，不上传设备日志或画面。

| 检查 | 结果 |
| --- | --- |
| USB mux 16 MiB 三次传输 | 1142.1 / 1175.2 / 1382.9 Mbps |
| iPad 合成 1080p120，600 帧 | GPU decode p95 0.353 ms；parse+submit+wait p95 0.725 ms |
| iPad 合成 2388×1668/120，600 帧 | GPU decode p95 0.660 ms；parse+submit+wait p95 1.039 ms |
| Windows 1080p 编码合成数据 | NVIDIA p95 0.694 ms，AMD p95 3.626 ms；含上传/编码/packetize，不含取帧和色彩转换 |
| Windows Vulkan→USB→Metal 像素校验 | AMD/NVIDIA 1080p、NVIDIA 原生分辨率通过；生产 NV12 桥也验证了 luma/chroma |
| 主程序合成串流 | 1280×720、约 60fps，连续接收无视频丢帧 |
| 主程序合成 1080p 再测 | 约 58–60fps，1800+ 连续帧无视频丢帧；仍未优化 CPU 取帧/转换路径 |
| 主程序真实桌面 | 1920×1080，用户确认显示和颜色正常；采集帧率有变化，初始观察无丢失，后续运行出现 USB 队列丢帧 |
| Rust lib 回归 | host 916 passed、8 ignored；wire 59 passed |
| Python probe 单测 | 7 passed |
| 主程序构建 | Windows GNU Rust 成功；iOS xtool release 构建、签名、安装、启动成功 |

合成 benchmark 同时执行了本机 Metal encode，可能暖缓存；不能用其结果承诺持续解码或完整游戏延迟。真实桌面初次观察的 capture-to-decode 大约 18–24 ms，存在更高样本，未做正式分位统计。尚未做游戏画质、输入到显示延迟、游戏帧时间对照、120fps 长测和温控长测。

后续桌面复测记录过 `usb_drops=7`、接收端 `dropped=4`，因此不能承诺持续零丢帧。当前 1 MiB USB 队列加大量 1400-byte 分片，在高码率/调度抖动时需要进一步测量；独立帧可继续恢复画面，但这仍是待优化项。未用扩大队列掩盖延迟。1080p 合成复测的 capture-to-decode 也有约 30–40 ms 的样本。

主要证据文件：`ipad-usb3-results.json`、`usb3-link.json`、`vulkan-1080p.json`、`vulkan-amd-1080p.json`、`interop-amd-nv12.json`、`interop-native-nv12.json`、`stream-synthetic-full.log`、`stream-desktop-full.log`、`unit-tests.log`。不要把这些整体 add 到 Git。

## 重新构建

本机工具都隔离在本工作区缓存，未改全局 PATH：`.cargo-home/`、`.rustup-home/`、`build/pyrowave/tools/`。Rust pinned 1.98.0 Windows GNU；LLVM-MinGW 20240619 MSVCRT；FFmpeg 7.1.1 shared SDK。

```powershell
# 这份本机缓存脚本配置 CC/CXX/AR、FFMPEG_DIR、libclang、bindgen includes
. ./build/pyrowave/cargo-env.ps1
cargo build --locked -p eternal-host -j8
cargo test --locked -p eternal-wire -p eternal-host --lib -j8
cargo fmt --all -- --check
python -m unittest scripts/test_pyrowave_probe.py
Copy-Item build/pyrowave/ffmpeg/ffmpeg-7.1.1-full_build-shared/bin/*.dll target/debug/
Copy-Item build/pyrowave/native-zig/libpyrowave-shared-1.dll target/debug/

python scripts/prepare_ios_xtool.py
wsl -d Ubuntu-24.04 -u dev -- bash -lc 'cd /mnt/d/lab/EternalMonitor/ios && xtool dev build -c release'
# 先 kill 自己的预览 App 再安装，否则安装可能停在 100%
& "$env:APPDATA\npm\ios.exe" kill XTL-UH6S3NYDHH.dev.eternalmonitor.PyroWavePreview --tunnel-info-port=28100
wsl -d Ubuntu-24.04 -u dev -- bash -lc 'xtool install --usb /mnt/d/lab/EternalMonitor/ios/xtool/EternalMonitor.app'
```

初次全量构建 Copus 若出现 `.o.scan` 缺失，可先串行完成 SwiftBuild，再让 xtool 打包；本次已验证成功：

```bash
export XCODE_EXTRA_PLATFORM_FOLDERS=/home/dev/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms
export PATH=/home/dev/.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin:$PATH
cd /mnt/d/lab/EternalMonitor/ios
swift build --configuration release --build-system swiftbuild --triple arm64-apple-ios \
  --toolset /home/dev/.swiftpm/swift-sdks/darwin.artifactbundle/toolset-swb.json -j 1
```

Windows Rust 使用 LLVM-MinGW 时必须 `RUSTFLAGS='-C link-self-contained=yes'`，否则缺 `gcc/gcc_eh`；libclang 在 `tools/python/libclang-18.1.1.data/platlib/clang/native`，不是 `tools/python/clang/native`。旧的失败缓存 `build/pyrowave/native/` 不要复用，DLL 成功构建目录为 `native-zig/`。

原生 DLL 来源：本机 `D:\lab\pyrowave` commit `7fe0e2667cd3076b8b2bf04bcb80bc8d691b800b`，MIT；Granite pin `53090429539bf3404250d18fe58db971f0907c04`，volk `47cddf7ed97b94118a08aacb548a411188e016cc`，Vulkan-Headers `6802bb4733b63ed5efd3adb308a6c885ef180ea1`。源码构建快照位于 `build/pyrowave/source`；Zig 0.14.1 + CMake/Ninja 构建 `pyrowave-shared`，`GRANITE_PLATFORM=null`，`PYROWAVE_UTILS=OFF`。首次配置就需设 CMAKE_AR/CMAKE_RANLIB 为缓存内调用 `zig ar/ranlib` 的 wrapper。可以使用现有 CMakeCache 重建：

```powershell
& ./build/pyrowave/tools/python/cmake/data/bin/cmake.exe --build build/pyrowave/native-zig --target pyrowave-shared -j8
```

当前 DLL SHA256：`A33681A102DA98752E6DD88263EB4D3A02BD3D9A0C7B8ABC69C2F6961510F67A`。应用不会从网络自动下载 DLL。iPad vendor 代码随仓库保存，并在 `vendor/UPSTREAM.md` 标注原始来源。

## 自动诊断与安全审查遗留

自动分享诊断已改为默认关闭、显式 opt-in；旧 iOS 自动分享键不作为同意，关闭时清除待上传队列；主机需显式 enabled marker，历史 disabled marker 优先。现有对应 Rust 测试通过，iOS XCTest 源码已更新，但本机 xtool 不能直接运行该 XCTest 套件。

此前静态审查未确认后门，但不能等同完整安全保证。已记录的后续关注点：局域网媒体/配对 token 明文、现有防火墙范围、FFmpeg 下载供应链固定/hash。它们未在本次 PyroWave 接入中一并重构。不要把根目录 go-ios 生成的 `selfIdentity.plist` 或签名凭据提交。

## 下一步建议

1. 先保留当前可用路径；对同一游戏比较 AMD PyroWave、NVIDIA PyroWave、NVENC 的游戏帧时间、capture-to-decode、呈现延迟及画质。
2. 跟踪真正瓶颈再优化。现有 DXGI Map/Copy→CPU BGRA→swscale→GPU 上传仍在；上游 `encode_desktop.cpp` 有同适配器 LUID 的 D3D11 texture/fence→Vulkan 导入样例，但 NVIDIA→AMD 跨适配器不是同一个零拷贝路径。
3. 优化 USB 大量小分片、native 同步等待、首次 shader 编译与分辨率切换；维持 latest-wins，避免堆队列。
4. 只有长测通过后才提升到 120fps / 原生分辨率；不要把合成 decode p95 当成完整串流延迟。
5. WDA 后续独立测试：重签后 `/status`、创建 session、一次可见元素操作；串流无需 WDA。用户已允许以后测试，当前保持关闭。
