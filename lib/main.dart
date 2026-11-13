import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'compression/ffmpeg_compressor.dart';
import 'media_files/media_files.dart';
import 'media_files/android_media_files.dart';
import 'media_files/windows_export.dart';
import 'video_cutter/cutter_page.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Compressor',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
    home: const CompressionPage(),
  );
}

class CompressionPage extends StatefulWidget {
  const CompressionPage({super.key, this.pickFiles, this.androidFiles});
  final Future<List<XFile>> Function()? pickFiles;
  final AndroidMediaFiles? androidFiles;
  @override
  State<CompressionPage> createState() => _CompressionPageState();
}

class _Job {
  _Job(this.source) : sizeBytes = source.sizeBytes;
  final MediaSource source;
  int? sizeBytes;
  String status = 'Ready';
  CompletedOutput? output;
  SavedMedia? saved;
}

class _CompressionPageState extends State<CompressionPage> {
  final List<_Job> _jobs = [];
  late final AppLifecycleListener _lifecycle;
  FfmpegCompressor? _encoder;
  OutputFolder? _folder;
  CompressionQuality _quality = CompressionQuality.balanced;
  int _maxEdge = 1920;
  bool _running = false;
  bool _picking = false;
  bool _cancelRequested = false;
  String _notice = 'Add files, choose an output folder, then start.';
  bool get _locked => _running || _picking;
  AndroidMediaFiles? get _androidFiles =>
      widget.androidFiles ??
      (Platform.isAndroid ? const AndroidMediaFiles() : null);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _requestExit);
  }

  Future<AppExitResponse> _requestExit() async {
    if (_locked) {
      _notice = 'Cancel the batch and wait for the current save, or close the picker, before exiting.';
      _refresh();
      return AppExitResponse.cancel;
    }
    if (_jobs.any((job) => job.output != null)) {
      _picking = true;
      _refresh();
      try {
        if (!await _confirmDiscard()) return AppExitResponse.cancel;
        for (final job in _jobs.where((job) => job.output != null)) {
          await _encoder!.discard(job.output!);
          job.output = null;
        }
      } on FileSystemException catch (error) {
        _notice = 'Could not remove the temporary output: $error';
        return AppExitResponse.cancel;
      } finally {
        _picking = false;
        _refresh();
      }
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _encoder?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    _picking = true;
    _refresh();
    try {
      if (_androidFiles != null) {
        final result = await _androidFiles!.pickSources();
        if (result case FileSuccess<PickedSources>(:final value)) {
          final known = _jobs.map((job) => job.source.reference).toSet();
          for (final source in value.sources) {
            if (known.add(source.reference)) _jobs.add(_Job(source));
          }
          _notice = value.errors.isEmpty
              ? '${_jobs.length} files selected.'
              : value.errors.map((error) => error.message).join('\n');
        } else if (result case FileFailure<PickedSources>(:final error)) {
          _notice = error.message;
        }
        return;
      }
      final files =
          await (widget.pickFiles?.call() ??
              openFiles(
                acceptedTypeGroups: const [
                  XTypeGroup(
                    label: 'Images and videos',
                    extensions: [
                      'jpg',
                      'jpeg',
                      'png',
                      'webp',
                      'mp4',
                      'mov',
                      'mkv',
                    ],
                  ),
                ],
              ));
      final known = _jobs.map((job) => job.source.reference).toSet();
      final errors = <String>[];
      for (final file in files) {
        try {
          final reference = await File(file.path).resolveSymbolicLinks();
          if (!known.add(reference)) continue;
          final extension = p.extension(file.name).toLowerCase();
          final kind = switch (extension) {
            '.jpg' || '.jpeg' || '.png' || '.webp' => MediaKind.image,
            '.mp4' || '.mov' || '.mkv' => MediaKind.video,
            _ => null,
          };
          if (kind == null) {
            errors.add('${file.name}: unsupported file type.');
            continue;
          }
          final size = await File(reference).length();
          if (size == 0) {
            errors.add('${file.name}: empty file.');
            continue;
          }
          _jobs.add(
            _Job(
              MediaSource(
                reference: reference,
                identity: reference,
                displayName: file.name,
                kind: kind,
                sizeBytes: size,
              ),
            ),
          );
        } on FileSystemException {
          errors.add('${file.name}: cannot read this file.');
        }
      }
      if (files.isNotEmpty) {
        _notice = errors.isEmpty
            ? '${_jobs.length} files selected.'
            : errors.join('\n');
      }
    } catch (error) {
      _notice = 'Could not select files: $error';
    } finally {
      _picking = false;
      _refresh();
    }
  }

  Future<void> _chooseFolder() async {
    _picking = true;
    _refresh();
    try {
      if (_androidFiles != null) {
        final result = await _androidFiles!.chooseOutputFolder();
        if (result case FileSuccess<OutputFolder>(:final value)) {
          _folder = value;
        } else if (result case FileFailure<OutputFolder>(:final error)) {
          _notice = error.message;
        }
        return;
      }
      final path = await getDirectoryPath(confirmButtonText: 'Use this folder');
      if (path != null) {
        _folder = OutputFolder(reference: path, displayName: p.basename(path));
      }
    } catch (error) {
      _notice = 'Could not select the output folder: $error';
    } finally {
      _picking = false;
      _refresh();
    }
  }

  Future<bool> _confirmDiscard() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard unsaved output?'),
          content: const Text(
            'Some encoded files have not been saved to your output folder. Discard these temporary copies? Originals and successfully saved files will not be removed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep it'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _removeJobs(List<_Job> jobs) async {
    if (_locked) return;
    _picking = true;
    _refresh();
    try {
      if (jobs.any((job) => job.output != null) && !await _confirmDiscard()) {
        return;
      }
      for (final job in jobs) {
        if (job.output != null) {
          await _encoder!.discard(job.output!);
          job.output = null;
        }
        _jobs.remove(job);
      }
      _notice = _jobs.isEmpty
          ? 'List cleared. Original and saved files kept.'
          : '${_jobs.length} files selected.';
    } catch (error) {
      _notice = 'Could not discard the temporary output: $error';
    } finally {
      _picking = false;
      _refresh();
    }
  }

  Future<void> _openCutter(_Job job) async {
    if (_locked) return;
    if (_jobs.any((job) => job.output != null)) {
      _notice = 'Save or discard the waiting compression output before opening the cutter.';
      _refresh();
      return;
    }
    PreparedInput? prepared;
    try {
      var source = job.source;
      if (_androidFiles != null) {
        _picking = true;
        _notice = 'Preparing video preview…';
        _refresh();
        final result = await _androidFiles!.prepareInput(job.source);
        if (result case FileSuccess<PreparedInput>(:final value)) {
          prepared = value;
          job.sizeBytes = value.sizeBytes;
          source = MediaSource(
            reference: value.path,
            displayName: job.source.displayName,
            kind: job.source.kind,
            sizeBytes: value.sizeBytes,
          );
        } else {
          if (result case FileFailure<PreparedInput>(:final error)) {
            _notice = error.message;
          }
          return;
        }
        _picking = false;
        _refresh();
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => CutterPage(
            source: source,
            folder: _folder,
            quality: _quality,
            maxEdge: _maxEdge == 0 ? null : _maxEdge,
          ),
        ),
      );
    } catch (error) {
      _notice = 'Could not open the cutter: $error';
    } finally {
      _picking = true;
      if (prepared != null) {
        final result = await _androidFiles!.releaseInput(prepared);
        if (result case FileFailure<void>(:final error)) {
          _notice = error.message;
        }
      }
      _picking = false;
      _refresh();
    }
  }

  Future<void> _start() async {
    if (_locked || _folder == null) return;
    _running = true;
    _cancelRequested = false;
    _refresh();
    try {
      _encoder ??= FfmpegCompressor(
        temporaryDirectory: Directory(
          p.join((await getTemporaryDirectory()).path, 'media-compressor'),
        ),
      );
      var paused = false;
      for (final job in _jobs.where((job) => job.saved == null)) {
        if (_cancelRequested || !mounted) break;
        _notice = 'Processing ${job.source.displayName}';
        try {
          if (job.output == null) {
            PreparedInput? prepared;
            try {
              var source = job.source;
              if (_androidFiles != null) {
                job.status = 'Preparing input…';
                _refresh();
                final result = await _androidFiles!.prepareInput(source);
                if (result case FileSuccess<PreparedInput>(:final value)) {
                  prepared = value;
                  job.sizeBytes = value.sizeBytes;
                  source = MediaSource(
                    reference: value.path,
                    displayName: job.source.displayName,
                    kind: job.source.kind,
                    sizeBytes: value.sizeBytes,
                  );
                } else if (result case FileFailure<PreparedInput>(
                  :final error,
                )) {
                  throw CompressionFailure(
                    error.message,
                    shared: [
                      FileErrorCode.noSpace,
                      FileErrorCode.unavailable,
                    ].contains(error.code),
                  );
                } else {
                  job.status = 'Cancelled';
                  break;
                }
              }
              if (_cancelRequested) {
                job.status = 'Cancelled';
                break;
              }
              job.status = 'Encoding…';
              _refresh();
              job.output = await _encoder!.compress(
                source,
                quality: _quality,
                maxEdge: _maxEdge == 0 ? null : _maxEdge,
                onProgress: (elapsed) {
                  job.status =
                      'Encoding · ${elapsed.inSeconds} seconds processed';
                  _refresh();
                },
              );
            } finally {
              if (prepared != null) {
                final result = await _androidFiles!.releaseInput(prepared);
                if (result case FileFailure<void>(:final error)) {
                  throw CompressionFailure(
                    'The staged input could not be removed: ${error.message}',
                    shared: true,
                  );
                }
              }
            }
            if (job.output == null) {
              job.status = 'Cancelled';
              break;
            }
          }
          if (_cancelRequested) {
            job.status = 'Encoding finished. Choose Continue to save this file without encoding again.';
            break;
          }
          job.status = 'Saving…';
          _refresh();
          final output = job.output!;
          final saved = _androidFiles == null
              ? await saveWindowsOutput(output, _folder!)
              : await _androidFiles!.saveOutput(output, _folder!);
          if (saved case FileSuccess<SavedMedia>(:final value)) {
            job.saved = value;
            job.output = null;
            job.status =
                'Saved · ${_size(value.sizeBytes)} · ${_change(job.sizeBytes!, value.sizeBytes)}';
            try {
              await _encoder!.discard(output);
            } on FileSystemException {
              job.status += ' (temporary copy could not be removed)';
            }
          } else {
            final message = saved is FileFailure<SavedMedia>
                ? saved.error.message
                : 'Save cancelled.';
            job.status = '$message\nEncoded file kept at ${output.path}';
            _notice = 'Encoding finished, but saving failed. Check the output folder, then choose Continue to save without encoding again.';
            paused = true;
            break;
          }
        } catch (error) {
          job.status = 'Failed: $error';
          if (job.output != null ||
              error is CompressionFailure && error.shared ||
              error is FileSystemException &&
                  [28, 39, 112].contains(error.osError?.errorCode)) {
            _notice = 'Paused: $error';
            paused = true;
            break;
          }
        }
        _refresh();
      }
      if (!paused) {
        final saved = _jobs.where((job) => job.saved != null).length;
        _notice =
            '${_cancelRequested ? 'Stopped' : 'Finished'} · $saved of ${_jobs.length} files saved.';
        if (saved < _jobs.length) {
          _notice += _jobs.any((job) => job.output != null)
              ? ' Choose Continue to save the completed encode and process remaining files.'
              : ' Start compression again to retry the remaining files.';
        }
      }
    } catch (error) {
      _notice = 'Could not start: $error';
    } finally {
      _running = false;
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = Platform.isWindows || Platform.isAndroid;
    final pending = _jobs.any((job) => job.saved == null);
    return PopScope(
      canPop: !Platform.isAndroid,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop &&
            Platform.isAndroid &&
            await _requestExit() == AppExitResponse.exit) {
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Compressor')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    supported
                        ? 'Offline image & video compression'
                        : 'This platform is not supported.',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: supported && !_locked ? _pick : null,
                        icon: const Icon(Icons.add),
                        label: const Text('Add files'),
                      ),
                      OutlinedButton.icon(
                        onPressed: !_locked && _jobs.isNotEmpty
                            ? () => _removeJobs(List.of(_jobs))
                            : null,
                        icon: const Icon(Icons.clear_all),
                        label: const Text('Clear list'),
                      ),
                      OutlinedButton.icon(
                        onPressed: supported && !_locked ? _chooseFolder : null,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Output folder'),
                      ),
                      DropdownButton<CompressionQuality>(
                        value: _quality,
                        onChanged: _locked
                            ? null
                            : (value) => setState(() => _quality = value!),
                        items: const [
                          DropdownMenuItem(
                            value: CompressionQuality.smaller,
                            child: Text('Smaller file'),
                          ),
                          DropdownMenuItem(
                            value: CompressionQuality.balanced,
                            child: Text('Balanced quality'),
                          ),
                          DropdownMenuItem(
                            value: CompressionQuality.higher,
                            child: Text('Higher quality'),
                          ),
                        ],
                      ),
                      Tooltip(
                        message: 'Limits width and height while keeping proportions. Smaller files are not enlarged.\nFor example, 1920 × 1080 becomes 1280 × 720 with a 1280 px limit.\nKeep original size skips resizing, apart from even-pixel rounding for video.',
                        child: DropdownButton<int>(
                          value: _maxEdge,
                          onChanged: _locked
                              ? null
                              : (value) => setState(() => _maxEdge = value!),
                          items: const [
                            DropdownMenuItem(
                              value: 0,
                              child: Text('Keep original size'),
                            ),
                            DropdownMenuItem(
                              value: 1920,
                              child: Text('Longest side: 1920 px'),
                            ),
                            DropdownMenuItem(
                              value: 1280,
                              child: Text('Longest side: 1280 px'),
                            ),
                            DropdownMenuItem(
                              value: 720,
                              child: Text('Longest side: 720 px'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    _folder == null
                        ? 'No output folder selected'
                        : 'Save to: ${_androidFiles == null ? _folder!.reference : _folder!.displayName}',
                  ),
                  const Divider(height: 24),
                  Expanded(
                    child: _jobs.isEmpty
                        ? const Center(
                            child: Text(
                              'Add JPEG, PNG, WebP, MP4, MOV or MKV files.\nOriginal files are never overwritten.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            itemCount: _jobs.length,
                            itemBuilder: (context, index) {
                              final job = _jobs[index];
                              return Card(
                                child: ListTile(
                                  leading: Icon(
                                    job.saved != null
                                        ? Icons.check_circle_outline
                                        : job.source.kind == MediaKind.video
                                        ? Icons.movie_outlined
                                        : Icons.image_outlined,
                                  ),
                                  title: Text(job.source.displayName),
                                  subtitle: SelectableText(
                                    '${_size(job.sizeBytes)} · ${job.status}${job.saved == null ? '' : '\n${job.saved!.reference}'}',
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (job.source.kind == MediaKind.video)
                                        IconButton(
                                          tooltip: 'Cut video',
                                          onPressed: _locked
                                              ? null
                                              : () => _openCutter(job),
                                          icon: const Icon(Icons.content_cut),
                                        ),
                                      IconButton(
                                        tooltip: 'Remove from list',
                                        onPressed: _locked
                                            ? null
                                            : () => _removeJobs([job]),
                                        icon: const Icon(Icons.close),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 12),
                  if (_running) const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 100),
                    child: SingleChildScrollView(
                      child: SelectableText(_notice),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            supported && !_locked && pending && _folder != null
                            ? _start
                            : null,
                        icon: const Icon(Icons.compress),
                        label: Text(
                          _jobs.any((job) => job.output != null)
                              ? 'Continue'
                              : 'Start compression',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _running && !_cancelRequested
                            ? () {
                                _cancelRequested = true;
                                _encoder?.cancel();
                                if (_androidFiles != null) {
                                  unawaited(
                                    _androidFiles!.cancelPrepare().catchError(
                                      (Object _) {},
                                    ),
                                  );
                                }
                                _notice = 'Stopping. A save already in progress will finish.';
                                _refresh();
                              }
                            : null,
                        child: const Text('Cancel'),
                      ),
                      Text(
                        '${_jobs.where((job) => job.saved != null).length} / ${_jobs.length} saved',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _size(int? bytes) => bytes == null
    ? 'Unknown size'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
String _change(int original, int saved) => saved <= original
    ? '${((1 - saved / original) * 100).toStringAsFixed(1)}% smaller'
    : '${((saved / original - 1) * 100).toStringAsFixed(1)}% larger';
