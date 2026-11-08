# Read-only USB speed query. EX_V2 is essential: EX alone reports HighSpeed
# even for some SuperSpeed devices. No driver or device settings are changed.
$ErrorActionPreference = 'Stop'
$devices = @(Get-PnpDevice -PresentOnly | Where-Object {
    $_.InstanceId -like 'USB\VID_05AC*' -and $_.InstanceId -notlike '*&MI_*'
})
if ($devices.Count -ne 1) { throw "Expected one Apple USB composite device, found $($devices.Count)." }
$properties = Get-PnpDeviceProperty -InstanceId $devices[0].InstanceId `
    -KeyName DEVPKEY_Device_Parent, DEVPKEY_Device_Address
$hub = ($properties | Where-Object KeyName -eq 'DEVPKEY_Device_Parent').Data
$port = [uint32](($properties | Where-Object KeyName -eq 'DEVPKEY_Device_Address').Data)
if ($hub -notlike 'USB\*' -or $port -eq 0) { throw 'Cannot resolve the parent USB hub and port.' }

if (-not ('EternalMonitor.UsbLinkProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace EternalMonitor {
    public static class UsbLinkProbe {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(SafeFileHandle handle, uint code,
            byte[] input, uint inputSize, byte[] output, uint outputSize,
            out uint returned, IntPtr overlapped);
        static byte[] Query(SafeFileHandle handle, uint code, byte[] input) {
            byte[] output = new byte[input.Length]; uint returned;
            if (!DeviceIoControl(handle, code, input, (uint)input.Length, output,
                    (uint)output.Length, out returned, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (returned < 16) throw new InvalidOperationException("Truncated hub response");
            return output;
        }
        public static uint[] Read(string hub, uint port) {
            string path = @"\\?\" + hub.Replace('\\', '#') + "#{f18a0e88-c30c-11d0-8815-00a0c906bed8}";
            using (var handle = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                byte[] legacy = new byte[4096]; BitConverter.GetBytes(port).CopyTo(legacy, 0);
                legacy = Query(handle, 0x220448, legacy);
                if (legacy[4] != 18 || BitConverter.ToUInt16(legacy, 12) != 0x05ac)
                    throw new InvalidOperationException("Hub port does not contain the Apple device");
                byte[] v2 = new byte[16]; BitConverter.GetBytes(port).CopyTo(v2, 0);
                BitConverter.GetBytes((uint)16).CopyTo(v2, 4);
                BitConverter.GetBytes((uint)4).CopyTo(v2, 8);
                v2 = Query(handle, 0x22045c, v2);
                return new uint[] { legacy[23], BitConverter.ToUInt16(legacy, 6),
                    BitConverter.ToUInt32(v2, 8), BitConverter.ToUInt32(v2, 12) };
            }
        }
    }
}
'@
}
$link = [EternalMonitor.UsbLinkProbe]::Read($hub, $port)
$flags = $link[3]
$speed = if ($flags -band 4) { 'SuperSpeedPlus (USB 3.x)' }
    elseif ($flags -band 1) { 'SuperSpeed (USB 3.x)' }
    elseif ($link[0] -eq 2) { 'HighSpeed (USB 2.0, 480 Mbps)' }
    elseif ($link[0] -eq 1) { 'FullSpeed (12 Mbps)' }
    else { 'LowSpeed or unknown' }
[pscustomobject]@{
    speed = $speed
    usb_descriptor_bcd = ('0x{0:x4}' -f $link[1])
    operating_superspeed_or_higher = [bool]($flags -band 1)
    capable_superspeed_or_higher = [bool]($flags -band 2)
    operating_superspeed_plus_or_higher = [bool]($flags -band 4)
    capable_superspeed_plus_or_higher = [bool]($flags -band 8)
} | ConvertTo-Json
