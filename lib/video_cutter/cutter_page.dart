import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../compression/ffmpeg_compressor.dart';
import '../media_files/media_files.dart';
import '../media_files/windows_export.dart';
import '../media_files/android_media_files.dart';
import 'cut_plan.dart';
import 'preview_scrubber.dart';

class CutterPage extends StatefulWidget {
  const CutterPage({
    super.key,
    required this.source,
    this.folder,
    required this.quality,
    this.maxEdge,
  });
  final MediaSource source;
  final OutputFolder? folder;
  final CompressionQuality quality;
  final int? maxEdge;
  @override
  State<CutterPage> createState() => _CutterPageState();
}

class _CutterPageState extends State<CutterPage> {
  Player? _player;
  VideoController? _video;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late final AppLifecycleListener _lifecycle;
  FfmpegCompressor? _encoder;
  OutputFolder? _folder;
  final AndroidMediaFiles? _androidFiles = Platform.isAndroid
      ? const AndroidMediaFiles()
      : null;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  Duration _from = Duration.zero;
  Duration _to = Duration.zero;
  PreviewScrubber? _scrubber;
  Duration? _seekTarget;
  bool _seeking = false;
  CutMode _mode = CutMode.removeSections;
  List<VideoSection>? _plan;
  CompletedOutput? _pending;
  final List<SavedMedia> _saved = [];
  bool _running = false;
  bool _picking = false;
  bool _cancelRequested = false;
  String _notice = 'Loading preview…';
  bool get _locked => _running || _picking;
  bool get _editable => !_locked && _plan == null && _duration > Duration.zero;

