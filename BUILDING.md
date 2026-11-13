# Building

## Tested toolchain

- Flutter 3.47.9 / Dart 3.13.7.
- Windows host with Visual Studio C++ desktop tools and a Windows SDK.
- JDK 21, Android SDK 36 / build tools 36.0.0, NDK 28.2.13676358.
- Gradle 9.3.1, Android Gradle Plugin 9.1.0 and Kotlin 2.4.0, selected by the project.

SDKs and package caches are not included. Flutter resolves the pinned packages in `pubspec.lock`; the first build may download native player dependencies and Android build tools. Do not commit local SDK paths or signing keys.

## Windows FFmpeg

The Windows build and real-media tests expect the Gyan FFmpeg 8.1.2 essentials archive extracted as:

```text
.tools/ffmpeg-8.1.2-essentials_build/
  bin/ffmpeg.exe
  bin/ffprobe.exe
  LICENSE
  README.txt
```

[Archive](https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-essentials_build.zip) · [Published checksum](https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-essentials_build.zip.sha256)

Verified archive SHA-256:

```text
db580001caa24ac104c8cb856cd113a87b0a443f7bdf47d8c12b1d740584a2ec
```

`.tools/` is ignored. CMake bundles `ffmpeg.exe` and its supplied license/README in the Windows runtime. The Android app instead uses Maven dependency `com.antonkarpenko:ffmpeg-kit-full-gpl:2.2.3`; no Windows FFmpeg binary is used there.

## Build

From the repository root with Flutter and Java on PATH:

```powershell
flutter pub get
flutter build windows --release
flutter build apk --release
```

Windows output: `build/windows/x64/runner/Release/`—distribute the **whole folder**, not just the executable.

Android output: `build/app/outputs/flutter-apk/app-release.apk`. The universal APK includes ARMv7, ARM64 and x86_64 and is too large for a normal GitHub Git file; compiled downloads belong in release assets, not the source tree.

Android release currently uses Flutter's development signing configuration. A build signed on another computer may not update an existing installation signed with a different key. Configure production signing separately and never commit its keys or passwords.

## Verify

```powershell
flutter build windows --debug
flutter test
flutter analyze
python scripts/check_android_ffmpeg_jni.py build/app/outputs/flutter-apk/app-release.apk
```

Build both Windows configurations before running the real native tests: the file-copy tests use the Debug helper DLL, and paused-player tests use the Release player DLL. The FFmpeg tests generate their own fixtures and do not read user media. On other hosts, the Windows-only native tests are skipped.

The JNI guard checks **18 native registrations and four callbacks** in the APK. It uses `ANDROID_HOME`/`ANDROID_SDK_ROOT`, or `.tools/android-sdk/`, with build tools 36.0.0. Override the tool path if necessary:

```powershell
python scripts/check_android_ffmpeg_jni.py build/app/outputs/flutter-apk/app-release.apk --dexdump C:/Android/Sdk/build-tools/36.0.0/dexdump.exe
```

Keep `android/app/proguard-rules.pro`: FFmpeg registers native tables and looks up callbacks by name, so removing the declarations can break a shrinking-enabled release.

Finalization checks passed: 73 tests, analysis, formatting, Windows/Android release builds, the full JNI guard, APK signature and 16 KiB ZIP alignment. Normal build 6 was not installed or UI-tested on the phone; these automated checks do not establish immediate Android preview rendering or every storage/lifecycle edge case.
