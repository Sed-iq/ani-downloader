/// The Android side (MainActivity.kt): storage root, remux, media scan, and the
/// foreground service that keeps a batch alive while the phone is locked.
library;

import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('kotodl/native');

Future<int> sdkInt() async => await _channel.invokeMethod<int>('sdkInt') ?? 0;

/// The shared storage root, e.g. /storage/emulated/0.
Future<String> storageRoot() async => await _channel.invokeMethod<String>('storageRoot') ?? '/storage/emulated/0';

/// Remux [ts] into the .mp4 [dest] with MediaMuxer. If the phone can't, the transport
/// stream is kept next to it as .ts, which video players still open.
Future<String> remux(String ts, String dest) async {
  var saved = dest;
  try {
    await _channel.invokeMethod<void>('remux', {'src': ts, 'dest': dest});
  } on PlatformException {
    saved = dest.replaceFirst(RegExp(r'\.mp4$'), '.ts');
    await File(ts).rename(saved);
  }
  await _channel.invokeMethod<void>('scan', {'path': saved}); // show it in the gallery
  return saved;
}

/// Start the foreground service. Call while the app is on screen.
Future<void> serviceStart(String text) => _channel.invokeMethod('serviceStart', {'text': text});

/// Update the service's notification; [progress] is 0-1000, or null for none.
Future<void> serviceUpdate(String text, [int? progress]) =>
    _channel.invokeMethod('serviceUpdate', {'text': text, 'progress': progress});

/// Stop the service. [text], if given, stays behind as a plain notification.
Future<void> serviceStop([String? text]) => _channel.invokeMethod('serviceStop', {'text': text});
