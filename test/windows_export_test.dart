import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/media_files/media_files.dart';
import 'package:media_compressor/media_files/windows_export.dart' as windows;
import 'package:path/path.dart' as p;

void main() {
  group('Windows exclusive copy', () {
    late Directory fixture;
    late File source;
    late Directory destination;

    setUp(() async {
      fixture = await Directory.systemTemp.createTemp(
        'media_compressor_export_',
      );
      source = await File(p.join(fixture.path, '输入-ä.mp4'))
          .writeAsString('source fixture');
      destination = await Directory(p.join(fixture.path, 'output')).create();
    });

    tearDown(() async {
      await fixture.delete(recursive: true);
    });

    test('copies a Unicode path with identical bytes', () async {
      final saved = File(p.join(destination.path, '视频-ä.mp4'));
      expect(await copyWindowsFileExclusive(source.path, saved.path), 0);
      expect(await _hash(saved), await _hash(source));
      expect(await saved.length(), await source.length());
    });

    test(
      'refuses an existing destination without changing either file',
      () async {
        final existing = await File(p.join(destination.path, 'existing.mp4'))
            .writeAsString('keep existing');
        final sourceHash = await _hash(source);
        final existingHash = await _hash(existing);
        expect(
          await copyWindowsFileExclusive(source.path, existing.path),
          isNot(0),
        );
        expect(await _hash(existing), existingHash);
        expect(await _hash(source), sourceHash);
      },
    );

    test(
      'refuses a same-source destination without changing its bytes',
      () async {
        final before = await _hash(source);
        expect(
          await copyWindowsFileExclusive(source.path, source.path),
          isNot(0),
        );
        expect(await _hash(source), before);
      },
    );

    test(
      'refuses a hard-link destination without changing its target',
      () async {
        final target = await File(p.join(fixture.path, 'target.mp4'))
            .writeAsString('keep target');
        final link = File(p.join(destination.path, 'hard-link.mp4'));
        _createHardLink(link.path, target.path);
        final before = await _hash(target);
        expect(
          await copyWindowsFileExclusive(source.path, link.path),
          isNot(0),
        );
        expect(await _hash(target), before);
        expect(await _hash(link), before);
      },
    );

    test(
      'refuses a symbolic-link destination without changing its target',
      () async {
        final target = await File(p.join(fixture.path, 'target.mp4'))
            .writeAsString('keep target');
        final link = Link(p.join(destination.path, 'symbolic-link.mp4'));
        if (!await _createSymbolicLink(link, target.path)) return;
        final before = await _hash(target);
        expect(
          await copyWindowsFileExclusive(source.path, link.path),
          isNot(0),
        );
        expect(await _hash(target), before);
        expect(
          await FileSystemEntity.type(link.path, followLinks: false),
          FileSystemEntityType.link,
        );
      },
    );

    test(
      'refuses a dangling symbolic link without creating its target',
      () async {
        final target = await File(p.join(fixture.path, 'target.mp4'))
            .writeAsString('temporary target');
        final link = Link(p.join(destination.path, 'dangling-link.mp4'));
        if (!await _createSymbolicLink(link, target.path)) return;
        await target.delete();
        expect(
          await copyWindowsFileExclusive(source.path, link.path),
          isNot(0),
        );
        expect(await target.exists(), isFalse);
        expect(
          await FileSystemEntity.type(link.path, followLinks: false),
          FileSystemEntityType.link,
        );
      },
    );

    test(
      'a missing destination folder fails without changing the source',
      () async {
        final before = await _hash(source);
        final missing = p.join(destination.path, 'missing', 'result.mp4');
        expect(await copyWindowsFileExclusive(source.path, missing), isNot(0));
        expect(await File(missing).exists(), isFalse);
        expect(await _hash(source), before);
      },
    );
    CompletedOutput output([String name = 'result.mp4']) => CompletedOutput(
      path: source.path,
      suggestedName: name,
      mimeType: 'video/mp4',
    );

    OutputFolder folder() =>
        OutputFolder(reference: destination.path, displayName: 'Test output');

    test(
      'export suffixes collisions without changing existing files',
      () async {
        final existing = await File(p.join(destination.path, 'result.mp4'))
            .writeAsString('keep existing');
        final before = await _hash(existing);
        final saved = _receipt(await saveWindowsOutput(output(), folder()));
        expect(saved.displayName, 'result (1).mp4');
        expect(saved.sizeBytes, await source.length());
        expect(await _hash(File(saved.reference)), await _hash(source));
        expect(await _hash(existing), before);
      },
    );

    test('existing directories and hard links also receive a suffix', () async {
      await Directory(p.join(destination.path, 'result.mp4')).create();
      final link = File(p.join(destination.path, 'result (1).mp4'));
      _createHardLink(link.path, source.path);
      final before = await _hash(source);
      final saved = _receipt(await saveWindowsOutput(output(), folder()));
      expect(saved.displayName, 'result (2).mp4');
      expect(await _hash(source), before);
      expect(await _hash(link), before);
    });

    test('same-source destination produces a new name', () async {
      final before = await _hash(source);
      final saved = _receipt(
        await saveWindowsOutput(
          output(p.basename(source.path)),
          OutputFolder(reference: fixture.path, displayName: 'Fixture'),
        ),
      );
      expect(saved.reference, isNot(source.path));
      expect(await _hash(source), before);
      expect(await _hash(File(saved.reference)), before);
    });

    test(
      'simultaneous exports with equal names save two distinct outputs',
      () async {
        final other = await File(p.join(fixture.path, 'other.mp4'))
            .writeAsString('different source');
        final results = await Future.wait([
          saveWindowsOutput(output(), folder()),
          saveWindowsOutput(
            CompletedOutput(
              path: other.path,
              suggestedName: 'result.mp4',
              mimeType: 'video/mp4',
            ),
            folder(),
          ),
        ]);
        final first = _receipt(results[0]);
        final second = _receipt(results[1]);
        expect(first.reference, isNot(second.reference));
        expect(await _hash(File(first.reference)), await _hash(source));
        expect(await _hash(File(second.reference)), await _hash(other));
      },
    );

    test(
      'native creation permits only one writer in a destination race',
      () async {
        await _writeFixture(source, 128);
        final target = p.join(destination.path, 'race.mp4');
        final codes = await Future.wait(
          List.generate(
            8,
            (_) => copyWindowsFileExclusive(source.path, target),
          ),
        );
        expect(codes.where((code) => code == 0), hasLength(1));
        expect(
          codes.where((code) => code == 80 || code == 183),
          hasLength(7),
          reason: 'Native results: $codes',
        );
        expect(await _hash(File(target)), await _hash(source));
      },
    );

    test(
      'missing destination is a shared failure and keeps the output',
      () async {
        final before = await _hash(source);
        final result = await saveWindowsOutput(
          output(),
          OutputFolder(
            reference: p.join(fixture.path, 'missing'),
            displayName: 'Missing',
          ),
        );
        expect(result, isA<FileFailure<SavedMedia>>());
        final error = (result as FileFailure<SavedMedia>).error;
        expect(error.scope, FileErrorScope.destination);
        expect(error.code, FileErrorCode.unavailable);
        expect(await _hash(source), before);
        expect(await destination.list().toList(), isEmpty);
      },
    );

    test('missing and empty completed outputs are item failures', () async {
      final missing = await saveWindowsOutput(
        CompletedOutput(
          path: p.join(fixture.path, 'missing.mp4'),
          suggestedName: 'result.mp4',
          mimeType: 'video/mp4',
        ),
        folder(),
      );
      expect(
        (missing as FileFailure<SavedMedia>).error.scope,
        FileErrorScope.item,
      );
      await source.writeAsString('');
      final empty = await saveWindowsOutput(output(), folder());
      expect(
        (empty as FileFailure<SavedMedia>).error.code,
        FileErrorCode.empty,
      );
      expect(await source.exists(), isTrue);
      expect(await destination.list().toList(), isEmpty);
    });

    test(
      'unsafe names cannot escape the folder or open device names',
      () async {
        for (final name in [
          '',
          '.',
          '..',
          '../escape.mp4',
          r'..\escape.mp4',
          r'a\b.mp4',
          'a/b.mp4',
          'x:stream',
          'CON',
          'NUL.mp4',
          'CON .jpg',
          'CONIN\$',
          'COM1.jpg',
          'LPT².jpg',
          'trailing.',
          'trailing.mp4 ',
          'bad\u0000.mp4',
        ]) {
          final result = await saveWindowsOutput(output(name), folder());
          expect(result, isA<FileFailure<SavedMedia>>(), reason: name);
          expect(
            (result as FileFailure<SavedMedia>).error.code,
            FileErrorCode.unsupported,
          );
        }
        expect(await destination.list().toList(), isEmpty);
        expect(
          await File(p.join(fixture.path, 'escape.mp4')).exists(),
          isFalse,
        );
      },
    );

    test(
      'partial read failure keeps prior exports and permits a later retry',
      () async {
        final previous = _receipt(
          await saveWindowsOutput(output('previous.mp4'), folder()),
        );
        final previousHash = await _hash(File(previous.reference));
        await _writeFixture(source, 4);
        final sourceHash = await _hash(source);
        final lock = await source.open();
        late FileResult<SavedMedia> failed;
        try {
          await lock.lock(FileLock.exclusive, 256 * 1024, 512 * 1024);
          failed = await saveWindowsOutput(output(), folder());
        } finally {
          await lock.close();
        }
        expect(failed, isA<FileFailure<SavedMedia>>());
        final error = (failed as FileFailure<SavedMedia>).error;
        expect(error.scope, FileErrorScope.item);
        expect(error.code, FileErrorCode.busy);
        expect(error.message, contains('partial file'));
        final partial = File(p.join(destination.path, 'result.mp4'));
        expect(await partial.length(), 256 * 1024);
        expect(await _hash(source), sourceHash);
        expect(await _hash(File(previous.reference)), previousHash);
        final retry = _receipt(await saveWindowsOutput(output(), folder()));
        expect(retry.displayName, 'result (1).mp4');
        expect(await _hash(File(retry.reference)), sourceHash);
        expect(await partial.length(), 256 * 1024);
      },
    );

    test(
      'export suffixes a dangling link without creating its target',
      () async {
        final target = await File(p.join(fixture.path, 'target.mp4'))
            .writeAsString('temporary');
        final link = Link(p.join(destination.path, 'result.mp4'));
        if (!await _createSymbolicLink(link, target.path)) return;
        await target.delete();
        final saved = _receipt(await saveWindowsOutput(output(), folder()));
        expect(saved.displayName, 'result (1).mp4');
        expect(await target.exists(), isFalse);
        expect(
          await FileSystemEntity.type(link.path, followLinks: false),
          FileSystemEntityType.link,
        );
      },
    );

    test('exports through a Windows path longer than 260 characters', () async {
      final longFolder = Directory(
        p.joinAll([
          destination.path,
          ...List.generate(
            8,
            (index) => 'folder-$index-abcdefghijklmnopqrstuvwxyz',
          ),
        ]),
      );
      await longFolder.create(recursive: true);
      final saved = _receipt(
        await saveWindowsOutput(
          output(),
          OutputFolder(reference: longFolder.path, displayName: 'Long folder'),
        ),
      );
      expect(saved.reference.length, greaterThan(260));
      expect(await _hash(File(saved.reference)), await _hash(source));
    });

    test('large copying leaves the caller event loop responsive', () async {
      await _writeFixture(source, 128);
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      final FileResult<SavedMedia> result;
      try {
        result = await saveWindowsOutput(output(), folder());
      } finally {
        timer.cancel();
      }
      final saved = _receipt(result);
      expect(ticks, greaterThan(0));
      expect(saved.sizeBytes, 32 * 1024 * 1024);
      expect(await _hash(File(saved.reference)), await _hash(source));
    });
  }, skip: !Platform.isWindows);
}

