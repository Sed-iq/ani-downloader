/// Anikoto site access: search, episode list, and English-dub streams.
/// A port of kotodl/scraper.py.
///
/// Flow: watch page -> `/ajax/episode/list/<id>` -> /ajax/server/list (dub servers)
/// -> /ajax/server -> MegaPlay embed -> getSourcesNew (AES) -> signed master.m3u8
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'm3u8.dart';
import 'player.dart';

export 'player.dart' show SiteError, cleanName;

const mirrors = ['anikoto.net', 'anikoto.cz', 'anikoto.tv', 'anikoto.bz'];
const userAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

/// An error as one short line.
String brief(Object error) {
  if (error is SiteError) return error.message;
  if (error is TimeoutException) return 'Timed out';
  if (error is SocketException) return error.osError?.message ?? error.message;
  if (error is HandshakeException) return 'Secure connection failed';
  if (error is HttpError) return 'HTTP ${error.status}';
  final text = error.toString().replaceFirst(RegExp(r'^\w*(Exception|Error): ?'), '').trim();
  return text.isEmpty ? error.runtimeType.toString() : text.split('\n').first;
}

class HttpError implements Exception {
  HttpError(this.status, this.url);
  final int status;
  final Uri url;
  @override
  String toString() => 'HTTP $status';
}

/// A search hit, as listed on the search page.
class Result {
  Result({required this.title, required this.url, this.kind = '', this.dub = '', this.poster, this.jp = ''});
  final String title;
  final String url; // watch page
  final String kind; // TV, Movie, OVA, ...
  final String dub; // dubbed episodes, e.g. "22" or "12/26" while still airing
  final String? poster;
  final String jp; // romaji title, also matched against the query
}

/// Lower is better: exact title, then prefix, then whole word, then substring, then the rest.
(int, int) rank(String query, Result result) {
  final q = query.toLowerCase().trim();
  int score(String title) {
    final t = title.toLowerCase();
    if (t == q) return 0;
    if (t.startsWith(q)) return 1;
    if (RegExp(r'\b' + RegExp.escape(q) + r'\b').hasMatch(t)) return 2;
    return t.contains(q) ? 3 : 4;
  }

  final a = score(result.title), b = score(result.jp.isEmpty ? result.title : result.jp);
  return (a < b ? a : b, result.title.length);
}

class Episode {
  Episode({required this.num, required this.title, required this.ids, required this.dub});
  final String num; // the site's episode number
  final String title;
  final String ids; // opaque token for /ajax/server/list
  final bool dub;
}

class Anime {
  Anime({required this.title, required this.poster, required this.domain, required this.episodes});
  final String title;
  final String? poster;
  final String domain; // mirror that answered, e.g. https://anikoto.net
  final List<Episode> episodes;
}

class Source {
  Source(this.referer, this.variants);
  final String referer;
  final Map<int, String> variants; // height (0 = unknown) -> media playlist URL
}

/// The tallest variant not above [height], else the smallest. 0 means best.
String pickVariant(Map<int, String> variants, int height) {
  final heights = variants.keys.toList()..sort();
  if (height <= 0) return variants[heights.last]!;
  final below = heights.where((h) => h <= height);
  return variants[below.isEmpty ? heights.first : below.last]!;
}

/// A fetched response: the final URL (after redirects), status and body.
class Page {
  Page(this.url, this.status, this.bytes);
  final Uri url;
  final int status;
  final Uint8List bytes;
  String get body => utf8.decode(bytes, allowMalformed: true);
}

/// A shared HTTP client with a browser identity and per-request timeouts.
class Http {
  Http({this.timeout = const Duration(seconds: 30)})
    : _client = IOClient(
        HttpClient()
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30)
          ..maxConnectionsPerHost = 16
          ..userAgent = userAgent,
      );
  final http.Client _client;
  final Duration timeout;

  Future<Page> send(Uri url, {Map<String, String>? headers}) async {
    final request = http.Request('GET', url)..headers.addAll(headers ?? const {});
    final response = await _client.send(request).timeout(timeout);
    final bytes = await response.stream.toBytes().timeout(timeout * 4);
    final at = response is http.BaseResponseWithUrl ? (response as http.BaseResponseWithUrl).url : url;
    return Page(at, response.statusCode, bytes);
  }

  /// GET, retrying once on a dropped connection, failing on a non-2xx status.
  Future<Page> get(Uri url, {Map<String, String>? headers}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final page = await send(url, headers: headers);
        if (page.status >= 400) throw HttpError(page.status, url);
        return page;
      } on HttpError {
        rethrow;
      } on Exception {
        if (attempt > 0) rethrow;
      }
    }
  }

  void close() => _client.close();
}

