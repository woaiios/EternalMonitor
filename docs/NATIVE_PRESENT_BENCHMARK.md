# iPad 原生 Metal 呈现等待实测

2026-11-08，iPad Pro A2759 / Apple M2 GPU / iPadOS 27.0.1，横屏全屏 2388×1668，thermal=nominal。独立 UIKit + CAMetalLayer 程序，本地 GPU 清屏至缓慢变化的颜色，不经过网络、视频解码、SwiftUI 或串流帧队列。

每轮 30 秒，剔除前 5 秒和最后 1 秒。GPU 完成取 MTLCommandBuffer.gpuEndTime，呈现取 CAMetalDrawable.presentedTime；时间均在 iPad 上同一 Mach media clock。呈现回调的到达时刻没有当作呈现时间。未用外部光学设备测量面板扫描或像素响应。

| 原生路径 | 请求fps | 实际fps | 有效帧数 | 实际呈现间隔中位数 ms | GPU完成→呈现 p50 / p95 ms | 零呈现帧 / 区间提交 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CADisplayLink 立即 / 2 buffers | 120 | 59.944 | 1438 | 16.6735 | 15.5383 / 19.8777 | 0 / 1438 |
| CADisplayLink 立即 / 3 buffers | 120 | 119.951 | 2879 | 8.3367 | 15.6505 / 15.7903 | 0 / 2879 |
| CADisplayLink 延后 / 3 buffers | 120 | 119.951 | 2879 | 8.3367 | 15.6378 / 15.7878 | 0 / 2879 |
| CAMetalDisplayLink 立即 / 2 buffers | 120 | 119.409 | 2865 | 8.3367 | 15.6396 / 15.8905 | 0 / 2865 |
| CAMetalDisplayLink 提前 1200us / 2 buffers | 120 | 115.323 | 2767 | 8.3367 | 7.8464 / 8.0087 | 111 / 2878 |
| CAMetalDisplayLink 提前 2500us / 2 buffers | 120 | 119.826 | 2876 | 8.3367 | 9.2009 / 9.9365 | 0 / 2876 |
| CAMetalDisplayLink 立即 / 2 buffers | 60 | 59.976 | 1439 | 16.6735 | 15.4213 / 19.7928 | 0 / 1439 |
| CAMetalDisplayLink 提前 2500us / 2 buffers | 60 | 59.976 | 1439 | 16.6735 | 10.1562 / 14.3108 | 0 / 1439 |

## 解释和限制

- 120Hz 每周期实测约 8.3367ms，但不等于每张图从 GPU 完成到呈现固定等 8.3367ms。立即提交的原生路径确实能每 8.33ms 呈现一帧，同时让每张帧提前等待约 15.6ms。吞吐率与单帧等待不同。
- CAMetalDisplayLink 的 targetTimestamp 是调用 present 的截止时间，targetPresentationTimestamp 是目标呈现时间。立即提交时回调约在目标呈现前 16.1ms；晚提交只缩短本地生成画面后的等待，callback→presented 中位数仍约 16.1ms。这不是触摸到显示的结果。
- 提前 1200us 的激进档，GPU完成→呈现 7.8464 / 8.0087ms，但 111/2878（3.86%）区间提交的 presentedTime=0；这些帧已计为未呈现，不能作为稳定低延迟成功。
- 提前 2500us 的保守档，GPU完成→呈现 9.2009 / 9.9365ms，区间零呈现帧为 0，实际约 119.826fps；最高等待仍到 21.7835ms，短测不是长期尾延迟承诺。
- CADisplayLink + 2 drawable 这一配置在 nextDrawable 中阻塞，只有约 60fps，不能冒充 120fps 对照。增加到 3 drawable 后约 120fps，但等待仍约 15.65ms。
- CADisplayLink 晚提交这一配置又在 nextDrawable 中位阻塞约 1.918ms，错过 deadline，callback→presented 中位数升至 24.251ms。不能声称所有显示 API 只要晚提交就能降低等待。
- GPU 渲染本身中位约 0.026ms，是最小清屏负载；真实游戏或复杂原生 UI 会有额外工作。
- 60fps 只规定产出频率，不意味着每帧必须等待 16.67ms：同机 CAMetalDisplayLink 晚提交测到 GPU完成→呈现中位 10.1562ms，P95 14.3108ms。
- 本次没有修改串流渲染参数，也没有用原生实验数据宣称完整串流达到 10ms。先前约 15.4ms 的串流观察有了独立原生基线；具体应如何改串流路径仍要单独测量。

## 复现与原始数据

程序及恢复步骤见 [NativePresentBench README](../ios/NativePresentBench/README.md)。分析脚本 scripts/analyze_native_present.py；驱动 scripts/run_native_present.py；分析计时口径的测试 scripts/test_analyze_native_present.py。xtool 真机构建/安装已通过，Python 相关 10 tests passed。

全部原始 trace、report、安装/恢复日志仅保留在忽略的 build/pyrowave/。数据路径：

- `native-cadirect120-report.json`
- `native-cadirect120-three/report.json`
- `native-calate120-three/report.json`
- `native-metaldirect120-report.json`
- `native-metallate120-report.json`
- `native-metallate2500/report.json`
- `native-metaldirect60/report.json`
- `native-metallate60/report.json`
