# Third-party components

Native codec/player binaries are obtained from upstream packages, not stored in Git. Their licenses remain applicable, including GPL/LGPL corresponding-source requirements when redistributing binaries.

| Component | Version/build | License and source reference |
|---|---|---|
| Windows FFmpeg | Gyan 8.1.2 essentials | GPLv3. The supplied license and build README are bundled under `data/ffmpeg/`. [Build provider](https://www.gyan.dev/ffmpeg/builds/) · [Source revision reported by the provider](https://github.com/FFmpeg/FFmpeg/commit/38b88335f9) |
| Android FFmpegKit Full-GPL | `com.antonkarpenko:ffmpeg-kit-full-gpl:2.2.3`, FFmpeg 8.1.2 | GPLv3/LGPLv3 components, including GPL codecs such as x264. [Native package sources/build scripts](https://github.com/sk3llo/ffmpeg_kit_flutter_android/tree/full-gpl) · [FFmpeg sources](https://github.com/FFmpeg/FFmpeg/tree/n8.1.2). License texts and notice are in APK `assets/ffmpeg/`. |
| media_kit / media_kit_video | 1.2.6 / 2.0.1 | MIT, copyright Hitesh Kumar Saini. [Sources](https://github.com/media-kit/media-kit). Native bundles have their own component licenses. |
| Windows native player | `mpv-dev-x86_64-20230924-git-652a1dd` | [Build sources/configuration](https://github.com/media-kit/libmpv-win32-video-build) · [mpv sources/license](https://github.com/mpv-player/mpv). |
| Android native player | libmpv Android video build v1.1.7 | [Build sources/configuration](https://github.com/media-kit/libmpv-android-video-build/tree/v1.1.7) · [mpv sources/license](https://github.com/mpv-player/mpv). |
| ANGLE runtime | Windows bundle v1.0.1 | [Bundle provider](https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES) · [ANGLE sources/license](https://github.com/google/angle). |
| Flutter / Dart | Flutter 3.47.9 | BSD-style licenses and component notices. [Flutter sources/license](https://github.com/flutter/flutter) · [Dart sources/license](https://github.com/dart-lang/sdk). Flutter also generates merged package notices in the application assets. |
| Gradle wrapper | 9.3.1 | Apache-2.0. [Sources/license](https://github.com/gradle/gradle). |

Other Dart packages and their exact versions are listed in `pubspec.lock`; their notices are included by Flutter. Native build configurations include additional codec/rendering libraries: consult the linked upstream build scripts and retain their required notices and corresponding sources. A dependency name or source link alone is not a license-compliance audit for a modified redistribution.
