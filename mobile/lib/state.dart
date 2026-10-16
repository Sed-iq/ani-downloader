/// What the screens show: search results being probed, and a download batch.
/// The same logic as the desktop Window in kotodl/ui.py.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'hls.dart' as hls;
import 'native.dart' as native;
import 'site.dart';
import 'storage.dart';

const probeAhead = 12, probeWorkers = 4; // top results whose resolutions are checked unasked

String qualityName(int height) => height > 0 ? '${height}p' : 'Best';

/// A search result and what has been learned about it so far.
class Entry extends ChangeNotifier {
  Entry(this.result);
  final Result result;
  Anime? anime;
  List<int> heights = []; // tallest first
  Uint8List? poster;
  String error = '';
  bool queued = false; // waiting in the background probe
  bool loading = false, done = false;

  String get title => anime?.title ?? result.title;
  String get dub => result.dub.isNotEmpty ? result.dub : '${anime?.episodes.where((e) => e.dub).length ?? ''}';

  void changed() => notifyListeners();
}

class Search extends ChangeNotifier {
  Search(this.site);
  final Anikoto site;
  int _gen = 0; // bumped by every search, so late answers to an older one are dropped
  List<Entry> entries = [];
  bool busy = false;
  String message = 'Ready';

  Future<void> search(String text) async {
    text = text.trim();
    if (text.isEmpty || busy) return;
    final gen = ++_gen;
    entries = [];
    busy = true;
    message = 'Searching…';
    notifyListeners();
    List<Result>? results;
    String? error;
    if (text.contains('://') || text.contains('/watch/')) {
      results = [Result(title: text, url: text)]; // a pasted watch link opens directly
    } else {
      try {
        results = await site.search(text);
      } catch (e) {
        error = brief(e);
      }
    }
    if (gen != _gen) return;
    busy = false;
    entries = [for (final r in results ?? <Result>[]) Entry(r)];
    message = error ?? (entries.isEmpty ? 'No English dub found' : '${entries.length} found');
    notifyListeners();
    final ahead = entries.take(probeAhead).toList();
    for (final e in ahead) {
      e.queued = true;
    }
    var next = 0;
    for (var w = 0; w < probeWorkers; w++) {
      unawaited(() async {
        while (gen == _gen && next < ahead.length) {
          final entry = ahead[next++];
          entry.queued = false;
          await load(entry);
        }
      }());
    }
  }

  /// Fetch a result's episode list, then its resolutions (every dub server's, combined).
  /// Does nothing if that's done or underway.
  Future<void> load(Entry entry) async {
    if (entry.done || entry.loading) return;
    entry
      ..loading = true
      ..error = ''
      ..changed();
    try {
      final url = entry.result.poster;
      if (url != null && entry.poster == null) unawaited(_poster(entry, url));
      final anime = entry.anime ??= await site.anime(entry.result.url);
      entry.changed();
      if (entry.poster == null && anime.poster != null) unawaited(_poster(entry, anime.poster!));
      final first = anime.episodes.where((e) => e.dub).firstOrNull;
      if (first == null) {
        entry
          ..error = 'No English dub'
          ..done = true;
        return;
      }
      final heights = <int>{};
      try {
        await for (final source in site.dubStreams(anime, first)) {
          heights.addAll(source.variants.keys); // servers can offer different sets
          entry
            ..heights = (heights.toList()..sort((a, b) => b - a))
            ..changed();
        }
      } catch (e) {
        entry.error = brief(e); // keep "Best"; each episode is resolved again at download time
      }
      entry.done = heights.isNotEmpty; // a failed check retries when opened again
    } catch (e) {
      entry.error = brief(e);
    } finally {
      entry
        ..loading = false
        ..changed();
    }
  }

  Future<void> _poster(Entry entry, String url) async {
    try {
      entry
        ..poster = await site.image(url)
        ..changed();
    } catch (_) {}
  }
}

enum RowState { idle, queued, resolving, downloading, done, failed, stopped }

class EpisodeRow {
  RowState state = RowState.idle;
  double progress = 0;
  String? path; // saved file
  String error = '';

  String get label => switch (state) {
    RowState.idle => '',
    RowState.queued => 'Queued',
    RowState.resolving => 'Resolving…',
    RowState.downloading => '${(progress * 100).floor()}%',
    RowState.done => 'Done',
    RowState.failed => 'Failed',
    RowState.stopped => 'Stopped',
  };
}

/// One anime's episode list and the batch downloading it.
class Batch extends ChangeNotifier {
  Batch(this.site, this.anime) : rows = [for (final _ in anime.episodes) EpisodeRow()] {
    checked = {
      for (final (i, e) in anime.episodes.indexed)
        if (e.dub) i,
    };
    unawaited(_findSaved());
  }

  final Anikoto site;
  final Anime anime;
  final List<EpisodeRow> rows;
  late Set<int> checked;
  hls.CancelToken? _cancel;
  String message = 'Ready';
  double? overall; // 0-1 while running
  String? folder;

  bool get running => _cancel != null;
  bool get stopping => _cancel?.isSet ?? false;

