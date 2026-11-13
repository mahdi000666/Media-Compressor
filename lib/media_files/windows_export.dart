import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'media_files.dart';

final class _NativeCopyDetails extends Struct {
  @Int32()
  external int sourceError;
  @Int32()
  external int destinationCreated;
}

typedef _CopyFileNative = Uint32 Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<_NativeCopyDetails>,
);
typedef _CopyFile = int Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<_NativeCopyDetails>,
);

final class _CopyStatus {
  const _CopyStatus(this.errorCode, this.scope, {this.created = false});

  final int errorCode;
  final FileErrorScope scope;
  final bool created;
}

Future<int> copyWindowsFileExclusive(
  String source,
  String destination, {
  String? libraryPath,
}) {
  final library = _libraryPath(libraryPath);
  return Isolate.run(
    () => _copyExclusive(source, destination, library).errorCode,
  );
}

String _libraryPath(String? override) =>
    override ??
    p.join(p.dirname(Platform.resolvedExecutable), 'media_files_native.dll');

_CopyStatus _copyExclusive(
  String source,
  String destination,
  String libraryPath,
) {
  final library = DynamicLibrary.open(libraryPath);
  final copyFile = library.lookupFunction<_CopyFileNative, _CopyFile>(
    'MediaCopyFileExclusive',
  );
  final sourcePointer = _nativePath(source).toNativeUtf16();
  try {
    final destinationPointer = _nativePath(destination).toNativeUtf16();
    try {
      final details = calloc<_NativeCopyDetails>();
      try {
        final error = copyFile(sourcePointer, destinationPointer, details);
        return _CopyStatus(
          error,
          details.ref.sourceError != 0
              ? FileErrorScope.item
              : FileErrorScope.destination,
          created: details.ref.destinationCreated != 0,
        );
      } finally {
        calloc.free(details);
      }
    } finally {
      malloc.free(destinationPointer);
    }
  } finally {
    malloc.free(sourcePointer);
  }
}

Future<FileResult<SavedMedia>> saveWindowsOutput(
  CompletedOutput output,
  OutputFolder folder, {
  String? libraryPath,
}) async {
  final library = _libraryPath(libraryPath);
  final name = output.suggestedName;
  if (!_validName(name)) {
    return _failure(
      FileErrorScope.item,
      FileErrorCode.unsupported,
      'The suggested filename cannot be used on Windows.',
    );
  }
  try {
    if (await File(output.path).length() == 0) {
      return _failure(
        FileErrorScope.item,
        FileErrorCode.empty,
        'The completed output is empty.',
      );
    }
  } on FileSystemException {
    return _failure(
      FileErrorScope.item,
      FileErrorCode.unreadable,
      'The completed output cannot be read.',
    );
  }

  String? attemptedPath;
  var created = false;
  try {
    if (!p.windows.isAbsolute(folder.reference) ||
        !await Directory(folder.reference).exists()) {
      return _failure(
        FileErrorScope.destination,
        FileErrorCode.unavailable,
        'The output folder is unavailable. Choose another folder.',
      );
    }
    for (var suffix = 0; ; suffix++) {
      final candidate = suffix == 0
          ? name
          : '${p.windows.basenameWithoutExtension(name)} ($suffix)${p.windows.extension(name)}';
      final target = p.windows.join(folder.reference, candidate);
      attemptedPath = target;
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      final status = await Isolate.run(
        () => _copyExclusive(output.path, target, library),
      );
      created = status.created;
      if (!created &&
          status.scope == FileErrorScope.destination &&
          (status.errorCode == 80 || status.errorCode == 183)) {
        continue;
      }
      if (status.errorCode != 0) {
        final partial = created ? ' A partial file may remain at $target.' : '';
        return _failure(
          status.scope,
          _errorCode(status.errorCode),
          'Copy failed (Windows error ${status.errorCode}).$partial',
        );
      }
      return FileSuccess(
        SavedMedia(
          reference: target,
          displayName: candidate,
          sizeBytes: await File(target).length(),
        ),
      );
    }
  } on FileSystemException {
    final partial = created ? ' A file may remain at $attemptedPath.' : '';
    return _failure(
      FileErrorScope.destination,
      FileErrorCode.io,
      'The export could not be completed or confirmed.$partial',
    );
  }
}

FileFailure<SavedMedia> _failure(
  FileErrorScope scope,
  FileErrorCode code,
  String message,
) => FileFailure(MediaFileError(scope: scope, code: code, message: message));

FileErrorCode _errorCode(int code) => switch (code) {
  2 || 3 => FileErrorCode.unavailable,
  5 || 19 => FileErrorCode.permissionDenied,
  32 || 33 => FileErrorCode.busy,
  39 || 112 => FileErrorCode.noSpace,
  123 || 206 => FileErrorCode.unsupported,
  _ => FileErrorCode.io,
};

bool _validName(String name) {
  if (name.isEmpty ||
      name.endsWith(' ') ||
      name.endsWith('.') ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name)) {
    return false;
  }
  final stem = name.split('.').first.trimRight().toUpperCase();
  return !const {
        'CON',
        'PRN',
        'AUX',
        'NUL',
        'CONIN\$',
        'CONOUT\$',
      }.contains(stem) &&
      !RegExp(r'^(COM|LPT)[1-9¹²³]$').hasMatch(stem);
}

String _nativePath(String path) {
  final absolute = p.windows.normalize(p.windows.absolute(path));
  if (absolute.startsWith(r'\\?\')) return absolute;
  return absolute.startsWith(r'\\')
      ? r'\\?\UNC\' + absolute.substring(2)
      : r'\\?\' + absolute;
}
