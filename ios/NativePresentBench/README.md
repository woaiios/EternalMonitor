# Native Metal 呈现基准

这是独立的 UIKit + CAMetalLayer 可执行程序，直接在 iPad 本地 GPU 上以原生 drawable 尺寸清屏到缓慢变化的颜色。没有网络、视频编解码、SwiftUI 或串流帧队列。它测量最小原生 Metal 路径，不能代表所有原生游戏的负载。

## 测量口径

每帧以 id 连接 CPU submit、MTLCommandBuffer.gpuStartTime / gpuEndTime 和 CAMetalDrawable.presentedTime；时间均来自同一设备 Mach media clock，不需要 PC/iPad 校时。呈现回调到达时间只用于独立记录回调滞后，不能当作呈现时间。presentedTime=0 的帧计作未呈现，不能拿它制造零延迟。

- gpu_end_to_presented：实际 GPU 完成到系统呈现事件的等待。
- render_begin_to_presented：本地决定这一帧颜色到系统呈现事件。
- callback_to_presented：显示回调到系统呈现事件；晚提交不会自动降低这个值。
- actual_present_interval：连续实际呈现时间之差；用于核对真实帧率，不能由 maximumFramesPerSecond 或请求值代替。

预热前 5 秒、最后 1 秒不计；默认每轮 30 秒。分析覆盖全部选定区间提交，分别报告缺失和零呈现；统计并非面板扫描/像素响应的光学测量。GPU 渲染是最小清屏负载，约 0.026ms。

## 模式

| 参数 | 行为 |
| --- | --- |
| --mode=cadirect | CADisplayLink 回调立即 nextDrawable、GPU 清屏、commandBuffer.present、commit |
| --mode=calate | 延到 CADisplayLink.targetTimestamp - lead 后生成当前颜色并提交 |
| --mode=metaldirect | CAMetalDisplayLink，preferredFrameLatency=1，回调立即提交并 present |
| --mode=metallate | 延到 CAMetalDisplayLink.targetTimestamp - lead 后生成当前颜色并提交 |
| --fps=120 或 60 | 固定 preferredFrameRateRange 请求；需以实际呈现间隔核对 |
| --drawables=2 或 3 | CAMetalLayer.maximumDrawableCount |
| --lead-us=2500 | 晚提交的提前量，限定 500..5000 微秒 |
| --seconds=30 | 运行时长，结束后停止提交，保留最后画面 |

颜色由 render_begin 的本地当前时间生成，不是提前生成后只修改计时起点。晚提交能缩短成帧后的等待，但不证明触摸到显示也同样缩短。

## 本机构建和恢复

先读 D:/lab/AGENTS.md 和 D:/lab/xtool/README.md。WDA 无需启动。

**本机免费签名名额有限，xtool.yml 故意复用串流预览 bundle ID。安装时会暂时替换预览可执行程序，测试后必须恢复，不能卸载预览 App 或删除其容器。**

```powershell
# 保留串流 App（目的目录应是一个新的本地忽略路径）
Copy-Item ios/xtool/EternalMonitor.app build/pyrowave/native-bench-restore.app -Recurse
wsl -d Ubuntu-24.04 -u dev -- bash -lc 'cd /mnt/d/lab/EternalMonitor/ios/NativePresentBench && xtool dev build -c release'
& "$env:APPDATA/npm/ios.exe" kill XTL-UH6S3NYDHH.dev.eternalmonitor.PyroWavePreview --tunnel-info-port=28100
wsl -d Ubuntu-24.04 -u dev -- bash -lc 'xtool install --usb /mnt/d/lab/EternalMonitor/ios/NativePresentBench/xtool/NativePresentBench.app'
python scripts/run_native_present.py --mode metallate --fps 120 --drawables 2 --lead-us 2500 --output build/pyrowave/native-metallate2500
# 恢复串流预览，签名和容器保持同一身份
& "$env:APPDATA/npm/ios.exe" kill XTL-UH6S3NYDHH.dev.eternalmonitor.PyroWavePreview --tunnel-info-port=28100
wsl -d Ubuntu-24.04 -u dev -- bash -lc 'xtool install --usb /mnt/d/lab/EternalMonitor/build/pyrowave/native-bench-restore.app'
& "$env:APPDATA/npm/ios.exe" launch XTL-UH6S3NYDHH.dev.eternalmonitor.PyroWavePreview --arg=--frame-trace --tunnel-info-port=28100
```

数据只写 App Documents/native-present.jsonl，go-ios AFC 取回到忽略的 build/pyrowave/；没有诊断上传。run_native_present.py 仅启动/测试已经安装好的基准，不安装也不自动恢复 App。它不能单独证明当前安装的是基准程序，因此应先按上面的安装步骤执行。