SavedMedia _receipt(FileResult<SavedMedia> result) {
  expect(result, isA<FileSuccess<SavedMedia>>());
  return (result as FileSuccess<SavedMedia>).value;
}

Future<void> _writeFixture(File file, int chunks) async {
  final writer = await file.open(mode: FileMode.write);
  final bytes = Uint8List(256 * 1024)..fillRange(0, 256 * 1024, 42);
  try {
    for (var index = 0; index < chunks; index++) {
      await writer.writeFrom(bytes);
    }
  } finally {
    await writer.close();
  }
}

Future<int> copyWindowsFileExclusive(String source, String destination) =>
    windows.copyWindowsFileExclusive(
      source,
      destination,
      libraryPath: _libraryPath,
    );

Future<FileResult<SavedMedia>> saveWindowsOutput(
  CompletedOutput output,
  OutputFolder folder,
) => windows.saveWindowsOutput(output, folder, libraryPath: _libraryPath);

String get _libraryPath =>
    p.absolute('build/windows/x64/runner/Debug/media_files_native.dll');

Future<Digest> _hash(File file) => sha256.bind(file.openRead()).first;

Future<bool> _createSymbolicLink(Link link, String target) async {
  try {
    await link.create(target);
    return true;
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode == 1314) {
      markTestSkipped(
        'Windows did not grant symbolic-link creation permission.',
      );
      return false;
    }
    rethrow;
  }
}

void _createHardLink(String link, String target) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final createLink = kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
        int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
      >('CreateHardLinkW');
  final getLastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final linkPointer = link.toNativeUtf16();
  try {
    final targetPointer = target.toNativeUtf16();
    try {
      final created = createLink(linkPointer, targetPointer, nullptr);
      final error = created == 0 ? getLastError() : 0;
      if (created == 0) {
        throw FileSystemException(
          'CreateHardLinkW failed',
          link,
          OSError('', error),
        );
      }
    } finally {
      malloc.free(targetPointer);
    }
  } finally {
    malloc.free(linkPointer);
  }
}
