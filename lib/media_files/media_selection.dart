import 'media_files.dart';

final class MediaSelection {
  const MediaSelection.empty() : items = const [], errors = const [];

  MediaSelection._(Iterable<MediaSource> items, Iterable<MediaFileError> errors)
    : items = List.unmodifiable(items),
      errors = List.unmodifiable(errors);

  final List<MediaSource> items;
  final List<MediaFileError> errors;

  MediaSelection applyPick(FileResult<PickedSources> result) =>
      switch (result) {
        FileCancelled<PickedSources>() => this,
        FileFailure<PickedSources>(:final error) => MediaSelection._(items, [
          error,
        ]),
        FileSuccess<PickedSources>(:final value) => _append(value),
      };

  MediaSelection _append(PickedSources picked) {
    final identities = items
        .map((item) => item.identity)
        .whereType<String>()
        .toSet();
    final next = [...items];
    for (final source in picked.sources) {
      final identity = source.identity;
      if (identity == null || identities.add(identity)) {
        next.add(source);
      }
    }
    return MediaSelection._(next, picked.errors);
  }

  MediaSelection removeAt(int index) =>
      MediaSelection._([...items]..removeAt(index), errors);
}
