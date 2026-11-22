# Hermes Desktop Lite

[简体中文](README.md) · English

Lightweight desktop and mobile clients for Hermes Agent.

## Performance

On Windows x64, Lite v0.1.0 took **84% less time** than the official Hermes Desktop client to display a reply when restoring the same conversation from a cold start. Its process tree used **86% less private memory**.

| Metric | Hermes Desktop Lite v0.1.0 | Official Hermes Desktop |
| --- | ---: | ---: |
| Cold start to main window | 0.851 s | 3.141 s |
| Cold start to visible historical reply | 1.270 s | 8.159 s |
| Private memory after cold start | 65.0 MiB | 466.8 MiB |
| Warm start to main window | 204 ms | 358 ms |
| Private memory after warm start | 191.0 MiB | 747.4 MiB |

Both clients used the same profile and restored the same conversation containing one prompt and one reply. Figures are medians of three runs. The official client was built from upstream commit `e96221fa73d2`.

## Technology stack

| Component | Technology |
| --- | --- |
| Desktop | Rust, GPUI |
| Mobile | Dart, Flutter |
| Shared session protocol | Rust (`hermes-client-core`) |

## Build targets

| Desktop | Mobile |
| --- | --- |
| Windows x64, Linux x64, macOS on Apple Silicon | Android ARM64 / x86_64, iOS |

## Windows runtime

If Windows reports that `VCRUNTIME140.dll` is missing at startup, install the Microsoft Visual C++ v14 x64 Redistributable. [Download from Microsoft](https://aka.ms/vc14/vc_redist.x64.exe)

## Design and licensing

The desktop interface draws inspiration from the official Hermes Desktop client. The source code is MIT-licensed. Bundled assets are distributed under their respective licenses. [Upstream project](https://github.com/NousResearch/hermes-agent/tree/f7e2898aaefc8f967dbf7345e3999a65672fe60e/apps/desktop) · [MIT License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
