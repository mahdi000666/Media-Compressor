import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../media_files/media_files.dart';
import 'android_ffmpeg.dart';

enum CompressionQuality { smaller, balanced, higher }

final class CompressionFailure implements Exception {
  const CompressionFailure(this.message, {this.shared = false});
  final String message;
  final bool shared;
  @override
  String toString() => message;
}

final class FfmpegCompressor {
  FfmpegCompressor({required this.temporaryDirectory, String? executable})
    : executable =
          executable ??
          p.join(p.dirname(Platform.resolvedExecutable), 'ffmpeg.exe');

  final Directory temporaryDirectory;
  final String executable;
  final Map<CompletedOutput, Directory> _outputs = Map.identity();
  late final AndroidFfmpeg _androidEncoder = AndroidFfmpeg();
  Process? _process;
  bool _running = false;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    if (Platform.isAndroid) _androidEncoder.cancel();
    _process?.kill();
  }

  Future<CompletedOutput?> compress(
    MediaSource source, {
    CompressionQuality quality = CompressionQuality.balanced,
    int? maxEdge,
    List<({Duration start, Duration end})>? sections,
    String? suggestedName,
    void Function(Duration)? onProgress,
  }) async {
    if (_running) throw StateError('An encode is already running.');
    if (maxEdge != null && maxEdge < 2) {
      throw ArgumentError.value(maxEdge, 'maxEdge');
    }
    _running = true;
    _cancelled = false;
    Directory? workspace;
    var retained = false;
    try {
      final extension = p.extension(source.displayName).toLowerCase();
      final video = source.kind == MediaKind.video;
      if (sections != null &&
          (!video ||
              sections.isEmpty ||
              sections.any(
                (section) =>
                    section.start.isNegative || section.end <= section.start,
              ))) {
        throw const CompressionFailure(
          'Choose at least one valid video section.',
        );
      }
      if (!video && !{'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)) {
        throw const CompressionFailure('Unsupported image format.');
      }
      if (await File(source.reference).length() == 0) {
        throw const CompressionFailure('The input file is empty.');
      }
      try {
        await temporaryDirectory.create(recursive: true);
        workspace = await temporaryDirectory.createTemp('encode-');
      } on FileSystemException {
        throw const CompressionFailure(
          'Cannot create temporary output. Check available storage and access to the app cache.',
          shared: true,
        );
      }
      final outputExtension = video ? '.mp4' : extension;
      final output = CompletedOutput(
        path: p.join(workspace.path, 'output$outputExtension'),
        suggestedName:
            suggestedName ??
            '${p.basenameWithoutExtension(source.displayName)}_Compress$outputExtension',
        mimeType: video
            ? 'video/mp4'
            : switch (extension) {
                '.png' => 'image/png',
                '.webp' => 'image/webp',
                _ => 'image/jpeg',
              },
      );
      final filter = maxEdge == null
          ? (video ? 'scale=trunc(iw/2)*2:trunc(ih/2)*2' : null)
          : "scale='min(iw,$maxEdge)':'min(ih,$maxEdge)':force_original_aspect_ratio=decrease${video ? ':force_divisible_by=2' : ''}";
      var input = source.reference;
      if (sections != null) {
        final path = File(source.reference).absolute.path
            .replaceAll('\\', '/')
            .replaceAll("'", "'\\''");
        final playlist = File(p.join(workspace.path, 'sections.ffconcat'));
        await playlist.writeAsString(
          [
            'ffconcat version 1.0',
            for (final section in sections) ...[
              "file '$path'",
              'inpoint ${_seconds(section.start)}',
              'outpoint ${_seconds(section.end)}',
              'duration ${_seconds(section.end - section.start)}',
            ],
            '',
          ].join('\n'),
        );
        input = playlist.path;
      }
      final filters = [
        if (sections != null) ...[
          'select=concatdec_select',
          'setpts=PTS-STARTPTS',
        ],
        ?filter,
      ];
      final args = <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-n',
        '-protocol_whitelist',
        'file,pipe',
        if (sections != null) ...[
          '-copyts',
          '-segment_time_metadata',
          '1',
          '-f',
          'concat',
          '-safe',
          '0',
        ],
        '-i',
        input,
        '-map',
        '0:V:0',
        '-map_metadata',
        '-1',
        '-map_chapters',
        '-1',
        if (filters.isNotEmpty) ...['-vf', filters.join(',')],
        if (sections != null) ...[
          '-af',
          'aselect=concatdec_select,asetpts=PTS-STARTPTS,aresample=async=1:first_pts=0',
          '-fps_mode',
          'vfr',
        ],
        if (video) ...[
          '-map',
          '0:a:0?',
          '-c:v',
          'libx264',
          '-preset',
          'medium',
          '-crf',
          [28, 23, 18][quality.index].toString(),
          '-pix_fmt',
          'yuv420p',
          '-c:a',
          'aac',
          '-b:a',
          '128k',
          '-movflags',
          '+faststart',
        ] else ...[
          '-frames:v',
          '1',
          if (extension == '.png') ...[
            '-c:v',
            'png',
            '-compression_level',
            '9',
          ] else if (extension == '.webp') ...[
            '-c:v',
            'libwebp',
            '-quality',
            [65, 80, 92][quality.index].toString(),
          ] else ...[
            '-c:v',
            'mjpeg',
            '-q:v',
            [8, 5, 2][quality.index].toString(),
          ],
        ],
        if (!Platform.isAndroid) ...['-progress', 'pipe:1'],
        '-nostats',
        output.path,
      ];
      if (_cancelled) return null;
      final exitCode = Platform.isAndroid
          ? await _runAndroid(args, onProgress)
          : await _runProcess(args, onProgress);
      if (_cancelled) return null;
      if (exitCode.code != 0) {
        throw CompressionFailure(
          exitCode.errors.trim().isEmpty
              ? 'FFmpeg failed (exit ${exitCode.code}).'
              : exitCode.errors.trim(),
          shared: exitCode.errors.toLowerCase().contains('no space left'),
        );
      }
      if (await File(output.path).length() == 0) {
        throw const CompressionFailure('FFmpeg produced an empty file.');
      }
      _outputs[output] = workspace;
      retained = true;
      return output;
    } on AndroidEncodingFailure catch (error) {
      throw CompressionFailure(error.message, shared: true);
    } on ProcessException {
      throw const CompressionFailure(
        'Cannot start the bundled FFmpeg. Keep the complete app folder together.',
        shared: true,
      );
    } finally {
      _process = null;
      if (!retained && workspace != null) {
        try {
          await workspace.delete(recursive: true);
        } on FileSystemException {
          // A locked cache file must not hide the original encoding error.
        }
      }
      _running = false;
    }
  }

  Future<({int code, String errors})> _runAndroid(
    List<String> args,
    void Function(Duration)? onProgress,
  ) async {
    final result = await _androidEncoder.encode(args, onProgress: onProgress);
    if (result.cancelled) _cancelled = true;
    return (code: result.code, errors: result.errors);
  }

  Future<({int code, String errors})> _runProcess(
    List<String> args,
    void Function(Duration)? onProgress,
  ) async {
    final process = await Process.start(executable, args, runInShell: false);
    _process = process;
    if (_cancelled) process.kill();
    var errors = '';
    final stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((text) {
          errors += text;
          if (errors.length > 4096) {
            errors = errors.substring(errors.length - 4096);
          }
        });
    final stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
          if (line.startsWith('out_time_us=')) {
            final microseconds = int.tryParse(line.substring(12));
            if (microseconds != null && microseconds >= 0) {
              onProgress?.call(Duration(microseconds: microseconds));
            }
          }
        });
    final code = await process.exitCode;
    await Future.wait([stdout, stderr]);
    return (code: code, errors: errors);
  }

  static String _seconds(Duration value) =>
      (value.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(
        6,
      );

  Future<void> discard(CompletedOutput output) async {
    final directory = _outputs[output];
    if (directory == null) {
      throw StateError('This output is not owned by this encoder.');
    }
    await directory.delete(recursive: true);
    _outputs.remove(output);
  }
}
