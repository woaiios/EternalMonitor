param(
    [switch]$Stop,
    [ValidateSet('amd', 'nvidia', 'auto')][string]$Gpu = 'amd',
    [ValidateRange(100, 1000)][int]$Mbps = 350,
    [ValidateRange(30, 120)][int]$Fps = 120,
    [switch]$Synthetic,
    [ValidatePattern('^\d{2,4}x\d{2,4}$')][string]$Size = '1920x1080',
    [switch]$Release,
    [switch]$FrameTrace,
    [switch]$GpuCapture,
    [switch]$GpuConversion,
    [ValidateRange(0, 2160)][int]$VideoHeight = 0,
    [ValidateSet('compute', 'graphics')][string]$GpuQueue = 'compute'
)
$ErrorActionPreference = 'Stop'
$pyroRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pyroBuild = Join-Path $pyroRoot 'build/pyrowave'
$pyroProfile = if ($Release) { 'release' } else { 'debug' }
$pyroExe = Join-Path $pyroRoot "target/$pyroProfile/eternal-host.exe"
$pyroRecord = Join-Path $pyroBuild 'running-host.json'

if ($Stop) {
    if (!(Test-Path -LiteralPath $pyroRecord)) { throw 'No host is tracked by this script.' }
    $record = Get-Content -LiteralPath $pyroRecord -Raw | ConvertFrom-Json
    $tracked = Get-Process -Id $record.id -ErrorAction SilentlyContinue
    if ($tracked) {
        if ($tracked.Path -ne $pyroExe -or $tracked.StartTime.ToUniversalTime().Ticks.ToString() -ne $record.start) {
            throw 'Tracked process identity changed; refusing to stop it.'
        }
        if (!('PyroHostConsole' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PyroHostConsole {
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll")] static extern bool GenerateConsoleCtrlEvent(uint signal, uint group);
    public static bool Stop(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) return false;
        try {
            if (!SetConsoleCtrlHandler(IntPtr.Zero, true)) return false;
            bool sent = GenerateConsoleCtrlEvent(0, 0);
            // Let the ignored control event reach this helper before
            // FreeConsole resets its control handler state.
            System.Threading.Thread.Sleep(250);
            return sent;
        } finally { FreeConsole(); }
    }
}
'@
        }
        if (![PyroHostConsole]::Stop([uint32]$tracked.Id) -or !$tracked.WaitForExit(15000)) {
            throw 'Graceful stop failed; the host was left running for inspection.'
        }
    }
    Remove-Item -LiteralPath $pyroRecord
    Write-Output 'Tracked PyroWave host stopped.'
    return
}

foreach ($required in @($pyroExe, (Join-Path (Split-Path $pyroExe) 'libpyrowave-shared-1.dll'),
        (Join-Path (Split-Path $pyroExe) 'avcodec-61.dll'))) {
    if (!(Test-Path -LiteralPath $required)) { throw "Missing build artifact: $required. See docs/HANDOFF_PYROWAVE.md." }
}
$existing = Get-Process eternal-host -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $pyroExe }
if ($existing) { throw 'This host installation is already running. Stop its current session first.' }
New-Item -ItemType Directory -Force $pyroBuild | Out-Null
if ($VideoHeight -ne 0 -and ($VideoHeight -lt 64 -or $VideoHeight % 2 -ne 0)) {
    throw 'VideoHeight must be zero (native) or an even number from 64 to 2160.'
}
if ($VideoHeight -gt 0 -and !($GpuCapture -or $GpuConversion)) {
    throw 'VideoHeight requires GpuCapture or GpuConversion.'
}
foreach ($option in @('ETERNAL_PYROWAVE_BGRA', 'ETERNAL_PYROWAVE_GPU_CAPTURE', 'ETERNAL_PYROWAVE_HEIGHT')) {
    Remove-Item "Env:$option" -ErrorAction SilentlyContinue
}
if ($GpuCapture -or $GpuConversion) { $env:ETERNAL_PYROWAVE_BGRA = '1' }
if ($GpuCapture) { $env:ETERNAL_PYROWAVE_GPU_CAPTURE = '1' }
if ($VideoHeight -gt 0) { $env:ETERNAL_PYROWAVE_HEIGHT = $VideoHeight.ToString() }
$env:ETERNAL_PYROWAVE_QUEUE = $GpuQueue
$env:ETERNAL_PYROWAVE = '1'
$env:ETERNAL_PYROWAVE_GPU = $Gpu
$env:ETERNAL_PYROWAVE_MBPS = $Mbps.ToString()
$env:ETERNAL_FPS = $Fps.ToString()
$env:ETERNAL_HEADLESS = '1'
$env:ETERNAL_E2E_LOG = '1'
$env:RUST_LOG = 'info'
if ($FrameTrace) {
    $env:ETERNAL_FRAME_TRACE = '1'
} else {
    Remove-Item Env:ETERNAL_FRAME_TRACE -ErrorAction SilentlyContinue
}
if ($Synthetic) {
    $env:ETERNAL_CAPTURE = 'synthetic'
    $env:ETERNAL_SYNTH_SIZE = $Size
} else {
    Remove-Item Env:ETERNAL_CAPTURE -ErrorAction SilentlyContinue
}
$process = Start-Process -FilePath $pyroExe -WorkingDirectory $pyroRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $pyroBuild 'host.out') -RedirectStandardError (Join-Path $pyroBuild 'host.err')
@{ id = $process.Id; start = $process.StartTime.ToUniversalTime().Ticks.ToString();
   gpu_capture = [bool]$GpuCapture; gpu_conversion = [bool]($GpuCapture -or $GpuConversion);
   video_height = $VideoHeight; gpu_queue = $GpuQueue; frame_trace = [bool]$FrameTrace } |
    ConvertTo-Json | Set-Content -LiteralPath $pyroRecord
Write-Output "PyroWave host PID $($process.Id), GPU=$Gpu, ceiling=$Mbps Mbps, requested=$Fps fps."
if ($GpuCapture) { Write-Output 'Shared textures select the capture adapter by LUID; GPU preference does not override it.' }
Write-Output 'Keep the EternalMonitor preview open on the USB-connected iPad.'
