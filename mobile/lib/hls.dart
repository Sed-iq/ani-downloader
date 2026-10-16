/// Download one HLS media playlist to an .mp4: parallel segments, in-order write, then remux.
/// A port of kotodl/hls.py.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'm3u8.dart';
import 'site.dart';

class Cancelled implements Exception {}

/// A cooperative stop flag, the counterpart of Python's threading.Event.
class CancelToken {
  final _done = Completer<void>();
  bool get isSet => _done.isCompleted;
  void set() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Sleep [delay], waking early when cancelled. True if cancelled.
  Future<bool> wait(Duration delay) async {
    await Future.any([_done.future, Future<void>.delayed(delay)]);
    return isSet;
  }
}

const _pngSig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]; // some CDNs disguise segments as images

/// Turns the finished `.ts` into [dest] (an .mp4). Returns the path actually written:
/// a platform that can't remux may keep the transport stream instead.
typedef Remux = Future<String> Function(String ts, String dest);

/// Save the stream at [dest]. [progress] (done, total, bytes) is called after each segment,
/// bytes counting only what this run fetched. Returns the saved file's path.
///
/// A failed or stopped download leaves `dest.part.ts` behind, and the next call resumes it.
Future<String> download(
  String playlistUrl,
  String referer,
  String dest, {
  required Remux remux,
  void Function(int done, int total, int bytes)? progress,
  CancelToken? cancel,
  int workers = 8,
  int retries = 8,
  Http? http,
}) async {
  cancel ??= CancelToken();
  final client = http ?? Http(timeout: const Duration(seconds: 60));
  final headers = {'referer': referer};
  try {
    var url = Uri.parse(playlistUrl);
    var text = (await client.get(url, headers: headers)).body;
    final variants = parseMaster(text, url);
    if (variants.isNotEmpty) {
      url = Uri.parse(variants[variants.keys.reduce(max)]!);
      text = (await client.get(url, headers: headers)).body;
    }
    final media = parseMedia(text, url);
    if (media.encrypted) throw SiteError('Encrypted stream not supported');
    final segments = media.segments;
    if (segments.isEmpty) throw SiteError('Empty playlist');

    var finished = false; // set once the write loop ends, so stragglers in the window give up
    Future<Uint8List> fetch(String segment) async {
      Uint8List data;
      for (var attempt = 0; ; attempt++) {
        if (cancel!.isSet || finished) throw Cancelled();
        try {
          data = (await client.get(Uri.parse(segment), headers: headers)).bytes;
          break;
        } on Exception catch (e) {
          if (attempt == retries - 1) rethrow;
          // Back off, so a rate limit (429) gets time to lift instead of eating every retry.
          final wait = e is HttpError && (e.status == 429 || e.status == 503) ? 10 : min(1 << attempt, 30);
          if (await cancel.wait(Duration(seconds: wait))) throw Cancelled();
        }
      }
      if (_indexOf(data, _pngSig, limit: 1) == 0) {
        final end = _indexOf(data, const [0x49, 0x45, 0x4E, 0x44]); // IEND
        if (end != -1) data = Uint8List.sublistView(data, end + 8); // 'IEND' + CRC
      }
      return data;
    }

    final ts = '$dest.part.ts', mark = '$dest.part.ts.done';
    final (start, offset) = await _resumePoint(ts, mark, segments.length);
    final queue = segments.sublist(start).iterator;
    final pending = Queue<Future<Uint8List>>();

    void submit() {
      if (queue.moveNext()) {
        final future = fetch(queue.current);
        future.ignore(); // errors surface when awaited in order; don't report them as unhandled
        pending.add(future);
      }
    }

    for (var i = 0; i < workers * 2; i++) {
      submit(); // bounded window keeps memory flat
    }
    var done = start, size = 0;
    final out = await File(ts).open(mode: start > 0 ? FileMode.append : FileMode.write);
    try {
      await out.truncate(offset); // drop a segment half-written when the last run died
      await out.setPosition(offset);
      while (pending.isNotEmpty) {
        final data = await pending.removeFirst();
        if (cancel.isSet) throw Cancelled();
        await out.writeFrom(data);
        await out.flush();
        done += 1;
        size += data.length;
        await _writeMark(mark, done, segments.length, await out.position());
        progress?.call(done, segments.length, size);
        submit();
      }
    } finally {
      finished = true;
      await out.close();
    }
    final saved = await remux(ts, dest);
    for (final leftover in [ts, mark]) {
      if (leftover != saved && File(leftover).existsSync()) await File(leftover).delete();
    }
    return saved;
  } finally {
    if (http == null) client.close();
  }
}

/// First index of [needle] in [data], looking at no more than [limit] start positions.
int _indexOf(Uint8List data, List<int> needle, {int? limit}) {
  final last = min(data.length - needle.length, (limit ?? data.length) - 1);
  outer:
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (data[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// (segments, bytes) already saved by an earlier run of the same stream, else (0, 0).
Future<(int, int)> _resumePoint(String ts, String mark, int total) async {
  try {
    final parts = (await File(mark).readAsString()).trim().split(RegExp(r'\s+')).map(int.parse).toList();
    final (done, count, offset) = (parts[0], parts[1], parts[2]);
    if (count != total || done > total || !File(ts).existsSync() || File(ts).lengthSync() < offset) return (0, 0);
    return (done, offset);
  } catch (_) {
    return (0, 0);
  }
}

Future<void> _writeMark(String mark, int done, int total, int offset) async {
  final tmp = File('$mark.tmp');
  await tmp.writeAsString('$done $total $offset\n', flush: true);
  await tmp.rename(mark);
}
