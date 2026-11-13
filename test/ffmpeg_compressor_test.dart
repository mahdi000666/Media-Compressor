import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/compression/ffmpeg_compressor.dart';
import 'package:media_compressor/media_files/media_files.dart';
import 'package:media_compressor/media_files/windows_export.dart';
import 'package:path/path.dart' as p;

void main() {
  final bin = p.absolute('.tools/ffmpeg-8.1.2-essentials_build/bin');
  late Directory root;
  late FfmpegCompressor encoder;

  Future<void> ffmpeg(List<String> args) async {
    final result = await Process.run(p.join(bin, 'ffmpeg.exe'), [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-n',
      ...args,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  Future<Map<String, dynamic>> probe(String path) async {
    final result = await Process.run(p.join(bin, 'ffprobe.exe'), [
      '-v',
      'error',
      '-show_streams',
      '-of',
      'json',
      path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (jsonDecode(result.stdout as String)
            as Map<String, dynamic>)['streams'][0]
        as Map<String, dynamic>;
  }

  group('Real FFmpeg encoding', () {
    setUp(() async {
      root = await Directory.systemTemp.createTemp('compressor-encode-test-');
      encoder = FfmpegCompressor(
        temporaryDirectory: Directory(p.join(root.path, 'cache')),
        executable: p.join(bin, 'ffmpeg.exe'),
      );
    });
    tearDown(() async => root.delete(recursive: true));

    test(
      'compresses video, retains audio, safely exports and preserves original',
      () async {
        final input = File(p.join(root.path, 'original & ü.mp4'));
        await ffmpeg([
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=640x360:rate=15',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440',
          '-t',
          '2',
          '-c:v',
          'libx264',
          '-crf',
          '0',
          '-c:a',
          'aac',
          input.path,
        ]);
        final before = await sha256.bind(input.openRead()).first;
        final progress = <Duration>[];
        final output = (await encoder.compress(
          MediaSource(
            reference: input.path,
            displayName: p.basename(input.path),
            kind: MediaKind.video,
          ),
          maxEdge: 320,
          onProgress: progress.add,
        ))!;
        expect(output.suggestedName, 'original & ü_Compress.mp4');
        expect(
          await File(output.path).length(),
          lessThan(await input.length()),
        );
        final info = await probe(output.path);
        expect(info['codec_name'], 'h264');
        expect(info['width'], 320);
        expect(info['height'], 180);
        final audio = await Process.run(p.join(bin, 'ffprobe.exe'), [
          '-v',
          'error',
          '-select_streams',
          'a:0',
          '-show_entries',
          'stream=codec_name',
          '-of',
          'csv=p=0',
          output.path,
        ]);
        expect((audio.stdout as String).trim(), 'aac');
        expect(progress, isNotEmpty);
        final saved = await saveWindowsOutput(
          output,
          OutputFolder(reference: root.path, displayName: 'Test'),
          libraryPath: p.absolute(
            'build/windows/x64/runner/Debug/media_files_native.dll',
          ),
        );
        expect(saved, isA<FileSuccess<SavedMedia>>());
        final receipt = (saved as FileSuccess<SavedMedia>).value;
        expect(receipt.displayName, 'original & ü_Compress.mp4');
        expect(
          await sha256.bind(File(receipt.reference).openRead()).first,
          await sha256.bind(File(output.path).openRead()).first,
        );
        await encoder.discard(output);
        expect(await File(output.path).exists(), isFalse);
        expect(await sha256.bind(input.openRead()).first, before);
        expect(await File(receipt.reference).exists(), isTrue);
        final decoded = await Process.run(p.join(bin, 'ffmpeg.exe'), [
          '-v',
          'error',
          '-i',
          receipt.reference,
          '-f',
          'null',
          '-',
        ]);
        expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
      },
    );

    for (final extension in ['jpg', 'png', 'webp']) {
      test(
        'resizes and re-encodes $extension without editing the input',
        () async {
          final input = File(p.join(root.path, 'image.$extension'));
          await ffmpeg([
            '-f',
            'lavfi',
            '-i',
            'testsrc2=size=400x300',
            '-frames:v',
            '1',
            input.path,
          ]);
          final before = await sha256.bind(input.openRead()).first;
          final staged = await input.copy(p.join(root.path, 'staged.media'));
          final output = (await encoder.compress(
            MediaSource(
              reference: staged.path,
              displayName: p.basename(input.path),
              kind: MediaKind.image,
            ),
            maxEdge: 160,
          ))!;
          expect(output.suggestedName, 'image_Compress.$extension');
          final info = await probe(output.path);
          expect(info['width'], 160);
          expect(info['height'], 120);
          expect(p.extension(output.path), '.$extension');
          expect(await sha256.bind(input.openRead()).first, before);
          await encoder.discard(output);
        },
      );
    }

    test(
      'failed input stays intact; forged outputs cannot be discarded',
      () async {
        final input = await File(p.join(root.path, 'bad.mp4'))
            .writeAsString('not a video');
        await expectLater(
          encoder.compress(
            MediaSource(
              reference: input.path,
              displayName: 'bad.mp4',
              kind: MediaKind.video,
            ),
          ),
          throwsA(isA<CompressionFailure>()),
        );
        expect(await input.readAsString(), 'not a video');
        expect(
          await Directory(p.join(root.path, 'cache')).list().toList(),
          isEmpty,
        );
        await expectLater(
          encoder.discard(
            CompletedOutput(
              path: input.path,
              suggestedName: 'bad.mp4',
              mimeType: 'video/mp4',
            ),
          ),
          throwsStateError,
        );
        expect(await input.exists(), isTrue);
      },
    );

    test(
      'unavailable cache is a shared failure, not an input failure',
      () async {
        final input = await File(p.join(root.path, 'input.mp4'))
            .writeAsString('fixture');
        final blockedCache = await File(p.join(root.path, 'blocked-cache'))
            .writeAsString('keep');
        final blockedEncoder = FfmpegCompressor(
          temporaryDirectory: Directory(blockedCache.path),
          executable: p.join(bin, 'ffmpeg.exe'),
        );
        await expectLater(
          blockedEncoder.compress(
            MediaSource(
              reference: input.path,
              displayName: 'input.mp4',
              kind: MediaKind.video,
            ),
          ),
          throwsA(
            isA<CompressionFailure>().having(
              (error) => error.shared,
              'shared',
              isTrue,
            ),
          ),
        );
        expect(await input.readAsString(), 'fixture');
        expect(await blockedCache.readAsString(), 'keep');
      },
    );

    test('cancellation removes only its own temporary output', () async {
      final input = File(p.join(root.path, 'cancel.mp4'));
      await ffmpeg([
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=640x360:rate=15',
        '-t',
        '4',
        '-c:v',
        'libx264',
        '-crf',
        '0',
        input.path,
      ]);
      final before = await sha256.bind(input.openRead()).first;
      final result = encoder.compress(
        MediaSource(
          reference: input.path,
          displayName: 'cancel.mp4',
          kind: MediaKind.video,
        ),
        onProgress: (_) => encoder.cancel(),
      );
      expect(await result, isNull);
      expect(await sha256.bind(input.openRead()).first, before);
      expect(
        await Directory(p.join(root.path, 'cache')).list().toList(),
        isEmpty,
      );
    });
  }, skip: !Platform.isWindows);
}
