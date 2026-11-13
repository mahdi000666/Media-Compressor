import 'dart:async';

import 'package:flutter/services.dart';

class AndroidEncodingFailure implements Exception {
  const AndroidEncodingFailure(this.message);
  final String message;
}

class AndroidEncodeResult {
  const AndroidEncodeResult(this.code, this.errors, this.cancelled);
  final int code;
  final String errors;
  final bool cancelled;
}

class AndroidFfmpeg {
  AndroidFfmpeg({
    this.channel = const MethodChannel('dev.local.media_compressor/ffmpeg'),
  });
  final MethodChannel channel;
  static int _nextId = 0;
  int? _activeId;

  Future<AndroidEncodeResult> encode(
    List<String> arguments, {
    void Function(Duration)? onProgress,
  }) async {
    final id = ++_nextId;
    _activeId = id;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'progress' && call.arguments['id'] == _activeId) {
        final microseconds = call.arguments['microseconds'] as int;
        if (microseconds >= 0) {
          onProgress?.call(Duration(microseconds: microseconds));
        }
      }
    });
    try {
      final result = await channel.invokeMapMethod<dynamic, dynamic>('encode', {
        'id': id,
        'arguments': arguments,
      });
      if (result == null) {
        throw const AndroidEncodingFailure(
          'Android FFmpeg returned no result.',
        );
      }
      return AndroidEncodeResult(
        result['code'] as int,
        result['errors'] as String,
        result['cancelled'] as bool,
      );
    } on PlatformException catch (error) {
      throw AndroidEncodingFailure(
        error.message ?? 'The Android encoder is unavailable.',
      );
    } on MissingPluginException {
      throw const AndroidEncodingFailure(
        'The Android encoder bridge is unavailable.',
      );
    } finally {
      _activeId = null;
      channel.setMethodCallHandler(null);
    }
  }

  void cancel() {
    final id = _activeId;
    if (id != null) {
      unawaited(
        channel
            .invokeMethod<void>('cancel', {'id': id})
            .catchError((Object _) {}),
      );
    }
  }
}
