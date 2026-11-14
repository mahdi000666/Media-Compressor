import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/video_cutter/preview_scrubber.dart';

void main() {
  testWidgets('rapid dragging shows preview frames and releases precisely', (
    tester,
  ) async {
    final presented = <Duration>[];
    final previews = <Duration>[];
    final exact = <Duration>[];
    Timer? render;
    final scrubber = PreviewScrubber(
      pause: () async {},
      preview: (target) async {
        previews.add(target);
        render?.cancel();
        render = Timer(const Duration(milliseconds: 50), () {
          presented.add(target);
        });
      },
      seek: (target) async => exact.add(target),
    );
    addTearDown(() {
      scrubber.dispose();
      render?.cancel();
    });
    for (var index = 1; index <= 20; index++) {
      scrubber.update(Duration(milliseconds: index * 100));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(presented, isNotEmpty);
    expect(previews.length, lessThanOrEqualTo(3));
    scrubber.finish();
    await tester.pump();
    expect(exact, [const Duration(seconds: 2)]);
    await tester.pump(const Duration(milliseconds: 50));
    expect(presented, isNotEmpty);
  });

  testWidgets(
    'uses the latest target, one pause and one precise release seek',
    (tester) async {
      var pauses = 0;
      final previews = <Duration>[];
      final exact = <Duration>[];
      final scrubber = PreviewScrubber(
        pause: () async {
          pauses++;
        },
        preview: (target) async {
          previews.add(target);
        },
        seek: (target) async {
          exact.add(target);
        },
      );
      scrubber.update(const Duration(milliseconds: 100));
      await tester.pump();
      scrubber.update(const Duration(milliseconds: 200));
      scrubber.update(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 40));
      expect(previews, [const Duration(milliseconds: 100)]);
      await tester.pump(const Duration(milliseconds: 40));
      expect(previews.last, const Duration(milliseconds: 300));
      scrubber.update(const Duration(milliseconds: 400));
      scrubber.finish();
      await tester.pump();
      expect(pauses, 1);
      expect(previews, [
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 300),
      ]);
      expect(exact, [const Duration(milliseconds: 400)]);
      await tester.pump(const Duration(seconds: 1));
      expect(exact, [const Duration(milliseconds: 400)]);
      scrubber.update(const Duration(milliseconds: 500));
      await tester.pump();
      expect(pauses, 2);
      expect(previews.last, const Duration(milliseconds: 500));
      scrubber.finish();
      await tester.pump();
      expect(exact, [
        const Duration(milliseconds: 400),
        const Duration(milliseconds: 500),
      ]);
      scrubber.dispose();
    },
  );

  testWidgets('release flushes the newest target after an in-flight preview', (
    tester,
  ) async {
    final first = Completer<void>();
    final previews = <Duration>[];
    final exact = <Duration>[];
    final scrubber = PreviewScrubber(
      pause: () async {},
      preview: (target) {
        previews.add(target);
        return previews.length == 1 ? first.future : Future.value();
      },
      seek: (target) async => exact.add(target),
    );
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.update(const Duration(milliseconds: 200));
    scrubber.update(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 200));
    scrubber.finish();
    await tester.pump();
    expect(previews, [const Duration(milliseconds: 100)]);
    expect(exact, isEmpty);
    first.complete();
    await tester.pump();
    expect(exact, [const Duration(milliseconds: 900)]);
    scrubber.dispose();
  });

  testWidgets('cancel drops pending targets and skips the precise seek', (
    tester,
  ) async {
    final first = Completer<void>();
    final previews = <Duration>[];
    final exact = <Duration>[];
    final scrubber = PreviewScrubber(
      pause: () async {},
      preview: (target) {
        previews.add(target);
        return previews.length == 1 ? first.future : Future.value();
      },
      seek: (target) async => exact.add(target),
    );
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.update(const Duration(milliseconds: 900));
    scrubber.finish();
    scrubber.cancel();
    first.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(previews, [const Duration(milliseconds: 100)]);
    expect(exact, isEmpty);
    scrubber.dispose();
  });

  for (final inFlight in [false, true]) {
    testWidgets('release sends one precise seek when finish is repeated '
        '${inFlight ? 'in flight' : 'settled'}', (tester) async {
      final first = Completer<void>();
      final previews = <Duration>[];
      final exact = <Duration>[];
      var pauses = 0;
      final scrubber = PreviewScrubber(
        pause: () async => pauses++,
        preview: (target) {
          previews.add(target);
          return previews.length == 1 ? first.future : Future.value();
        },
        seek: (target) async => exact.add(target),
      );
      addTearDown(scrubber.dispose);
      scrubber.update(const Duration(milliseconds: 100));
      await tester.pump();
      if (!inFlight) {
        first.complete();
        await tester.pump(const Duration(seconds: 2));
      }
      scrubber.finish();
      await tester.pump();
      if (inFlight) first.complete();
      await tester.pump();
      scrubber.finish();
      await tester.pump(const Duration(seconds: 1));
      expect(exact, [const Duration(milliseconds: 100)]);
      expect(pauses, 1);
      scrubber.update(const Duration(milliseconds: 200));
      await tester.pump();
      expect(pauses, 2);
      expect(previews.last, const Duration(milliseconds: 200));
      scrubber.finish();
      await tester.pump();
      expect(exact, [
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 200),
      ]);
    });
  }

  testWidgets('a new drag cancels a queued precise seek and pauses again', (
    tester,
  ) async {
    final first = Completer<void>();
    final previews = <Duration>[];
    final exact = <Duration>[];
    var pauses = 0;
    final scrubber = PreviewScrubber(
      pause: () async => pauses++,
      preview: (target) {
        previews.add(target);
        return previews.length == 1 ? first.future : Future.value();
      },
      seek: (target) async => exact.add(target),
    );
    addTearDown(scrubber.dispose);
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.finish();
    scrubber.update(const Duration(milliseconds: 900));
    await tester.pump();
    first.complete();
    await tester.pump(const Duration(milliseconds: 80));
    expect(pauses, 2);
    expect(previews, [
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 900),
    ]);
    expect(exact, isEmpty);
    scrubber.finish();
    await tester.pump();
    expect(exact, [const Duration(milliseconds: 900)]);
  });

  testWidgets('release during pause goes straight to the precise target', (
    tester,
  ) async {
    final pause = Completer<void>();
    final previews = <Duration>[];
    final exact = <Duration>[];
    final scrubber = PreviewScrubber(
      pause: () => pause.future,
      preview: (target) async => previews.add(target),
      seek: (target) async => exact.add(target),
    );
    addTearDown(scrubber.dispose);
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.update(const Duration(milliseconds: 900));
    scrubber.finish();
    await tester.pump();
    expect(previews, isEmpty);
    expect(exact, isEmpty);
    pause.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(previews, isEmpty);
    expect(exact, [const Duration(milliseconds: 900)]);
  });

  testWidgets('dispose prevents seeking after a pending pause completes', (
    tester,
  ) async {
    final pause = Completer<void>();
    final previews = <Duration>[];
    final exact = <Duration>[];
    final scrubber = PreviewScrubber(
      pause: () => pause.future,
      preview: (target) async => previews.add(target),
      seek: (target) async => exact.add(target),
    );
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.dispose();
    pause.complete();
    await tester.pump(const Duration(seconds: 1));
    scrubber.update(const Duration(milliseconds: 900));
    scrubber.finish();
    await tester.pump();
    expect(previews, isEmpty);
    expect(exact, isEmpty);
  });

  testWidgets(
    'without a fast preview callback both seeks use the precise one',
    (tester) async {
      final seeks = <Duration>[];
      final scrubber = PreviewScrubber(
        pause: () async {},
        seek: (target) async => seeks.add(target),
      );
      addTearDown(scrubber.dispose);
      scrubber.update(const Duration(milliseconds: 100));
      await tester.pump();
      expect(seeks, [const Duration(milliseconds: 100)]);
      scrubber.finish();
      await tester.pump();
      expect(seeks, [
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 100),
      ]);
    },
  );
}
