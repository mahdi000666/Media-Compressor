import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/compression/android_ffmpeg.dart';
import 'package:media_compressor/media_files/android_media_files.dart';
import 'package:media_compressor/media_files/media_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const filesChannel = MethodChannel('test/android-files');
  const encoderChannel = MethodChannel('test/android-encoder');
  const files = AndroidMediaFiles(channel: filesChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const source = MediaSource(
    reference: 'content://fixture/document/1',
    displayName: 'video.mp4',
    kind: MediaKind.video,
  );
  const output = CompletedOutput(
    path: '/fixture/cache/output.mp4',
    suggestedName: 'video_Compress.mp4',
    mimeType: 'video/mp4',
  );
  const folder = OutputFolder(
    reference: 'content://fixture/tree/output',
    displayName: 'output',
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(filesChannel, null);
    messenger.setMockMethodCallHandler(encoderChannel, null);
  });

  test('document selection keeps opaque identities, order and unknown size without staging', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      calls.add(call.method);
      return {
        'sources': [
          {
            'reference': source.reference,
            'displayName': source.displayName,
            'kind': 'video',
            'sizeBytes': null,
          },
          {
            'reference': 'content://fixture/document/2',
            'displayName': source.displayName,
            'kind': 'video',
            'sizeBytes': 12,
          },
        ],
        'errors': [],
      };
    });
    final result =
        (await files.pickSources() as FileSuccess<PickedSources>).value;
    expect(result.sources.first.reference, source.reference);
    expect(result.sources.first.sizeBytes, isNull);
    expect(result.sources.last.identity, 'content://fixture/document/2');
    expect(calls, ['pick']);
  });

  test(
    'cancelled pickers return cancellation rather than replacing state',
    () async {
      messenger.setMockMethodCallHandler(filesChannel, (_) async => null);
      expect(await files.pickSources(), isA<FileCancelled<PickedSources>>());
      expect(
        await files.chooseOutputFolder(),
        isA<FileCancelled<OutputFolder>>(),
      );
    },
  );

  test(
    'preparation is on demand and original files cannot be released',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(filesChannel, (call) async {
        calls.add(call.method);
        if (call.method == 'prepare') {
          expect(call.arguments, {'reference': source.reference});
          return {'path': '/fixture/cache/staged.media', 'sizeBytes': 64};
        }
        return <String, Object?>{};
      });
      final input = (await files.prepareInput(
        source,
      ) as FileSuccess<PreparedInput>).value;
      expect(input.ownership, InputOwnership.temporary);
      expect(input.source, same(source));
      expect(input.sizeBytes, 64);
      expect(await files.releaseInput(input), isA<FileSuccess<void>>());
      expect(
        await files.releaseInput(
          const PreparedInput(
            source: source,
            path: 'original',
            sizeBytes: 1,
            ownership: InputOwnership.original,
          ),
        ),
        isA<FileFailure<void>>(),
      );
      expect(calls, ['prepare', 'release']);
    },
  );

  test('export preserves provider names and maps destination failure without cleanup calls', () async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      expect(call.method, 'save');
      expect(call.arguments, {
        'folder': folder.reference,
        'path': output.path,
        'name': output.suggestedName,
        'mimeType': output.mimeType,
      });
      if (attempts++ == 1) {
        throw PlatformException(
          code: 'noSpace',
          message: 'Destination full',
          details: {'scope': 'destination'},
        );
      }
      return {
        'reference': 'content://fixture/document/result',
        'displayName': 'video_Compress (1).mp4',
        'sizeBytes': 52,
      };
    });
    final saved = (await files.saveOutput(
      output,
      folder,
    ) as FileSuccess<SavedMedia>).value;
    expect(saved.displayName, 'video_Compress (1).mp4');
    final failure =
        await files.saveOutput(output, folder) as FileFailure<SavedMedia>;
    expect(failure.error.scope, FileErrorScope.destination);
    expect(failure.error.code, FileErrorCode.noSpace);
    expect(
      await files.saveOutput(output, folder),
      isA<FileSuccess<SavedMedia>>(),
    );
    expect(saved.reference, 'content://fixture/document/result');
    expect(output.path, '/fixture/cache/output.mp4');
    expect(attempts, 3);
  });

  test(
    'native encoder forwards arguments, scoped cancellation and progress',
    () async {
      final started = Completer<int>();
      final finished = Completer<Map<String, Object?>>();
      int? cancelledId;
      messenger.setMockMethodCallHandler(encoderChannel, (call) async {
        if (call.method == 'encode') {
          expect(call.arguments['arguments'], [
            '-i',
            '/fixture/input.mp4',
            '-n',
            '/fixture/output.mp4',
          ]);
          started.complete(call.arguments['id'] as int);
          return finished.future;
        }
        expect(call.method, 'cancel');
        cancelledId = call.arguments['id'] as int;
        return null;
      });
      final progress = <Duration>[];
      final encoder = AndroidFfmpeg(channel: encoderChannel);
      final pending = encoder.encode([
        '-i',
        '/fixture/input.mp4',
        '-n',
        '/fixture/output.mp4',
      ], onProgress: progress.add);
      final id = await started.future;
      await messenger.handlePlatformMessage(
        encoderChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('progress', {'id': id, 'microseconds': 1200000}),
        ),
        (_) {},
      );
      expect(progress, [const Duration(milliseconds: 1200)]);
      encoder.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(cancelledId, id);
      finished.complete({'code': 255, 'errors': '', 'cancelled': true});
      expect((await pending).cancelled, isTrue);
    },
  );

  test(
    'missing native encoder is an explicit shared-availability error',
    () async {
      messenger.setMockMethodCallHandler(
        encoderChannel,
        (_) async => throw PlatformException(
          code: 'unavailable',
          message: 'Library missing',
        ),
      );
      await expectLater(
        AndroidFfmpeg(channel: encoderChannel).encode(['-version']),
        throwsA(
          isA<AndroidEncodingFailure>().having(
            (error) => error.message,
            'message',
            'Library missing',
          ),
        ),
      );
    },
  );
}