class Anikoto {
  Anikoto([Http? http]) : http = http ?? Http();
  final Http http;
  final _players = <String, Future<PlayerParams>>{}; // e1-player script URL -> parameters
  String mirror = mirrors.first; // last mirror that answered; searches start there

  static const _xhr = {'x-requested-with': 'XMLHttpRequest'};

  Future<Page> _get(Uri url, {Map<String, String>? headers}) => http.get(url, headers: {..._xhr, ...?headers});

  /// GET a site page, falling back to the other mirrors if the host is down.
  Future<Page> _open(String url) async {
    final parsed = Uri.parse(url.contains('://') ? url : 'https://$url');
    final hosts = [parsed.host];
    if (mirrors.contains(parsed.host)) {
      hosts.addAll([mirror, ...mirrors].where((h) => !hosts.contains(h)));
    }
    Object? error;
    for (final host in {...hosts}) {
      final Page page;
      try {
        page = await http.send(parsed.replace(host: host), headers: _xhr);
      } on Exception catch (e) {
        error = e;
        continue;
      }
      if (page.status == 404) throw SiteError('Anime not found');
      if (page.status >= 400) throw HttpError(page.status, parsed);
      if (mirrors.contains(host)) mirror = host;
      return page;
    }
    throw SiteError("Can't reach ${parsed.host}${error == null ? '' : ' (${brief(error)})'}");
  }

  /// Titles with an English dub matching [query], best match first.
  /// The site's own order is loose, so the first few pages are fetched and re-ranked.
  Future<List<Result>> search(String query, {int pages = 3}) async {
    final params = {'keyword': query, 'language[]': 'dub'};
    var page = await _open(Uri.https(mirror, '/filter', params).toString());
    final base = page.url;
    final results = <String, Result>{};
    for (var n = 1; n <= pages; n++) {
      if (n > 1) page = await _get(base.replace(queryParameters: {...params, 'page': '$n'}));
      final doc = html.parse(page.body);
      for (final item in doc.querySelectorAll('#list-items .item')) {
        final hit = _result(item);
        if (hit != null) results.putIfAbsent(hit.url, () => hit);
      }
      if (doc.querySelector('.pagination a[href*="page=${n + 1}"]') == null) break;
    }
    final sorted = results.values.toList();
    mergeSort(sorted, (a, b) {
      final (x1, x2) = rank(query, a);
      final (y1, y2) = rank(query, b);
      return x1 != y1 ? x1 - y1 : x2 - y2;
    });
    return sorted;
  }

  Future<Anime> anime(String url) async {
    final page = await _open(url);
    final found = RegExp(r'/anime/getinfo/(\d+)').firstMatch(page.body);
    if (found == null) throw SiteError('Not an Anikoto anime page');
    final at = page.url;
    final domain = '${at.scheme}://${at.host}';
    final doc = html.parse(page.body);
    final title = doc.querySelector('h1.d-title');
    final poster = doc.querySelector('img[itemprop=image]');

    final listing = await _get(Uri.parse('$domain/ajax/episode/list/${found[1]}?vrf='));
    final episodes = <Episode>[];
    for (final li in html.parseFragment(jsonDecode(listing.body)['result'] as String).querySelectorAll('li')) {
      if (li.attributes['data-html'] != 'true') continue;
      final a = li.querySelector('a');
      if (a == null || a.attributes['data-ids'] == null) continue;
      episodes.add(
        Episode(
          num: a.attributes['data-num'] ?? '${episodes.length + 1}',
          title: (li.attributes['title'] ?? '').trim(),
          ids: a.attributes['data-ids']!,
          dub: a.attributes['data-dub'] == '1',
        ),
      );
    }
    final name = title?.text.trim() ?? '';
    return Anime(
      title: name.isEmpty ? 'Anime' : name,
      poster: poster?.attributes['src'],
      domain: domain,
      episodes: episodes,
    );
  }

  Future<Uint8List> image(String url) async => (await _get(Uri.parse(url))).bytes;

  /// A Source per dub server, fastest first: servers resolve in parallel, so one
  /// stalled CDN doesn't hold up the rest. Fails if none resolve.
  Stream<Source> dubStreams(Anime anime, Episode episode) async* {
    final servers = await _get(
      Uri.parse('${anime.domain}/ajax/server/list').replace(queryParameters: {'servers': episode.ids}),
    );
    final dub = html
        .parseFragment(jsonDecode(servers.body)['result'] as String)
        .querySelectorAll('div.type[data-type="dub"] li[data-link-id]');
    if (dub.isEmpty) throw SiteError('No dub server');
    final results = StreamController<(String, Source?, Object?)>();
    for (final li in dub) {
      final name = li.text.trim();
      _megaplay(
        anime.domain,
        li.attributes['data-link-id']!,
      ).then((stream) => results.add((name, stream, null)), onError: (Object e) => results.add((name, null, e)));
    }
    final errors = <String>[];
    var left = dub.length;
    await for (final (name, stream, error) in results.stream) {
      if (stream != null) {
        yield stream;
      } else {
        errors.add('$name: ${brief(error!)}');
      }
      if (--left == 0) break;
    }
    if (errors.length == dub.length) throw SiteError(errors.join('; '));
  }

