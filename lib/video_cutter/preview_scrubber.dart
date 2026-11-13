import 'dart:async';

final class PreviewScrubber {
  PreviewScrubber({required this.pause, required this.seek});

  final Future<void> Function() pause;
  final Future<void> Function(Duration) seek;
  Timer? _timer;
  Future<void>? _pause;
  Duration? _target;
  Duration? _lastTarget;
  bool _busy = false;
  bool _finishing = false;
  bool _disposed = false;

  void update(Duration target) {
    if (_disposed) return;
    _lastTarget = target;
    _target = target;
    _finishing = false;
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
    if (_disposed || _lastTarget == null) return;
    _timer?.cancel();
    _timer = null;
    _finishing = true;
    if (!_busy && _target == null) {
      cancel();
    } else {
      _flush();
    }
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pause = null;
    _target = null;
    _lastTarget = null;
    _finishing = false;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }

  Future<void> _flush() async {
    if (_busy || _target == null || _disposed) return;
    _busy = true;
    try {
      await (_pause ??= pause());
      if (_disposed || _target == null) return;
      final target = _target!;
      _target = null;
      await seek(target);
    } finally {
      _busy = false;
      if (_finishing && !_disposed) {
        if (_target == null) {
          cancel();
        } else {
          _flush();
        }
      }
    }
  }
}
