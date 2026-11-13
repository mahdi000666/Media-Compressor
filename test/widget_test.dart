import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/main.dart';
import 'package:media_compressor/compression/ffmpeg_compressor.dart';
import 'package:media_compressor/media_files/media_files.dart';
import 'package:media_compressor/media_files/android_media_files.dart';
import 'package:media_compressor/video_cutter/cutter_page.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets(
    'Android selection keeps opaque URIs and unknown sizes on a phone layout',
    (tester) async {
      const channel = MethodChannel('test/android-selection-ui');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var picks = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'folder') {
          return {
            'reference': 'content://fixture/tree/output',
            'displayName': 'Exports',
          };
        }
        expect(call.method, 'pick');
        if (picks++ > 0) return null;
        return {
          'sources': [
            {
              'reference': 'content://fixture/document/one',
              'displayName': 'same.mp4',
              'kind': 'video',
              'sizeBytes': null,
            },
            {
              'reference': 'content://fixture/document/two',
              'displayName': 'same.mp4',
              'kind': 'video',
              'sizeBytes': 1024,
            },
          ],
          'errors': [],
        };
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        return tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(420, 800));
      await tester.pumpWidget(
        const MaterialApp(
          home: CompressionPage(
            androidFiles: AndroidMediaFiles(channel: channel),
          ),
        ),
      );
      await tester.tap(find.text('Add files'));
      await tester.pumpAndSettle();
      expect(find.text('same.mp4'), findsNWidgets(2));
      expect(find.textContaining('Unknown size'), findsOneWidget);
      await tester.tap(find.text('Output folder'));
      await tester.pumpAndSettle();
      expect(find.text('Save to: Exports'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start compression'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Add files'));
      await tester.pumpAndSettle();
      expect(find.text('same.mp4'), findsNWidgets(2));
      await tester.tap(find.text('Clear list'));
      await tester.pumpAndSettle();
      expect(find.text('0 / 0 saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cutter range stays fully above its action separator', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [
      const Size(1280, 720),
      const Size(800, 600),
      const Size(420, 800),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          home: CutterPage(
            key: ValueKey(size),
            source: const MediaSource(
              reference: 'layout-fixture.mp4',
              displayName: 'layout-fixture.mp4',
              kind: MediaKind.video,
            ),
            quality: CompressionQuality.balanced,
          ),
        ),
      );
      await tester.pump();
      final range = tester.getRect(find.textContaining('Selected range:'));
      final slider = tester.getRect(find.byType(RangeSlider));
      final separator = tester.getRect(find.byType(Divider));
      expect(
        range.bottom,
        lessThanOrEqualTo(separator.top),
        reason:
            'Range text must not be clipped by the preview viewport at $size',
      );
      expect(slider.bottom, lessThanOrEqualTo(range.top));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('shows compression controls without starting a job', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Compressor'), findsOneWidget);
    expect(find.text('Add files'), findsOneWidget);
    expect(find.text('Output folder'), findsOneWidget);
    expect(find.text('No output folder selected'), findsOneWidget);
    expect(find.text('0 / 0 saved'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start compression'),
    );
    expect(start.onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Clear list'),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('Video → MP4'), findsNothing);
    expect(find.textContaining('Max edge:'), findsNothing);
    expect(find.textContaining('retry unsaved'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clears multiple selected rows without deleting their files', (
    tester,
  ) async {
    final fixtures = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp(
        'compressor-clear-test-',
      );
      final image = await File(p.join(root.path, 'picture.png'))
          .writeAsString('image fixture');
      final video = await File(p.join(root.path, 'video.mp4'))
          .writeAsString('video fixture');
      return (root, image, video);
    });
    final (root, image, video) = fixtures!;
    addTearDown(() => root.delete(recursive: true));
    final picked = [XFile(image.path), XFile(video.path)];
    final pendingPick = Completer<List<XFile>>();
    var picks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CompressionPage(
          pickFiles: () =>
              picks++ == 0 ? Future.value(picked) : pendingPick.future,
        ),
      ),
    );
    final add = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add files'),
    );
    await tester.runAsync(() => (add.onPressed! as Future<void> Function())());
    await tester.pumpAndSettle();
    expect(find.text('picture.png'), findsOneWidget);
    expect(find.text('video.mp4'), findsOneWidget);
    await tester.tap(find.text('Add files'));
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Clear list'),
          )
          .onPressed,
      isNull,
    );
    pendingPick.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('picture.png'), findsOneWidget);
    expect(find.text('video.mp4'), findsOneWidget);
    await tester.tap(find.text('Clear list'));
    await tester.pumpAndSettle();
    expect(find.text('picture.png'), findsNothing);
    expect(find.text('video.mp4'), findsNothing);
    expect(find.text('0 / 0 saved'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await image.readAsString(), 'image fixture');
      expect(await video.readAsString(), 'video fixture');
    });
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}