  // The page can close while a stopped batch is still winding down.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void toggle(int i) {
    if (running || !anime.episodes[i].dub) return;
    checked.contains(i) ? checked.remove(i) : checked.add(i);
    notifyListeners();
  }

  void checkAll(bool on) {
    if (running) return;
    checked = on
        ? {
            for (final (i, e) in anime.episodes.indexed)
              if (e.dub) i,
          }
        : {};
    notifyListeners();
  }

  String _name(Episode ep) {
    final width = anime.episodes.map((e) => e.num.length).fold(1, (a, b) => a > b ? a : b); // zero-pad so files sort
    return [
      cleanName(anime.title),
      ep.num.padLeft(width, '0'),
      cleanName(ep.title),
    ].where((s) => s.isNotEmpty).join(' - ');
  }

  /// An episode saved by an earlier run, as .mp4 or as the .ts fallback.
  String? _existing(String dir, Episode ep) {
    for (final ext in ['mp4', 'ts']) {
      final path = '$dir/${_name(ep)}.$ext';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  Future<void> _findSaved() async {
    try {
      final dir = '${(await rootFolder()).path}/${cleanName(anime.title)}';
      if (!Directory(dir).existsSync()) return;
      for (final (i, ep) in anime.episodes.indexed) {
        final path = _existing(dir, ep);
        if (path != null && rows[i].state == RowState.idle) {
          rows[i]
            ..state = RowState.done
            ..path = path;
          checked.remove(i);
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  void stop() {
    _cancel?.set();
    message = 'Stopping…';
    notifyListeners();
  }

  Future<void> start(int height) async {
    if (running) return;
    final jobs = [
      for (final (i, e) in anime.episodes.indexed)
        if (e.dub && checked.contains(i)) i,
    ];
    if (jobs.isEmpty) {
      message = 'Nothing checked';
      notifyListeners();
      return;
    }
    final cancel = _cancel = hls.CancelToken();
    for (final i in jobs) {
      rows[i]
        ..state = RowState.queued
        ..error = '';
    }
    overall = 0;
    message = 'Starting…';
    notifyListeners();
    final String dir;
    try {
      dir = folder = (await animeFolder(anime.title)).path;
    } catch (e) {
      for (final i in jobs) {
        rows[i].state = RowState.idle;
      }
      message = "Can't create the folder: ${brief(e)}";
      overall = _cancel = null;
      notifyListeners();
      return;
    }
    try {
      await native.serviceStart('Starting…');
    } catch (_) {} // no service: the batch still runs while the app is open

    var saved = 0, failed = 0;
    for (final (n, i) in jobs.indexed) {
      if (cancel.isSet) break;
      final ep = anime.episodes[i], row = rows[i];
      final existing = _existing(dir, ep);
      if (existing != null) {
        saved++;
        row
          ..state = RowState.done
          ..path = existing;
        notifyListeners();
        continue;
      }
      row.state = RowState.resolving;
      _overall(n, jobs.length, 0, 0);
      var started = DateTime.now();
      try {
        final source = await site.dubStream(anime, ep, height);
        started = DateTime.now(); // speed excludes resolving
        var shown = -1;
        row.path = await hls.download(
          pickVariant(source.variants, height),
          source.referer,
          '$dir/${_name(ep)}.mp4',
          remux: native.remux,
          cancel: cancel,
          progress: (done, total, bytes) {
            final percent = done * 100 ~/ total;
            if (percent == shown) return;
            shown = percent;
            row
              ..state = RowState.downloading
              ..progress = done / total;
            final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
            _overall(n, jobs.length, done / total, bytes / (seconds > 0.001 ? seconds : 0.001));
          },
        );
        row.state = RowState.done;
        saved++;
      } on hls.Cancelled {
        row.state = RowState.stopped;
        break;
      } catch (e) {
        if (cancel.isSet) {
          row.state = RowState.stopped;
          break;
        }
        failed++;
        row
          ..state = RowState.failed
          ..error = brief(e);
      }
      notifyListeners();
    }

    for (final row in rows) {
      if (row.state == RowState.queued) row.state = RowState.idle;
    }
    for (final (i, row) in rows.indexed) {
      if (row.state == RowState.done) checked.remove(i);
    }
    final parts = ['$saved saved', if (failed > 0) '$failed failed', if (cancel.isSet) 'stopped'];
    message = parts.join(',  ');
    overall = null;
    _cancel = null;
    notifyListeners();
    try {
      await native.serviceStop('${anime.title}: ${parts.join(', ')}');
    } catch (_) {}
  }

  void _overall(int n, int total, double fraction, double speed) {
    overall = (n + fraction) / total;
    final rate = speed > 0 ? '  ·  ${(speed / 1e6).toStringAsFixed(1)} MB/s' : '';
    message = 'Episode ${n + 1} of $total$rate';
    notifyListeners();
    unawaited(
      native.serviceUpdate('${anime.title}: episode ${n + 1} of $total', (overall! * 1000).round()).catchError((_) {}),
    );
  }
}
