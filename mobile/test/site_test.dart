// Offline checks of the scraper port against pages captured from the site, with the
// expected values computed by the Python version (kotodl + anikoto).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kotodl/m3u8.dart';
import 'package:kotodl/player.dart';
import 'package:kotodl/site.dart';

import 'fake_http.dart';

final expected = jsonDecode(fixture('expected.json')) as Map<String, dynamic>;

void main() {
  group('player', () {
    final params = expected['params'] as List;

    for (final script in ['player_new.js', 'player_vjs.js']) {
      test('parameters from $script', () {
        final p = playerParameters(fixture(script));
        expect([p.key, p.iv, p.secret, p.ttl], params);
      });
    }

    test('decrypts the source', () {
      final enc = (jsonDecode(fixture('sources.json')) as Map)['enc'] as String;
      expect(decryptSource(enc, params[0] as String, params[1] as String), expected['decrypted']);
    });

    test('signs CDN URLs like the player', () {
      final signed = expected['signed'] as Map;
      final now = DateTime.fromMillisecondsSinceEpoch((signed['now'] as int) * 1000);
      final url = (expected['decrypted'] as Map)['file'] as String;
      expect(signedUrl(url, params[2] as String, params[3] as int, now: now), signed['url']);
      expect(signedUrl('${signed['url']}', 'x', 1), signed['url'], reason: 'already signed');
    });

    test('jsString decodes JS escapes', () {
      expect(jsString(r'"a\x41B\n\"q\""'), 'aAB\n"q"');
    });

    test('cleanName', () {
      expect(cleanName(' Re:Zero  /  Part? 2 '), 'Re_Zero _ Part_ 2');
    });
  });

  group('site', () {
    test('search parses and ranks like the desktop app', () async {
      final site = Anikoto(FakeHttp({'/filter': fixture('filter.html')}));
      final results = await site.search('one punch man');
      expect([
        for (final r in results) [r.title, r.url, r.kind, r.dub, r.poster, r.jp],
      ], expected['search']);
    });

    test('episode list', () async {
      final http = FakeHttp({
        '/watch/one-punch-man-jylym/ep-1':
            '<h1 class="d-title">One Punch Man</h1>'
            '<img itemprop="image" src="https://x/p.jpg"><script>"/anime/getinfo/1607"</script>',
        '/ajax/episode/list/1607': fixture('episodes.json'),
      });
      final anime = await Anikoto(http).anime('https://anikoto.net/watch/one-punch-man-jylym/ep-1');
      expect(anime.title, 'One Punch Man');
      expect(anime.poster, 'https://x/p.jpg');
      expect(anime.domain, 'https://anikoto.net');
      expect(anime.episodes.length, 12);
      expect(anime.episodes.first.num, '1');
      expect(anime.episodes.first.title, 'The Strongest Man');
      expect(anime.episodes.every((e) => e.dub), isTrue);
    });

    test('falls back to another mirror when one is down', () async {
      final http = _DownHttp({'/filter': fixture('filter.html')});
      final site = Anikoto(http);
      expect(await site.search('one punch man'), isNotEmpty);
      expect(site.mirror, 'anikoto.cz');
    });

    test('pickVariant', () {
      final v = {480: 'a', 720: 'b', 1080: 'c'};
      expect(pickVariant(v, 0), 'c');
      expect(pickVariant(v, 720), 'b');
      expect(pickVariant(v, 900), 'b');
      expect(pickVariant(v, 360), 'a');
    });
  });

  group('m3u8', () {
    final base = Uri.parse('https://cdn.example/anime/a/b/master.m3u8');

    test('master playlist', () {
      const text =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480,CODECS="avc1.4d401f,mp4a.40.2"\n'
          'index-480.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n'
          'https://other.example/index-1080.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080\n'
          'index-1080-low.m3u8\n';
      expect(parseMaster(text, base), {
        480: 'https://cdn.example/anime/a/b/index-480.m3u8',
        1080: 'https://other.example/index-1080.m3u8',
      });
    });

    test('media playlist', () {
      const text =
          '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nseg-1.ts\n#EXTINF:10,\n/abs/seg-2.ts\n#EXT-X-ENDLIST\n';
      final media = parseMedia(text, base);
      expect(media.segments, ['https://cdn.example/anime/a/b/seg-1.ts', 'https://cdn.example/abs/seg-2.ts']);
      expect(media.encrypted, isFalse);
      expect(parseMedia('#EXT-X-KEY:METHOD=AES-128,URI="k"\nseg.ts', base).encrypted, isTrue);
    });
  });
}

/// anikoto.net refuses connections; the other mirrors answer.
class _DownHttp extends FakeHttp {
  _DownHttp(super.pages);

  @override
  Future<Page> send(Uri url, {Map<String, String>? headers}) {
    if (url.host == 'anikoto.net') throw const SocketException('Connection refused');
    return super.send(url, headers: headers);
  }
}
