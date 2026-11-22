# Hermes Lite Mobile

Flutter client for Android and iOS. Connect with a gateway access token or browser sign-in. Choose a profile to browse conversations, stream replies, and exchange images.

## Build

Use Flutter 3.50.1 and rustup. The mobile build hook compiles the shared Rust session protocol for the target architecture.

```sh
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm64
```

Use `android-x64` to build for an x86_64 emulator. The APK for the selected architecture is written to `build/app/outputs/flutter-apk/`. Preview packages use development signing.

On Windows, use an ASCII-only checkout path for release builds. If Kotlin reports an incremental cache error, add `-Dorg.gradle.project.kotlin.incremental=false` to `GRADLE_OPTS` for the build.

On macOS with Xcode, run `flutter build ios --release --no-codesign` to build an unsigned device application. Configure an Apple development team for device installation or distribution.

For signed iOS builds, enable the same App Group for the Runner and ShareExtension targets. Their bundle identifiers and App Group derive from `HERMES_IOS_BUNDLE_ID` in `ios/Flutter/HermesApp.xcconfig`.

Run `flutter build ios --debug --simulator` for the iOS Simulator.

The GitHub Actions **Mobile builds** workflow builds the selected preview target on demand. The `ios-simulator` target installs and launches the app before uploading its artifact.

## Gateway integration test

Set `QA_GATEWAY`, `QA_USERNAME` and `QA_PASSWORD` in the test process environment. The integration test signs in to a Basic-auth gateway, creates a conversation, and exchanges a generated PNG with the assistant.

```sh
flutter test integration/live_gateway_test.dart
```
