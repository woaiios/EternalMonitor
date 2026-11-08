"""Build the optional BGRA extension into the local pinned PyroWave snapshot."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
snapshot = root / "build/pyrowave/source/pyrowave_c.cpp"
extension = root / "host/native/pyrowave_bgra.inc"
text = snapshot.read_text(encoding="utf-8")
include = f'#include "{extension.as_posix()}"'
if include not in text:
    snapshot.write_text(text + "\n" + include + "\n", encoding="utf-8")
cmake = root / "build/pyrowave/tools/python/cmake/data/bin/cmake.exe"
subprocess.run([str(cmake), "-S", str(snapshot.parent), "-B", str(root / "build/pyrowave/native-zig"),
                "-DGRANITE_VULKAN_SYSTEM_HANDLES=ON"], check=True)
subprocess.run([str(cmake), "--build", str(root / "build/pyrowave/native-zig"),
                "--target", "pyrowave-shared", "-j8"], check=True)
