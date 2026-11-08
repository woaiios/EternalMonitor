Unmodified Metal backend from `D:/lab/pyrowave`, commit
`7fe0e2667cd3076b8b2bf04bcb80bc8d691b800b`.

Upstream: https://github.com/Themaister/pyrowave
License: MIT, reproduced in LICENSE. Includes upstream's generated MSL header.
The standalone benchmark uses the encoder and decoder. EternalMonitor links
the decoder through `../Streaming.mm`; encoding on Windows uses the upstream
Vulkan C API DLL. Vendor files are unmodified.