  /// The first server offering [height] (0 = any), else the first that resolved.
  /// Tokens expire in ~90s, so call this right before downloading.
  Future<Source> dubStream(Anime anime, Episode episode, [int height = 0]) async {
    Source? fallback;
    await for (final stream in dubStreams(anime, episode)) {
      if (height <= 0 || stream.variants.containsKey(height)) return stream;
      fallback ??= stream;
    }
    return fallback!;
  }

  Future<PlayerParams> _player(String script) => _players.putIfAbsent(script, () async {
    try {
      return playerParameters((await _get(Uri.parse(script))).body);
    } catch (_) {
      _players.remove(script); // a failed fetch retries next time
      rethrow;
    }
  });

  Future<Source> _megaplay(String domain, String linkId) async {
    final server = await _get(Uri.parse('$domain/ajax/server').replace(queryParameters: {'get': linkId}));
    final embed = (jsonDecode(server.body)['result'] as Map)['url'] as String;
    final embedUri = Uri.parse(embed);
    final doc = html.parse((await _get(embedUri, headers: {'referer': '$domain/'})).body);
    final player = doc.querySelector('#megaplay-player[data-id]');
    final script = doc
        .querySelectorAll('script[src]')
        .map((s) => s.attributes['src']!)
        .where((src) => src.contains('e1-player'))
        .firstOrNull;
    if (player == null || script == null) throw SiteError('Unsupported player');

    final origin = '${embedUri.scheme}://${embedUri.authority}';
    final params = {'id': player.attributes['data-id']!};
    final cdn = embedUri.queryParameters['s']; // the embed forwards ?s= (CDN pick) to getSources
    if (cdn != null) params['s'] = cdn;
    final sources = await _get(
      Uri.parse('$origin/stream/getSourcesNew').replace(queryParameters: params),
      headers: {'referer': embed},
    );
    final data = jsonDecode(sources.body) as Map<String, dynamic>;

    String master;
    if (data.containsKey('enc')) {
      final p = await _player(embedUri.resolve(script).toString());
      master = signedUrl(_file(decryptSource(data['enc'] as String, p.key, p.iv)), p.secret, p.ttl);
    } else {
      master = _file(data['sources']);
    }
    final referer = '$origin/';
    return Source(referer, await _variants(master, referer));
  }

  Future<Map<int, String>> _variants(String master, String referer) async {
    final text = (await http.get(Uri.parse(master), headers: {'referer': referer})).body;
    final variants = parseMaster(text, Uri.parse(master));
    return variants.isEmpty ? {0: master} : variants;
  }
}

Result? _result(dom.Element item) {
  final name = item.querySelector('a.name');
  final href = name?.attributes['href'];
  if (name == null || href == null || href.isEmpty) return null;
  String count(String kind) => item.querySelector('.ep-status.$kind span')?.text.trim() ?? '';
  final dub = count('dub'), total = count('total');
  return Result(
    title: name.text.trim(),
    url: href,
    kind: item.querySelector('.poster .meta .right')?.text.trim() ?? '',
    dub: dub.isNotEmpty && total.isNotEmpty && total != dub ? '$dub/$total' : dub,
    poster: item.querySelector('.poster img')?.attributes['src'],
    jp: name.attributes['data-jp'] ?? '',
  );
}

String _file(dynamic source) {
  if (source is List) {
    source = source.firstWhere((s) => s is Map && (s['file'] ?? '') != '', orElse: () => null);
  }
  if (source is Map) source = source['file'];
  if (source is! String || source.isEmpty) throw SiteError('No stream in player response');
  return source;
}

/// A stable in-place merge sort, so equal ranks keep the site's order (List.sort isn't stable).
void mergeSort<T>(List<T> list, int Function(T, T) compare) {
  if (list.length < 2) return;
  final mid = list.length ~/ 2;
  final left = list.sublist(0, mid), right = list.sublist(mid);
  mergeSort(left, compare);
  mergeSort(right, compare);
  var i = 0, j = 0, k = 0;
  while (i < left.length && j < right.length) {
    list[k++] = compare(left[i], right[j]) <= 0 ? left[i++] : right[j++];
  }
  while (i < left.length) {
    list[k++] = left[i++];
  }
  while (j < right.length) {
    list[k++] = right[j++];
  }
}
