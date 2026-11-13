import 'package:flutter_test/flutter_test.dart';
import 'package:media_compressor/media_files/media_files.dart';
import 'package:media_compressor/media_files/media_selection.dart';

void main() {
  const image = MediaSource(
    reference: 'opaque:image-1',
    identity: 'image-1',
    displayName: 'Shared name.jpg',
    kind: MediaKind.image,
    sizeBytes: 100,
  );
  const video = MediaSource(
    reference: 'opaque:video-1',
    identity: 'video-1',
    displayName: 'Video.mp4',
    kind: MediaKind.video,
  );
  const otherImage = MediaSource(
    reference: 'opaque:image-2',
    identity: 'image-2',
    displayName: 'Shared name.jpg',
    kind: MediaKind.image,
    sizeBytes: 200,
  );
  const itemError = MediaFileError(
    scope: FileErrorScope.item,
    code: FileErrorCode.unreadable,
    message: 'Cannot read Broken.mp4.',
    sourceReference: 'opaque:broken',
  );

  FileSuccess<PickedSources> picked(
    List<MediaSource> sources, {
    List<MediaFileError> errors = const [],
  }) => FileSuccess(PickedSources(sources: sources, errors: errors));

  test('starts empty and keeps the old snapshot unchanged', () {
    const before = MediaSelection.empty();
    final after = before.applyPick(picked([image]));
    expect(before.items, isEmpty);
    expect(before.errors, isEmpty);
    expect(after.items, [image]);
  });

  test('mixed picks append in picker-returned order across selections', () {
    final first = const MediaSelection.empty().applyPick(
      picked([video, image]),
    );
    final next = first.applyPick(picked([otherImage]));
    expect(first.items, [video, image]);
    expect(next.items, [video, image, otherImage]);
    expect(next.items.first.sizeBytes, isNull);
  });

  test('known duplicate identities are ignored within and across picks', () {
    const alias = MediaSource(
      reference: 'opaque:another-handle-for-image-1',
      identity: 'image-1',
      displayName: 'Renamed.jpg',
      kind: MediaKind.image,
    );
    final first = const MediaSelection.empty().applyPick(
      picked([image, alias, image, video]),
    );
    final next = first.applyPick(picked([alias, video, otherImage]));
    expect(first.items, [image, video]);
    expect(next.items, [image, video, otherImage]);
    expect(next.items.first, same(image));
  });

  test('distinct sources with the same display name remain separate', () {
    final state = const MediaSelection.empty().applyPick(
      picked([image, otherImage]),
    );
    expect(state.items, [image, otherImage]);
  });

  test('unknown identities are not guessed from references or names', () {
    const unknown = MediaSource(
      reference: 'opaque:unknown',
      displayName: 'Unknown.jpg',
      kind: MediaKind.image,
    );
    final first = const MediaSelection.empty().applyPick(picked([unknown]));
    final next = first.applyPick(picked([unknown]));
    expect(next.items, [unknown, unknown]);
  });

  test('opaque identities are not case-folded or path-normalized', () {
    const upperCaseIdentity = MediaSource(
      reference: 'opaque:upper-case-id',
      identity: 'IMAGE-1',
      displayName: 'Other.jpg',
      kind: MediaKind.image,
    );
    final state = const MediaSelection.empty().applyPick(
      picked([image, upperCaseIdentity]),
    );
    expect(state.items, [image, upperCaseIdentity]);
  });

  test('cancellation preserves both items and existing error state', () {
    final before = const MediaSelection.empty().applyPick(
      picked([image], errors: [itemError]),
    );
    final after = before.applyPick(const FileCancelled());
    expect(after, same(before));
    expect(after.items, [image]);
    expect(after.errors, [itemError]);
    expect(
      const MediaSelection.empty().applyPick(const FileCancelled()).items,
      isEmpty,
    );
  });

  test('one invalid item does not erase existing or newly valid sources', () {
    final before = const MediaSelection.empty().applyPick(picked([image]));
    final after = before.applyPick(picked([video], errors: [itemError]));
    expect(after.items, [image, video]);
    expect(after.errors, [itemError]);
  });

  test(
    'picker failure preserves selection and reports the operation error',
    () {
      const error = MediaFileError(
        scope: FileErrorScope.operation,
        code: FileErrorCode.unavailable,
        message: 'The file picker is unavailable.',
      );
      final before = const MediaSelection.empty().applyPick(picked([image]));
      final after = before.applyPick(const FileFailure(error));
      expect(after.items, [image]);
      expect(after.errors, [error]);
      expect(before.errors, isEmpty);
    },
  );

  test(
    'a successful empty pick preserves items and clears old picker errors',
    () {
      final before = const MediaSelection.empty().applyPick(
        picked([image], errors: [itemError]),
      );
      final after = before.applyPick(picked([]));
      expect(after.items, [image]);
      expect(after.errors, isEmpty);
    },
  );

  test(
    'removing one item preserves other items and allows adding it again',
    () {
      final before = const MediaSelection.empty().applyPick(
        picked([image, video, otherImage], errors: [itemError]),
      );
      final after = before.removeAt(1);
      expect(before.items, [image, video, otherImage]);
      expect(after.items, [image, otherImage]);
      expect(after.errors, [itemError]);
      expect(after.applyPick(picked([video])).items, [
        image,
        otherImage,
        video,
      ]);
      expect(after.removeAt(0).items, [otherImage]);
      expect(after.removeAt(1).items, [image]);
    },
  );

  test('removing one unknown-identity entry does not remove another', () {
    const unknown = MediaSource(
      reference: 'opaque:unknown',
      displayName: 'Unknown.jpg',
      kind: MediaKind.image,
    );
    final state = const MediaSelection.empty().applyPick(
      picked([unknown, unknown]),
    );
    expect(state.removeAt(0).items, [unknown]);
    expect(state.removeAt(0).removeAt(0).items, isEmpty);
  });

  test('selection snapshots cannot be mutated externally', () {
    final state = const MediaSelection.empty().applyPick(
      picked([image], errors: [itemError]),
    );
    expect(() => state.items.clear(), throwsUnsupportedError);
    expect(() => state.errors.clear(), throwsUnsupportedError);
  });

  test('large reference selections do not require local or prepared paths', () {
    final sources = List.generate(
      1000,
      (index) => MediaSource(
        reference: 'opaque:unprepared-$index',
        identity: 'identity-$index',
        displayName: 'Video $index.mp4',
        kind: MediaKind.video,
        sizeBytes: 1 << 40,
      ),
    );
    final state = const MediaSelection.empty().applyPick(picked(sources));
    expect(state.items, sources);
    expect(state.items.every((source) => source.sizeBytes == 1 << 40), isTrue);
  });
}
