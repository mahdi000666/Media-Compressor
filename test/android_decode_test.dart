import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/compression/ffmpeg_compressor.dart';
import 'package:media_compressor/media_files/media_files.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.local.media_compressor/ffmpeg');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late MediaSource source;
  late List<List<String>> attempts;

  FfmpegCompressor encoder({bool hardwareDecode = true}) => FfmpegCompressor(
    temporaryDirectory: Directory(p.join(root.path, 'cache')),
    isAndroid: true,
    hardwareDecode: hardwareDecode,
  );

  String outputCodec(List<String> args) => args[args.lastIndexOf('-c:v') + 1];

  void mockEncoder({
    int failures = 0,
    bool cancelled = false,
    bool empty = false,
  }) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'encode');
      final args = List<String>.from(call.arguments['arguments'] as List);
      attempts.add(args);
      final output = File(args.last);
      expect(await output.exists(), isFalse);
      final failed = attempts.length <= failures;
      if (!empty || failed) {
        await output.writeAsString(failed ? 'partial' : 'encoded');
      }
      return {
        'code': failed ? 1 : 0,
        'errors': failed ? 'Codec unavailable' : '',
        'cancelled': cancelled,
      };
    });
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('android-decode-test-');
    final input = await File(p.join(root.path, 'input.mp4'))
        .writeAsString('original');
    source = MediaSource(
      reference: input.path,
      displayName: 'input.mp4',
      kind: MediaKind.video,
    );
    attempts = [];
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test('hardware decoding is opt-in', () async {
    mockEncoder();
    final compressor = FfmpegCompressor(
      temporaryDirectory: Directory(p.join(root.path, 'cache')),
      isAndroid: true,
    );
    expect(compressor.hardwareDecode, isFalse);
    final output = (await compressor.compress(source))!;
    expect(attempts, hasLength(1));
    expect(attempts.single, isNot(contains('-hwaccel')));
    expect(outputCodec(attempts.single), 'h264_mediacodec');
    await compressor.discard(output);
  });

  test(
    'hardware decode is an input option, with unchanged output settings',
    () async {
      mockEncoder();
      final compressor = encoder();
      final output = (await compressor.compress(source, maxEdge: 1280))!;
      final args = attempts.single;
      expect(args.indexOf('-hwaccel'), lessThan(args.indexOf('-i')));
      expect(args[args.indexOf('-hwaccel') + 1], 'mediacodec');
      expect(outputCodec(args), 'h264_mediacodec');
      expect(args[args.indexOf('-pix_fmt') + 1], 'yuv420p');
      expect(args[args.indexOf('-b:v') + 1], '1300000');
      expect(args[args.indexOf('-c:a') + 1], 'aac');
      expect(args, contains('0:a:0?'));
      expect(args, contains('-n'));
      expect(args, isNot(contains('-progress')));
      expect(await File(source.reference).readAsString(), 'original');
      await compressor.discard(output);
    },
  );

  test('tries NV12 before falling back to software decoding', () async {
    mockEncoder(failures: 1);
    final compressor = encoder();
    final output = (await compressor.compress(source))!;
    expect(attempts, hasLength(2));
    expect(attempts.every((args) => args.contains('-hwaccel')), isTrue);
    expect(attempts.last[attempts.last.indexOf('-pix_fmt') + 1], 'nv12');
    await compressor.discard(output);
  });

  test(
    'decode failure preserves the existing hardware encoder fallback',
    () async {
      mockEncoder(failures: 2);
      final progress = <Duration>[];
      final compressor = encoder();
      final output = (await compressor.compress(
        source,
        onProgress: progress.add,
      ))!;
      expect(attempts, hasLength(3));
      expect(
        attempts.take(2).every((args) => args.contains('-hwaccel')),
        isTrue,
      );
      expect(attempts.last, isNot(contains('-hwaccel')));
      expect(outputCodec(attempts.last), 'h264_mediacodec');
      expect(progress, [Duration.zero, Duration.zero]);
      await compressor.discard(output);
    },
  );

  test('falls back to x264 only after hardware encode attempts fail', () async {
    mockEncoder(failures: 4);
    final compressor = encoder();
    final output = (await compressor.compress(source))!;
    expect(attempts, hasLength(5));
    expect(attempts.last, isNot(contains('-hwaccel')));
    expect(outputCodec(attempts.last), 'libx264');
    expect(attempts.last[attempts.last.indexOf('-preset') + 1], 'veryfast');
    await compressor.discard(output);
  });

  test('cut attempts retain concat metadata and audio selection', () async {
    mockEncoder(failures: 2);
    final compressor = encoder();
    final output = (await compressor.compress(
      source,
      sections: [
        (start: const Duration(seconds: 2), end: const Duration(seconds: 5)),
      ],
    ))!;
    final args = attempts.last;
    expect(args, contains('-segment_time_metadata'));
    expect(args[args.indexOf('-f') + 1], 'concat');
    expect(
      args[args.indexOf('-vf') + 1],
      startsWith('select=concatdec_select,'),
    );
    expect(
      args[args.indexOf('-af') + 1],
      'aselect=concatdec_select,asetpts=PTS-STARTPTS,aresample=async=1:first_pts=0',
    );
    final playlist = File(args[args.indexOf('-i') + 1]);
    expect(await playlist.readAsString(), contains('outpoint 7.000000'));
    await compressor.discard(output);
  });

  test('images do not attempt hardware decode or encode', () async {
    mockEncoder();
    final compressor = encoder();
    final output = (await compressor.compress(
      MediaSource(
        reference: source.reference,
        displayName: 'input.png',
        kind: MediaKind.image,
      ),
    ))!;
    expect(attempts, hasLength(1));
    expect(attempts.single, isNot(contains('-hwaccel')));
    expect(outputCodec(attempts.single), 'png');
    await compressor.discard(output);
  });

  test('cancellation skips fallback and cleans its partial output', () async {
    mockEncoder(cancelled: true);
    expect(await encoder().compress(source), isNull);
    expect(attempts, hasLength(1));
    expect(
      await Directory(p.join(root.path, 'cache')).list().toList(),
      isEmpty,
    );
    expect(await File(source.reference).readAsString(), 'original');
  });

  test('empty successful attempts do not bypass fallback', () async {
    mockEncoder(empty: true);
    await expectLater(
      encoder().compress(source),
      throwsA(isA<CompressionFailure>()),
    );
    expect(attempts, hasLength(5));
    expect(
      await Directory(p.join(root.path, 'cache')).list().toList(),
      isEmpty,
    );
  });

  test('all failed attempts clean only their workspace', () async {
    mockEncoder(failures: 5);
    await expectLater(
      encoder().compress(source),
      throwsA(
        isA<CompressionFailure>().having(
          (error) => error.message,
          'message',
          'Codec unavailable',
        ),
      ),
    );
    expect(attempts, hasLength(5));
    expect(
      await Directory(p.join(root.path, 'cache')).list().toList(),
      isEmpty,
    );
    expect(await File(source.reference).readAsString(), 'original');
  });
}
