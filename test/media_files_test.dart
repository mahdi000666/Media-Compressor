import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/media_files/media_files.dart';

void main() {
  const source = MediaSource(
    reference: 'content://test/document/movie%2F1',
    displayName: 'Movie.mp4',
    kind: MediaKind.video,
  );

  test('unknown source size is not an empty file', () {
    const empty = MediaSource(
      reference: 'content://test/document/empty',
      displayName: 'Empty.mp4',
      kind: MediaKind.video,
      sizeBytes: 0,
    );
    expect(source.sizeBytes, isNull);
    expect(empty.sizeBytes, 0);
  });

  test('preparation records actual size without changing source metadata', () {
    const prepared = PreparedInput(
      source: source,
      path: '/test-owned/staged.mp4',
      sizeBytes: 1 << 33,
      ownership: InputOwnership.temporary,
    );
    expect(prepared.source, same(source));
    expect(prepared.sizeBytes, 1 << 33);
    expect(prepared.ownership, InputOwnership.temporary);
    expect(source.sizeBytes, isNull);
    expect(source.reference, 'content://test/document/movie%2F1');
  });

  test('original paths are distinguishable from owned temporary inputs', () {
    const prepared = PreparedInput(
      source: source,
      path: '/test-source/movie.mp4',
      sizeBytes: 42,
      ownership: InputOwnership.original,
    );
    expect(prepared.ownership, InputOwnership.original);
  });

  test('saved receipts preserve actual names and opaque locations', () {
    const folder = OutputFolder(
      reference: 'content://test/tree/primary%3AOutput',
      displayName: 'Output',
    );
    const output = CompletedOutput(
      path: '/test-owned/result.mp4',
      suggestedName: 'Movie.mp4',
      mimeType: 'video/mp4',
    );
    const saved = SavedMedia(
      reference: 'content://test/document/primary%3AOutput%2FMovie%20(1).mp4',
      displayName: 'Movie (1).mp4',
      sizeBytes: 20,
    );
    expect(folder.reference, 'content://test/tree/primary%3AOutput');
    expect(saved.displayName, isNot(output.suggestedName));
    expect(saved.reference, contains('%2F'));
    expect(saved.sizeBytes, 20);
    expect(output.path, isNot(source.reference));
  });

  test('picker results protect source and error collections from mutation', () {
    const error = MediaFileError(
      scope: FileErrorScope.item,
      code: FileErrorCode.unreadable,
      message: 'Cannot read Broken.mp4.',
      sourceReference: 'content://test/document/broken',
    );
    final sources = [source];
    final errors = [error];
    final picked = PickedSources(sources: sources, errors: errors);
    sources.clear();
    errors.clear();
    expect(picked.sources, [source]);
    expect(picked.errors, [error]);
    expect(() => picked.sources.clear(), throwsUnsupportedError);
    expect(() => picked.errors.clear(), throwsUnsupportedError);
  });

  test(
    'cancellation, item errors, and shared destination errors are distinct',
    () {
      const cancelled = FileCancelled<OutputFolder>();
      const itemError = MediaFileError(
        scope: FileErrorScope.item,
        code: FileErrorCode.empty,
        message: 'Empty.mp4 contains no data.',
        sourceReference: 'content://test/document/empty',
      );
      const failure = FileFailure<SavedMedia>(
        MediaFileError(
          scope: FileErrorScope.destination,
          code: FileErrorCode.noSpace,
          message: 'The output folder has no free space.',
        ),
      );
      expect(cancelled, isNot(isA<FileFailure<OutputFolder>>()));
      expect(itemError.scope, FileErrorScope.item);
      expect(itemError.sourceReference, isNotNull);
      expect(failure.error.scope, FileErrorScope.destination);
      expect(failure.error.code, FileErrorCode.noSpace);
    },
  );
}
