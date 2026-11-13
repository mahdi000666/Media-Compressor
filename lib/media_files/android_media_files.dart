import 'package:flutter/services.dart';

import 'media_files.dart';

class AndroidMediaFiles {
  const AndroidMediaFiles({
    this.channel = const MethodChannel('dev.local.media_compressor/files'),
  });
  final MethodChannel channel;

  Future<FileResult<T>> _invoke<T>(
    String method,
    Map<String, Object?>? arguments,
    T Function(Map<dynamic, dynamic>) decode, {
    FileErrorScope scope = FileErrorScope.operation,
    String? sourceReference,
  }) async {
    try {
      final value = await channel.invokeMapMethod<dynamic, dynamic>(
        method,
        arguments,
      );
      return value == null ? FileCancelled<T>() : FileSuccess(decode(value));
    } on PlatformException catch (error) {
      final details = error.details;
      final nativeScope = details is Map ? details['scope'] : null;
      return FileFailure(
        MediaFileError(
          scope: FileErrorScope.values.firstWhere(
            (value) => value.name == nativeScope,
            orElse: () => scope,
          ),
          code: FileErrorCode.values.firstWhere(
            (value) => value.name == error.code,
            orElse: () => FileErrorCode.io,
          ),
          message: error.message ?? 'Android file operation failed.',
          sourceReference: sourceReference,
        ),
      );
    } on MissingPluginException {
      return FileFailure(
        MediaFileError(
          scope: scope,
          code: FileErrorCode.unavailable,
          message: 'The Android file bridge is unavailable.',
          sourceReference: sourceReference,
        ),
      );
    }
  }

  Future<FileResult<PickedSources>> pickSources() => _invoke(
    'pick',
    null,
    (value) => PickedSources(
      sources: (value['sources'] as List).map(
        (entry) => MediaSource(
          reference: entry['reference'] as String,
          identity: entry['reference'] as String,
          displayName: entry['displayName'] as String,
          kind: MediaKind.values.byName(entry['kind'] as String),
          sizeBytes: entry['sizeBytes'] as int?,
        ),
      ),
      errors: (value['errors'] as List).map(
        (entry) => MediaFileError(
          scope: FileErrorScope.item,
          code: FileErrorCode.values.byName(entry['code'] as String),
          message: entry['message'] as String,
          sourceReference: entry['reference'] as String?,
        ),
      ),
    ),
  );

  Future<FileResult<OutputFolder>> chooseOutputFolder() => _invoke(
    'folder',
    null,
    (value) => OutputFolder(
      reference: value['reference'] as String,
      displayName: value['displayName'] as String,
    ),
    scope: FileErrorScope.destination,
  );

  Future<FileResult<PreparedInput>> prepareInput(MediaSource source) => _invoke(
    'prepare',
    {'reference': source.reference},
    (value) => PreparedInput(
      source: source,
      path: value['path'] as String,
      sizeBytes: value['sizeBytes'] as int,
      ownership: InputOwnership.temporary,
    ),
    scope: FileErrorScope.item,
    sourceReference: source.reference,
  );

  Future<FileResult<void>> releaseInput(PreparedInput input) async {
    if (input.ownership != InputOwnership.temporary) {
      return const FileFailure(
        MediaFileError(
          scope: FileErrorScope.operation,
          code: FileErrorCode.permissionDenied,
          message: 'Original files cannot be released as temporary inputs.',
        ),
      );
    }
    return _invoke<void>('release', {'path': input.path}, (_) {});
  }

  Future<void> cancelPrepare() => channel.invokeMethod<void>('cancelPrepare');

  Future<FileResult<SavedMedia>> saveOutput(
    CompletedOutput output,
    OutputFolder folder,
  ) => _invoke(
    'save',
    {
      'folder': folder.reference,
      'path': output.path,
      'name': output.suggestedName,
      'mimeType': output.mimeType,
    },
    (value) => SavedMedia(
      reference: value['reference'] as String,
      displayName: value['displayName'] as String,
      sizeBytes: value['sizeBytes'] as int,
    ),
    scope: FileErrorScope.destination,
  );
}
