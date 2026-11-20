# Hermes Desktop Lite

[简体中文](README.md) · English

Hermes Desktop Lite is a lightweight desktop client for Hermes Agent, built with Rust and GPUI.

## Technical stack

| Component | Implementation |
| --- | --- |
| Native UI | GPUI and gpui-component provide windowing, text input, and GPU-accelerated rendering. The conversation list and message timeline use virtualization to build rows for the visible range. |
| Gateway communication | Tokio schedules asynchronous I/O. tokio-tungstenite sends conversation requests and receives streaming events over WebSocket. reqwest uses HTTP to load history, fetch attachments, and download files. |
| Content rendering | markdown parses messages into a syntax tree that the client renders with GPUI as paragraphs, tables, and code blocks. image decodes images, and calamine parses workbooks. |

## Windows runtime

If the Windows x64 build reports a missing VC++ runtime file such as `VCRUNTIME140.dll`, install the Microsoft Visual C++ v14 x64 Redistributable and relaunch the client. [Official Microsoft download](https://aka.ms/vc14/vc_redist.x64.exe)

## Windows performance

In each benchmark, both clients connect to the same remote gateway, use the same profile, and restore one chat tab containing the same short text history of one prompt and one reply. Lite uses the v0.1.0 Windows x64 release executable. The official client is built locally from upstream commit `e96221fa73d2` with Electron 44.10.2.

### Cold start

| Metric | Hermes Desktop Lite v0.1.0 | Official Hermes Desktop |
| --- | ---: | ---: |
| Time to main window | 0.851 s | 3.141 s |
| Time to visible historical reply | 1.270 s | 8.159 s |
| Process-tree private memory | 65.0 MiB | 466.8 MiB |
| Sum of process-tree working sets | 88.4 MiB | 672.2 MiB |
| Client processes at sampling time | 1 | 4 |

<details>
<summary>Cold-start methodology and measurements</summary>

Before each run, Windows is restarted and allowed to settle for at least 75 seconds before the first launch of the client. Each client is measured three times. The table reports the median for timing and memory.

Timing starts just before process creation. The two milestones are the first appearance of a titled main window and the first on-screen match for a reference image of the target historical reply. Private memory and working sets are summed across the client and its child processes 12 seconds after the reply becomes visible.

| Client | Main window (ms) | Historical reply (ms) | Private memory (MiB) | Working set (MiB) |
| --- | ---: | ---: | ---: | ---: |
| Lite | 770 / 851 / 854 | 1246 / 1270 / 1344 | 65.0 / 64.0 / 65.1 | 88.4 / 87.8 / 89.1 |
| Official client | 3407 / 3056 / 3141 | 8159 / 8045 / 8205 | 462.3 / 466.8 / 467.8 | 657.0 / 672.2 / 672.6 |

</details>

### Warm start

| Metric | Hermes Desktop Lite v0.1.0 | Official Hermes Desktop |
| --- | ---: | ---: |
| Time to main window | 204 ms | 358 ms |
| Process-tree private memory | 191.0 MiB | 747.4 MiB |
| Sum of process-tree working sets | 236.1 MiB | 979.3 MiB |
| Client processes at sampling time | 1 | 6 |

<details>
<summary>Warm-start methodology and measurements</summary>

Both clients use maximized chat windows and retain their disk caches. Each client runs once to warm up, followed by three measured runs in alternating order. The client exits fully before each launch. Timing begins just before process creation and ends when Windows first reports a visible, titled main window, with a polling interval of roughly 10 ms. Conversation restoration is checked separately in the UI. The timings in this table measure window appearance.

Private memory and resident working sets are summed across the client and its child processes 12 seconds after the main window appears. The table reports medians. Summing working sets can count shared pages more than once. The workload covers the restoration of a short, existing text history. During testing, the official client logged a gateway response denying an exclusive maintenance request.

| Client | Warm start (ms), three runs | Private memory (MiB), three runs | Working set (MiB), three runs |
| --- | --- | --- | --- |
| Lite | 223 / 204 / 204 | 190.7 / 191.0 / 191.0 | 236.0 / 236.1 / 236.2 |
| Official client | 374 / 352 / 358 | 747.4 / 751.7 / 747.0 | 979.3 / 983.4 / 978.6 |

</details>

## Design and licensing

The conversation sidebar, tab layout, and message styling draw inspiration from the official Hermes Desktop client. The source code is MIT-licensed. Bundled icons, fonts, and chat backgrounds are distributed under their respective licenses. [Upstream project](https://github.com/NousResearch/hermes-agent/tree/f7e2898aaefc8f967dbf7345e3999a65672fe60e/apps/desktop) · [MIT License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
