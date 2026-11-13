# Media Compressor

Offline image/video compression and video cutting for **Windows x64** and **Android 7.0+ (API 24)**. This Flutter app replaces the previous native compressor in this repository.

## Features

- Select multiple images and videos and compress them sequentially.
- Choose a quality preset and maximum dimensions, without enlarging smaller inputs.
- Compress JPEG, PNG and WebP images; export videos as H.264/AAC MP4.
- Cut one selected video range: **Export clip** keeps it; **Remove selection** joins the parts before and after it.
- Save new files in one chosen output folder. Originals and existing outputs are not overwritten.
- Cancel encoding and retry saving a completed output without re-encoding it.

Files are processed locally. There is no server, account or upload service.

## Use

1. **Add files** and choose an **Output folder**.
2. Set the quality and **Longest side** limit, or keep the original dimensions.
3. Choose **Start compression**. Outputs keep the source base name plus `_Compress`, `_Cut` or `_Clip`; collisions receive a number.
4. For cutting, use the video's **scissors** button. Drag the green handles, then choose **Export clip** or **Remove selection**.
5. **Continue** retries a save failure. Discarding an unsaved encoded file requires confirmation; already saved files remain untouched.

**Windows:** keep the complete runtime folder together and run `media_compressor.exe`; its DLLs, `ffmpeg.exe` and `data/` are required. A Microsoft Visual C++ runtime may be needed on another computer.

**Android:** install the APK from a trusted file manager/browser; USB debugging is not required. On Android 11+, choose a permitted output subfolder such as `Downloads/Compressor`, not the root Downloads directory. Keep enough free space for one staged input and its encoded output.

## Known limits

- Android preview catches up after a **1–2 second delay** while adjusting the range. This remains unresolved.
- Android compression/cutting was reported slower than Windows; export speed has not been benchmarked on identical inputs/settings.
- Video cuts re-encode frames and audio; they are not lossless copies or guaranteed millisecond-exact boundaries.
- Only the first audio track is retained. Metadata, chapters and subtitles are not copied; HDR handling is unvalidated.
- Animated images export their first frame. Compression can produce a larger file for some inputs.
- Jobs are foreground/session-only and do not resume after app termination. Keep the app open during work.
- Full-disk, provider-permission and detailed cancellation/lifecycle cases are not all device-validated.
- Android builds currently use development signing, not a production/Play Store signing setup.

## Build and verify

See [BUILDING.md](BUILDING.md). The repository contains source, build files and tests—not SDKs, package caches, generated outputs or compiled applications. Native components and their source/license references are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Core code: `lib/`; Android bridges: `android/app/src/main/kotlin/`; Windows runner and exclusive file-copy helper: `windows/runner/`. The release JNI guard is `scripts/check_android_ffmpeg_jni.py`.
