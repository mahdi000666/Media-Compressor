enum MediaKind { image, video }

enum InputOwnership { original, temporary }

final class MediaSource {
  const MediaSource({
    required this.reference,
    required this.displayName,
    required this.kind,
    this.identity,
    this.sizeBytes,
  });

  final String reference;
  final String? identity;
  final String displayName;
  final MediaKind kind;
  final int? sizeBytes;
}

final class PreparedInput {
  const PreparedInput({
    required this.source,
    required this.path,
    required this.sizeBytes,
    required this.ownership,
  });

  final MediaSource source;
  final String path;
  final int sizeBytes;
  final InputOwnership ownership;
}

final class OutputFolder {
  const OutputFolder({required this.reference, required this.displayName});

  final String reference;
  final String displayName;
}

final class CompletedOutput {
  const CompletedOutput({
    required this.path,
    required this.suggestedName,
    required this.mimeType,
  });

  final String path;
  final String suggestedName;
  final String mimeType;
}

final class SavedMedia {
  const SavedMedia({
    required this.reference,
    required this.displayName,
    required this.sizeBytes,
  });

  final String reference;
  final String displayName;
  final int sizeBytes;
}

enum FileErrorScope { item, destination, operation }

enum FileErrorCode {
  unreadable,
  empty,
  unsupported,
  permissionDenied,
  noSpace,
  unavailable,
  busy,
  io,
}

final class MediaFileError {
  const MediaFileError({
    required this.scope,
    required this.code,
    required this.message,
    this.sourceReference,
  });

  final FileErrorScope scope;
  final FileErrorCode code;
  final String message;
  final String? sourceReference;
}

sealed class FileResult<T> {
  const FileResult();
}

final class FileSuccess<T> extends FileResult<T> {
  const FileSuccess(this.value);

  final T value;
}

final class FileCancelled<T> extends FileResult<T> {
  const FileCancelled();
}

final class FileFailure<T> extends FileResult<T> {
  const FileFailure(this.error);

  final MediaFileError error;
}

final class PickedSources {
  PickedSources({
    required Iterable<MediaSource> sources,
    Iterable<MediaFileError> errors = const [],
  }) : sources = List.unmodifiable(sources),
       errors = List.unmodifiable(errors);

  final List<MediaSource> sources;
  final List<MediaFileError> errors;
}

abstract interface class MediaFiles {
  Future<FileResult<PickedSources>> pickSources();

  Future<FileResult<PreparedInput>> prepareInput(MediaSource source);

  Future<FileResult<OutputFolder>> chooseOutputFolder();

  Future<FileResult<SavedMedia>> saveOutput(
    CompletedOutput output,
    OutputFolder folder,
  );

  Future<FileResult<void>> releaseInput(PreparedInput input);

  Future<FileResult<void>> discardOutput(CompletedOutput output);
}
