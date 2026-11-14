import 'dart:async';

/// Coalesces range-handle updates into preview seeks and finishes with one
/// precise seek, so a phone decoder is not restarted on every pointer event.
final class PreviewScrubber {
  PreviewScrubber({required this.pause, required this.seek, this.preview});

  final Future<void> Function() pause;

  /// Precise seek used once the handle is released.
  final Future<void> Function(Duration) seek;

  /// Fast, approximate seek used while the handle is held. Falls back to
  /// [seek] when null.
  final Future<void> Function(Duration)? preview;

  Timer? _timer;
  Future<void>? _pause;
  Duration? _target;
  Duration? _lastTarget;
  bool _busy = false;
  bool _exactPending = false;
  bool _exactDone = false;
  bool _disposed = false;

  void update(Duration target) {
    if (_disposed) return;
    _lastTarget = target;
    _target = target;
    _exactPending = false;
    _exactDone = false;
    if (_timer == null) {
      _pause = null;
      // A seek command can complete before its frame is displayed.
      _timer = Timer.periodic(
        const Duration(milliseconds: 80),
        (_) => _flush(),
      );
      _flush();
    }
  }

  void finish() {
    if (_disposed || _lastTarget == null || _exactDone) return;
    _timer?.cancel();
    _timer = null;
    _exactPending = true;
    _flush();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pause = null;
    _target = null;
    _lastTarget = null;
    _exactPending = false;
    _exactDone = false;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }

  Future<void> _flush() async {
    if (_busy || _disposed) return;
    if (_target == null && !_exactPending) return;
    _busy = true;
    try {
      await (_pause ??= pause());
      if (_disposed) return;
      if (_exactPending) {
        _exactPending = false;
        _exactDone = true;
        _target = null;
        await seek(_lastTarget!);
      } else {
        final target = _target!;
        _target = null;
        await (preview ?? seek)(target);
      }
    } finally {
      _busy = false;
      if (!_disposed && _timer == null && (_target != null || _exactPending)) {
        _flush();
      }
    }
  }
}