  @override
  void initState() {
    super.initState();
    _folder = widget.folder;
    if (Platform.isAndroid) {
      _scrubber = PreviewScrubber(
        pause: () => _control((player) => player.pause()),
        seek: (target) => _control((player) => player.seek(target)),
      );
    }
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (_locked) {
          _notice = 'Cancel the export and wait for the current save, or close the picker, before exiting.';
          _refresh();
          return AppExitResponse.cancel;
        }
        return await _discardWork()
            ? AppExitResponse.exit
            : AppExitResponse.cancel;
      },
    );
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      MediaKit.ensureInitialized(
        libmpv: Platform.isWindows
            ? p.join(p.dirname(Platform.resolvedExecutable), 'libmpv-2.dll')
            : null,
      );
      final player = Player(
        configuration: const PlayerConfiguration(
          title: 'Compressor',
          protocolWhitelist: ['file', 'pipe'],
          libass: false,
        ),
      );
      _player = player;
      _video = VideoController(player);
      _subscriptions.add(
        player.stream.duration.listen((duration) {
          if (duration <= Duration.zero) return;
          if (_duration == Duration.zero) {
            _to = duration;
            _notice = 'Drag the green handles, then remove the range or export it as a clip.';
          }
          _duration = duration;
          _refresh();
        }),
      );
      _subscriptions.add(
        player.stream.position.listen((position) {
          _position = position;
          _refresh();
        }),
      );
      _subscriptions.add(
        player.stream.error.listen((error) {
          _notice = 'Preview: $error';
          _refresh();
        }),
      );
      _refresh();
      if (Platform.isAndroid) {
        // Keep accurate targets, but allow skipping pre-target decode work.
        await (player.platform as NativePlayer).setProperty(
          'hr-seek-framedrop',
          'yes',
        );
        if (!mounted) return;
      }
      await player.open(
        Media(File(widget.source.reference).uri.toString()),
        play: false,
      );
    } catch (error) {
      _notice = 'Cannot open preview: $error';
      _refresh();
    }
  }

  @override
  void dispose() {
    _scrubber?.dispose();
    _encoder?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player?.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _control(Future<void> Function(Player) action) async {
    final player = _player;
    if (player == null) return;
    try {
      await action(player);
    } catch (error) {
      _notice = 'Preview: $error';
      _refresh();
    }
  }

  void _changeRange(RangeValues values) {
    final start = Duration(milliseconds: values.start.round());
    final end = Duration(milliseconds: values.end.round());
    if (start == _from && end == _to) return;
    final target = start != _from ? start : end;
    setState(() {
      _from = start;
      _to = end;
    });
    if (_scrubber != null) {
      _scrubber!.update(target);
    } else {
      _seekTo(target);
    }
  }

  Future<void> _seekTo(Duration target) async {
    _seekTarget = target;
    if (_seeking) return;
    _seeking = true;
    try {
      await _control((player) => player.pause());
      while (mounted && !_locked && _seekTarget != null) {
        final position = _seekTarget!;
        _seekTarget = null;
        await _control((player) => player.seek(position));
      }
    } finally {
      _seeking = false;
    }
  }

  Future<void> _chooseFolder() async {
    _scrubber?.cancel();
    _picking = true;
    _refresh();
    try {
      if (_androidFiles != null) {
        final result = await _androidFiles.chooseOutputFolder();
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
      _notice = 'Could not choose the output folder: $error';
    } finally {
      _picking = false;
      _refresh();
    }
  }

  Future<bool> _discardWork() async {
    if (_locked) return false;
    _scrubber?.cancel();
    _picking = true;
    _refresh();
    try {
      if (_pending != null) {
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved output?'),
            content: const Text(
              'The current encoded file has not been saved. Discard it and the remaining export work? Originals and already saved files stay untouched.',
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
        );
        if (discard != true) return false;
        await _encoder!.discard(_pending!);
        _pending = null;
      }
      _plan = null;
      return true;
    } catch (error) {
      _notice = 'Could not discard the temporary output: $error';
      return false;
    } finally {
      _picking = false;
      _refresh();
    }
  }

  Future<void> _leave() async {
    if (await _discardWork() && mounted) Navigator.of(context).pop();
  }

  Future<void> _export(CutMode mode) async {
    if (_locked || _folder == null) return;
    _running = true;
    _cancelRequested = false;
    _seekTarget = null;
    _scrubber?.cancel();
    _refresh();
    try {
      await _control((player) => player.pause());
      _plan ??= planCuts([(start: _from, end: _to)], _duration, mode).single;
      _mode = mode;
      _encoder ??= FfmpegCompressor(
        temporaryDirectory: Directory(
          p.join((await getTemporaryDirectory()).path, 'media-compressor'),
        ),
      );
      if (_pending == null && !_cancelRequested) {
        final name = p.basenameWithoutExtension(widget.source.displayName);
        _notice = 'Encoding…';
        _refresh();
        _pending = await _encoder!.compress(
          widget.source,
          sections: _plan,
          quality: widget.quality,
          maxEdge: widget.maxEdge,
          suggestedName: cutOutputName(name, mode),
          onProgress: (elapsed) {
            _notice = 'Encoding · ${elapsed.inSeconds} seconds processed';
            _refresh();
          },
        );
      }
      if (_cancelRequested || _pending == null) {
        _notice = 'Stopped. Continue export resumes this range.';
        return;
      }
      _notice = 'Saving…';
      _refresh();
      final result = _androidFiles == null
          ? await saveWindowsOutput(_pending!, _folder!)
          : await _androidFiles.saveOutput(_pending!, _folder!);
      if (result case FileSuccess<SavedMedia>(:final value)) {
        _saved.add(value);
        final output = _pending!;
        _pending = null;
        _plan = null;
        _notice = 'Saved ${value.displayName}.';
        try {
          await _encoder!.discard(output);
        } on FileSystemException {
          _notice += ' The temporary copy could not be removed.';
        }
      } else {
        final error = result is FileFailure<SavedMedia>
            ? result.error.message
            : 'Saving was cancelled.';
        _notice =
            '$error\nEncoded file kept at ${_pending!.path}. Check the folder, then Continue export.';
      }
    } catch (error) {
      _notice = 'Export stopped: $error';
    } finally {
      _running = false;
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxMilliseconds = _duration.inMilliseconds.toDouble();
    final from = _from.inMilliseconds.toDouble().clamp(0.0, maxMilliseconds);
    final to = _to.inMilliseconds.toDouble().clamp(from, maxMilliseconds);
    return PopScope(
      canPop: !_locked && _plan == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_locked) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Cut video'),
          leading: IconButton(
            tooltip: 'Back',
            onPressed: _locked ? null : _leave,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.source.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _video == null
                        ? const Center(child: Text('Opening preview…'))
                        : AbsorbPointer(
                            absorbing: _locked,
                            child: Video(controller: _video!, wakelock: false),
                          ),
                  ),
                  const SizedBox(height: 8),
                  Text('${sectionTime(_position)} / ${sectionTime(_duration)}'),
                  RangeSlider(
                    min: 0,
                    max: maxMilliseconds > 0 ? maxMilliseconds : 1,
                    values: RangeValues(from, to),
                    labels: RangeLabels(sectionTime(_from), sectionTime(_to)),
                    onChanged: !_editable ? null : _changeRange,
                    onChangeEnd: !_editable || _scrubber == null
                        ? null
                        : (_) => _scrubber!.finish(),
                  ),
                  Text(
                    'Selected range: ${sectionTime(_from)} → ${sectionTime(_to)}',
                  ),
                  if (_saved.isNotEmpty)
                    SizedBox(
                      height: 72,
                      child: ListView(
                        children: [
                          for (final saved in _saved)
                            ListTile(
                              leading: const Icon(Icons.check_circle_outline),
                              title: SelectableText(saved.displayName),
                              subtitle: SelectableText(saved.reference),
                            ),
                        ],
                      ),
                    ),
                  const Divider(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_plan == null) ...[
                        FilledButton(
                          onPressed: _editable && _folder != null && _to > _from
                              ? () => _export(CutMode.removeSections)
                              : null,
                          child: const Text('Remove selection'),
                        ),
                        FilledButton(
                          onPressed: _editable && _folder != null && _to > _from
                              ? () => _export(CutMode.exportClips)
                              : null,
                          child: const Text('Export clip'),
                        ),
                      ] else
                        FilledButton(
                          onPressed: !_locked && _folder != null
                              ? () => _export(_mode)
                              : null,
                          child: const Text('Continue export'),
                        ),
                      OutlinedButton.icon(
                        onPressed: _locked ? null : _chooseFolder,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Output folder'),
                      ),

                      if (_running)
                        OutlinedButton(
                          onPressed: _cancelRequested
                              ? null
                              : () {
                                  _cancelRequested = true;
                                  _encoder?.cancel();
                                  _notice = 'Stopping. A save already in progress will finish.';
                                  _refresh();
                                },
                          child: const Text('Cancel'),
                        ),
                      if (!_running && _plan != null)
                        TextButton(
                          onPressed: _picking ? null : _discardWork,
                          child: const Text('Discard remaining work'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'MP4 · ${widget.quality.name} quality · ${widget.maxEdge == null ? 'original size' : 'longest side ${widget.maxEdge} px'}',
                  ),
                  SelectableText(
                    _folder == null
                        ? 'Choose an output folder.'
                        : 'Save to: ${_androidFiles == null ? _folder!.reference : _folder!.displayName}',
                  ),
                  if (_running) const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 90),
                    child: SingleChildScrollView(
                      child: SelectableText(_notice),
                    ),
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
