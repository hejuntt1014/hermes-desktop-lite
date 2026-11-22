<div align="center">

<img src="assets/gateway-illustration.png" width="96" alt="Hermes Lite">

# Hermes Lite

**Lightweight clients for [Hermes Agent](https://github.com/NousResearch/hermes-agent): a native Rust desktop app and a Flutter mobile app**

[简体中文](README.md) · English

[![Release](https://img.shields.io/github/v/release/hejuntt1014/hermes-desktop-lite?label=desktop)](https://github.com/hejuntt1014/hermes-desktop-lite/releases/latest)
[![Android](https://img.shields.io/github/v/release/hejuntt1014/hermes-desktop-lite?include_prereleases&filter=android-*&label=android)](https://github.com/hejuntt1014/hermes-desktop-lite/releases)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

<p align="center">
  <img src="docs/screenshots/desktop-chat.png" alt="Desktop chat" width="100%">
</p>

Hermes Lite connects to your own Hermes gateway so you can browse conversations, stream replies, share attachments and talk by voice from your computer and your phone. The desktop app renders natively with Rust and GPUI, so it starts fast and stays light. The mobile app is built with Flutter and uses floating frosted-glass controls that leave the screen to your content.

## Download

| Platform | Download |
| --- | --- |
| Windows x64 · Linux x64 · macOS on Apple Silicon | [Latest desktop release](https://github.com/hejuntt1014/hermes-desktop-lite/releases/latest) |
| Android ARM64 / x86_64 | [Android previews](https://github.com/hejuntt1014/hermes-desktop-lite/releases) |
| iOS | Build it yourself, see [Building](#building) |

If Windows reports that `VCRUNTIME140.dll` is missing at startup, install the [Microsoft Visual C++ v14 x64 Redistributable](https://aka.ms/vc14/vc_redist.x64.exe).

## Why it is faster

On Windows x64, Lite v0.1.0 took **84% less time** than the official Hermes Desktop client to display a reply when restoring the same conversation from a cold start. Its process tree used **86% less private memory**.

| Metric | Hermes Lite v0.1.0 | Official Hermes Desktop |
| --- | ---: | ---: |
| Cold start to main window | 0.851 s | 3.141 s |
| Cold start to visible historical reply | 1.270 s | 8.159 s |
| Private memory after cold start | 65.0 MiB | 466.8 MiB |
| Warm start to main window | 204 ms | 358 ms |
| Private memory after warm start | 191.0 MiB | 747.4 MiB |

Both clients used the same profile and restored the same conversation containing one prompt and one reply. Figures are medians of three runs. The official client was built from upstream commit `e96221fa73d2`.

## Desktop

<p align="center">
  <img src="docs/screenshots/desktop-appearance.png" alt="Desktop appearance settings" width="100%">
</p>

- **Conversations**: tabs, pinning and archiving, branches and date groups, full-text search and profile switching; long conversations load in pages and remember where you were reading
- **Chat**: streamed replies, reasoning, tool-call summaries, task lists, clarification and approval cards, plus edit, retry, branch and export
- **Workspace**: browse remote files, reference files and folders, review Git changes, upload attachments and paste images
- **Voice**: dictation, voice conversation (GPT-Live or speech-to-text) and wake word
- **Personalization**: built-in and custom themes, wallpapers and transparency, importable and exportable theme packages
- **Connection**: a local gateway or a remote one, with an access token or browser sign-in

## Mobile

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/mobile-home.png" width="200" alt="New chat"><br><sub>New chat</sub></td>
    <td align="center"><img src="docs/screenshots/mobile-chat.png" width="200" alt="Chat"><br><sub>Chat</sub></td>
    <td align="center"><img src="docs/screenshots/mobile-sidebar.png" width="200" alt="Sidebar"><br><sub>Sidebar</sub></td>
    <td align="center"><img src="docs/screenshots/mobile-menu.png" width="200" alt="Attachment menu"><br><sub>Attachment menu</sub></td>
    <td align="center"><img src="docs/screenshots/mobile-voice.png" width="200" alt="Voice conversation"><br><sub>Voice</sub></td>
  </tr>
</table>

- **Content first**: the top bar and composer float over the conversation as frosted glass, and the composer folds to a single line when idle
- **Tabs**: switch between conversations like browser tabs, or swipe the title to move to the next one
- **Voice**: GPT-Live real-time voice by default; a call shrinks to a draggable bubble that keeps the chat in view, and a tap on the microphone dictates
- **Desktop parity**: attachments and images, model and reasoning level, scheduled tasks, workspace files, clarifications and approvals, automatic reconnection
- **Two languages**: Simplified Chinese and English

## Building

### Desktop

Requires Rust 1.100, pinned by `rust-toolchain.toml`.

```sh
cargo build --release
```

The binary is written to `target/release/hermes-desktop-lite`. On Linux, install the GPUI system dependencies first; see [`.github/workflows/desktop.yml`](.github/workflows/desktop.yml).

### Mobile

Requires Flutter 3.50.1 and rustup. The build compiles the shared Rust session protocol for the target architecture.

```sh
cd mobile
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm64
```

See [`mobile/README.md`](mobile/README.md) for iOS, signing and emulator builds. On Windows, build Android from a project path that contains only ASCII characters.

## Technology

| Component | Technology |
| --- | --- |
| Desktop | Rust, [GPUI](https://www.gpui.rs/) |
| Mobile | Dart, Flutter |
| Shared session protocol | Rust ([`crates/hermes-client-core`](crates/hermes-client-core)) |

## Design and licensing

The desktop interface draws inspiration from the official Hermes Desktop client. The source code is [MIT-licensed](LICENSE); bundled assets are distributed under their respective licenses, see the [third-party notices](THIRD_PARTY_NOTICES.md). [Upstream project](https://github.com/NousResearch/hermes-agent/tree/f7e2898aaefc8f967dbf7345e3999a65672fe60e/apps/desktop)
