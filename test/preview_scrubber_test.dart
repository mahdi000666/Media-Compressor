import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/video_cutter/preview_scrubber.dart';

void main() {
  testWidgets('rapid dragging leaves time to display frames while held', (
    tester,
  ) async {
    final presented = <Duration>[];
    final seeks = <Duration>[];
    Timer? render;
    final scrubber = PreviewScrubber(
      pause: () async {},
      seek: (target) async {
        seeks.add(target);
        render?.cancel();
        render = Timer(const Duration(milliseconds: 50), () {
          presented.add(target);
        });
      },
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
    expect(seeks.length, lessThanOrEqualTo(3));
    scrubber.finish();
    await tester.pump();
    expect(seeks.last, const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 50));
    expect(presented.last, const Duration(seconds: 2));
  });

  testWidgets('uses the latest target, one pause and a final seek on release', (
    tester,
  ) async {
    var pauses = 0;
    final seeks = <Duration>[];
    final scrubber = PreviewScrubber(
      pause: () async {
        pauses++;
      },
      seek: (target) async {
        seeks.add(target);
      },
    );
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.update(const Duration(milliseconds: 200));
    scrubber.update(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 40));
    expect(seeks, [const Duration(milliseconds: 100)]);
    await tester.pump(const Duration(milliseconds: 40));
    expect(seeks.last, const Duration(milliseconds: 300));
    scrubber.update(const Duration(milliseconds: 400));
    scrubber.finish();
    await tester.pump();
    expect(pauses, 1);
    expect(seeks, [
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 300),
      const Duration(milliseconds: 400),
    ]);
    await tester.pump(const Duration(seconds: 1));
    expect(seeks.length, 3);
    scrubber.update(const Duration(milliseconds: 500));
    await tester.pump();
    expect(pauses, 2);
    scrubber.finish();
    await tester.pump();
    scrubber.dispose();
  });

  testWidgets('release flushes the newest target after an in-flight seek', (
    tester,
  ) async {
    final first = Completer<void>();
    final seeks = <Duration>[];
    final scrubber = PreviewScrubber(
      pause: () async {},
      seek: (target) {
        seeks.add(target);
        return seeks.length == 1 ? first.future : Future.value();
      },
    );
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.update(const Duration(milliseconds: 200));
    scrubber.update(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 200));
    scrubber.finish();
    await tester.pump();
    expect(seeks, [const Duration(milliseconds: 100)]);
    first.complete();
    await tester.pump();
    expect(seeks, [
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 900),
    ]);
    scrubber.dispose();
  });

  testWidgets('cancel drops pending targets even during an in-flight seek', (
    tester,
  ) async {
    final first = Completer<void>();
    final seeks = <Duration>[];
    final scrubber = PreviewScrubber(
      pause: () async {},
      seek: (target) {
        seeks.add(target);
        return seeks.length == 1 ? first.future : Future.value();
      },
    );
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.update(const Duration(milliseconds: 900));
    scrubber.finish();
    scrubber.cancel();
    first.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(seeks, [const Duration(milliseconds: 100)]);
    scrubber.dispose();
  });

  for (final inFlight in [false, true]) {
    testWidgets(
      'release does not repeat a final seek that is ${inFlight ? 'in flight' : 'settled'}',
      (tester) async {
        final first = Completer<void>();
        final seeks = <Duration>[];
        var pauses = 0;
        final scrubber = PreviewScrubber(
          pause: () async => pauses++,
          seek: (target) {
            seeks.add(target);
            return seeks.length == 1 ? first.future : Future.value();
          },
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
        expect(seeks, [const Duration(milliseconds: 100)]);
        expect(pauses, 1);
        scrubber.update(const Duration(milliseconds: 200));
        await tester.pump();
        expect(pauses, 2);
        expect(seeks.last, const Duration(milliseconds: 200));
        scrubber.finish();
        await tester.pump();
        expect(seeks.length, 2);
      },
    );
  }

  testWidgets('a new drag pauses again while the previous seek is in flight', (
    tester,
  ) async {
    final first = Completer<void>();
    final seeks = <Duration>[];
    var pauses = 0;
    final scrubber = PreviewScrubber(
      pause: () async => pauses++,
      seek: (target) {
        seeks.add(target);
        return seeks.length == 1 ? first.future : Future.value();
      },
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
    expect(seeks, [
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 900),
    ]);
    scrubber.finish();
    await tester.pump();
    expect(seeks.length, 2);
  });

  testWidgets(
    'release during pause still sends the final pending target once',
    (tester) async {
      final pause = Completer<void>();
      final seeks = <Duration>[];
      final scrubber = PreviewScrubber(
        pause: () => pause.future,
        seek: (target) async => seeks.add(target),
      );
      addTearDown(scrubber.dispose);
      scrubber.update(const Duration(milliseconds: 100));
      await tester.pump();
      scrubber.update(const Duration(milliseconds: 900));
      scrubber.finish();
      await tester.pump();
      expect(seeks, isEmpty);
      pause.complete();
      await tester.pump(const Duration(seconds: 1));
      expect(seeks, [const Duration(milliseconds: 900)]);
    },
  );

  testWidgets('dispose prevents seeking after a pending pause completes', (
    tester,
  ) async {
    final pause = Completer<void>();
    final seeks = <Duration>[];
    final scrubber = PreviewScrubber(
      pause: () => pause.future,
      seek: (target) async {
        seeks.add(target);
      },
    );
    scrubber.update(const Duration(milliseconds: 100));
    await tester.pump();
    scrubber.dispose();
    pause.complete();
    await tester.pump(const Duration(seconds: 1));
    scrubber.update(const Duration(milliseconds: 900));
    scrubber.finish();
    await tester.pump();
    expect(seeks, isEmpty);
  });
}
