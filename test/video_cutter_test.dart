import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/compression/ffmpeg_compressor.dart';
import 'package:media_compressor/media_files/media_files.dart';
import 'package:media_compressor/media_files/windows_export.dart';
import 'package:media_compressor/video_cutter/cut_plan.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

VideoSection section(int start, int end) =>
    (start: Duration(milliseconds: start), end: Duration(milliseconds: end));

void main() {
  test(
    'remove mode joins the complement; clip mode retains individual sections',
    () {
      final selected = [section(3000, 3500), section(1000, 2000)];
      expect(
        planCuts(selected, const Duration(seconds: 4), CutMode.removeSections),
        [
          [section(0, 1000), section(2000, 3000), section(3500, 4000)],
        ],
      );
      expect(
        planCuts(selected, const Duration(seconds: 4), CutMode.exportClips),
        [
          [section(1000, 2000)],
          [section(3000, 3500)],
        ],
      );
    },
  );
  test('invalid, overlapping and whole-video removal plans are rejected', () {
    for (final sections in [
      <VideoSection>[],
      [section(-1, 10)],
      [section(1, 1)],
      [section(0, 5000)],
      [section(0, 2000), section(1000, 3000)],
      [section(0, 4000)],
    ]) {
      expect(
        () => planCuts(
          sections,
          const Duration(seconds: 4),
          CutMode.removeSections,
        ),
        throwsArgumentError,
      );
    }
    expect(
      planCuts(
        [section(0, 1000), section(1000, 4000)],
        const Duration(seconds: 4),
        CutMode.exportClips,
      ).length,
      2,
    );
  });

  test('a single range directly drives removal or one clip', () {
    final range = section(800, 2200);
    expect(cutOutputName('movie ü', CutMode.removeSections), 'movie ü_Cut.mp4');
    expect(cutOutputName('movie ü', CutMode.exportClips), 'movie ü_Clip.mp4');
    expect(
      planCuts([range], const Duration(seconds: 4), CutMode.removeSections),
      [
        [section(0, 800), section(2200, 4000)],
      ],
    );
    expect(planCuts([range], const Duration(seconds: 4), CutMode.exportClips), [
      [range],
    ]);
  });

  group('Real video cutting', () {
    final bin = p.absolute('.tools/ffmpeg-8.1.2-essentials_build/bin');
    late Directory root;
    late File input;
    late FfmpegCompressor encoder;
    late MediaSource source;

    Future<ProcessResult> ffmpeg(
      List<String> args, {
      bool binary = false,
    }) async {
      final result = await Process.run(p.join(bin, 'ffmpeg.exe'), [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-n',
        ...args,
      ], stdoutEncoding: binary ? null : utf8);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return result;
    }

    Future<void> verify(
      CompletedOutput output,
      double duration,
      List<int> first,
      List<int> last,
    ) async {
      final probe = await Process.run(p.join(bin, 'ffprobe.exe'), [
        '-v',
        'error',
        '-show_format',
        '-show_streams',
        '-of',
        'json',
        output.path,
      ]);
      expect(probe.exitCode, 0);
      final json = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
      expect(
        double.parse(json['format']['duration'] as String),
        closeTo(duration, 0.12),
      );
      final streams = json['streams'] as List;
      expect(streams.any((stream) => stream['codec_name'] == 'aac'), isTrue);
      for (final stream in streams) {
        expect(double.parse(stream['start_time'] as String), closeTo(0, 0.06));
        expect(
          double.parse(stream['duration'] as String),
          closeTo(duration, 0.12),
        );
      }
      for (final entry in [
        (time: 0.1, expected: first),
        (time: duration - 0.1, expected: last),
      ]) {
        final frame = await ffmpeg([
          '-ss',
          '${entry.time}',
          '-i',
          output.path,
          '-frames:v',
          '1',
          '-vf',
          'scale=1:1',
          '-pix_fmt',
          'rgb24',
          '-f',
          'rawvideo',
          'pipe:1',
        ], binary: true);
        final pixel = frame.stdout as List<int>;
        expect(pixel.length, 3);
        for (var channel = 0; channel < 3; channel++) {
          expect(pixel[channel], closeTo(entry.expected[channel], 12));
        }
      }
      await ffmpeg(['-i', output.path, '-f', 'null', '-']);
    }

    setUpAll(() async {
      root = await Directory.systemTemp.createTemp('compressor-cut-test-');
      input = File(p.join(root.path, "source ' ü &.mp4"));
      await ffmpeg([
        for (final color in ['red', 'green', 'blue', 'yellow']) ...[
          '-f',
          'lavfi',
          '-i',
          'color=c=$color:s=160x120:r=25:d=1',
        ],
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=4',
        '-filter_complex',
        '[0:v][1:v][2:v][3:v]concat=n=4:v=1:a=0[v]',
        '-map',
        '[v]',
        '-map',
        '4:a',
        '-c:v',
        'libx264',
        '-g',
        '250',
        '-sc_threshold',
        '0',
        '-c:a',
        'aac',
        input.path,
      ]);
      source = MediaSource(
        reference: input.path,
        displayName: p.basename(input.path),
        kind: MediaKind.video,
      );
      encoder = FfmpegCompressor(
        temporaryDirectory: Directory(p.join(root.path, 'cache')),
        executable: p.join(bin, 'ffmpeg.exe'),
      );
    });
    tearDownAll(() => root.delete(recursive: true));

    test(
      'removes middle sections with correct content, duration and audio',
      () async {
        final before = await sha256.bind(input.openRead()).first;
        final kept = planCuts(
          [section(1000, 3000)],
          const Duration(seconds: 4),
          CutMode.removeSections,
        ).single;
        final output = (await encoder.compress(
          source,
          sections: kept,
          suggestedName: 'cut.mp4',
        ))!;
        await verify(output, 2, [255, 0, 0], [255, 255, 0]);
        final folder = await Directory(p.join(root.path, 'exports')).create();
        final existing = await File(p.join(folder.path, 'cut.mp4'))
            .writeAsString('Existing export');
        final result = await saveWindowsOutput(
          output,
          OutputFolder(reference: folder.path, displayName: 'exports'),
          libraryPath: p.absolute(
            'build/windows/x64/runner/Debug/media_files_native.dll',
          ),
        );
        expect(result, isA<FileSuccess<SavedMedia>>());
        final saved = (result as FileSuccess<SavedMedia>).value;
        expect(saved.reference, isNot(existing.path));
        expect(
          await sha256.bind(File(saved.reference).openRead()).first,
          await sha256.bind(File(output.path).openRead()).first,
        );
        expect(await existing.readAsString(), 'Existing export');
        expect(await sha256.bind(input.openRead()).first, before);
        await encoder.discard(output);
      },
    );
    test('keeps the whole audio track when chunks straddle the cut', () async {
      final chunked = p.join(root.path, 'chunked.mp4');
      await ffmpeg([
        '-i',
        input.path,
        '-c',
        'copy',
        '-movflags',
        'frag_keyframe+empty_moov',
        '-frag_duration',
        '1000000',
        chunked,
      ]);
      final output = (await encoder.compress(
        MediaSource(
          reference: chunked,
          displayName: 'chunked.mp4',
          kind: MediaKind.video,
        ),
        sections: [section(500, 2500)],
      ))!;
      await verify(output, 2, [255, 0, 0], [0, 0, 255]);
      await encoder.discard(output);
    });
    test(
      'exports intervals inside a GOP rather than including earlier frames',
      () async {
        for (final entry in [
          (range: section(200, 800), color: [255, 0, 0]),
          (range: section(2200, 2800), color: [0, 0, 255]),
        ]) {
          final output = (await encoder.compress(
            source,
            sections: [entry.range],
          ))!;
          await verify(output, 0.6, entry.color, entry.color);
          await encoder.discard(output);
        }
      },
    );
    test('cuts a video that has no audio track', () async {
      final silent = p.join(root.path, 'silent.mp4');
      await ffmpeg(['-i', input.path, '-map', '0:v:0', '-c', 'copy', silent]);
      final output = (await encoder.compress(
        MediaSource(
          reference: silent,
          displayName: 'silent.mp4',
          kind: MediaKind.video,
        ),
        sections: [section(500, 1500)],
      ))!;
      await ffmpeg(['-i', output.path, '-f', 'null', '-']);
      expect(await File(output.path).length(), greaterThan(0));
      await encoder.discard(output);
    });

    for (final framedrop in [false, true]) {
      test(
        'native preview seeks accurately while paused${framedrop ? ' with pre-target frame dropping' : ''}',
        () async {
          MediaKit.ensureInitialized(
            libmpv: p.absolute('build/windows/x64/runner/Release/libmpv-2.dll'),
          );
          final player = Player(
            configuration: const PlayerConfiguration(
              vo: 'null',
              protocolWhitelist: ['file', 'pipe'],
            ),
          );
          try {
            final native = player.platform as NativePlayer;
            if (framedrop) {
              await native.setProperty('hr-seek-framedrop', 'yes');
            }
            expect(await native.getProperty('hr-seek'), 'yes');
            expect(
              await native.getProperty('hr-seek-framedrop'),
              framedrop ? 'yes' : 'no',
            );
            final duration = player.stream.duration
                .firstWhere((value) => value > Duration.zero)
                .timeout(const Duration(seconds: 10));
            await player.open(Media(input.uri.toString()), play: false);
            expect((await duration).inMilliseconds, closeTo(4000, 100));
            for (final milliseconds in [2200, 320]) {
              final before = player.state.position;
              final position = player.stream.position
                  .firstWhere(
                    (value) =>
                        (value - before).abs() >
                        const Duration(milliseconds: 100),
                  )
                  .timeout(const Duration(seconds: 10));
              await player.seek(Duration(milliseconds: milliseconds));
              expect(
                (await position).inMilliseconds,
                closeTo(milliseconds, 60),
              );
              expect(player.state.playing, isFalse);
            }
          } finally {
            await player.dispose();
          }
        },
      );
    }

    test(
      'native preview can switch between keyframe and precise seeks',
      () async {
        MediaKit.ensureInitialized(
          libmpv: p.absolute('build/windows/x64/runner/Release/libmpv-2.dll'),
        );
        final player = Player(
          configuration: const PlayerConfiguration(
            vo: 'null',
            protocolWhitelist: ['file', 'pipe'],
          ),
        );
        try {
          final native = player.platform as NativePlayer;
          expect(await native.getProperty('hr-seek'), 'yes');
          await native.setProperty('hr-seek', 'no');
          expect(await native.getProperty('hr-seek'), 'no');
          await native.setProperty('hr-seek', 'yes');
          expect(await native.getProperty('hr-seek'), 'yes');
        } finally {
          await player.dispose();
        }
      },
    );
  }, skip: !Platform.isWindows);
}
