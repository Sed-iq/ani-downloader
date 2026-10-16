// End to end against the real site: search, episode list, dub stream, and the first
// segments of an episode remuxed with ffmpeg. Needs network and ffmpeg, so it's skipped
// unless asked for: flutter test --tags live --run-skipped
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kotodl/hls.dart';
import 'package:kotodl/m3u8.dart';
import 'package:kotodl/site.dart';

Future<String> ffmpegRemux(String ts, String dest) async {
  final r = await Process.run('ffmpeg', [
    '-nostdin', '-loglevel', 'error', '-y', '-i', ts, //
    '-c', 'copy', '-bsf:a', 'aac_adtstoasc', '-movflags', '+faststart', '-f', 'mp4', dest,
  ]);
  if (r.exitCode != 0) throw Exception(r.stderr);
  return dest;
}

void main() {
  test('search, resolve and download the first segments of an episode', () async {
    final site = Anikoto();
    final results = await site.search('one punch man');
    expect(results.first.title, 'One Punch Man');

    final anime = await site.anime(results.first.url);
    expect(anime.episodes, isNotEmpty);
    final ep = anime.episodes.firstWhere((e) => e.dub);

    final source = await site.dubStream(anime, ep);
    expect(source.variants, isNotEmpty);
    final playlist = Uri.parse(pickVariant(source.variants, 0));
    final media = parseMedia((await site.http.get(playlist, headers: {'referer': source.referer})).body, playlist);
    expect(media.segments.length, greaterThan(10));

    // Serve a playlist cut down to the first segments; they still come from the CDN.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..write('#EXTM3U\n#EXT-X-TARGETDURATION:10\n')
        ..write([for (final s in media.segments.take(6)) '#EXTINF:5,\n$s'].join('\n'))
        ..write('\n#EXT-X-ENDLIST\n')
        ..close();
    });
    final dir = await Directory.systemTemp.createTemp('kotodl_live');
    try {
      final dest = '${dir.path}/One Punch Man - 01.mp4';
      var last = 0;
      final saved = await download(
        'http://127.0.0.1:${server.port}/media.m3u8',
        source.referer,
        dest,
        remux: ffmpegRemux,
        progress: (done, total, _) => last = done,
      );
      expect(saved, dest);
      expect(last, 6);
      final probe = await Process.run('ffprobe', [
        '-v', 'error', '-show_entries', 'stream=codec_type:format=duration', '-of', 'csv=p=0', dest, //
      ]);
      final out = probe.stdout as String;
      // ignore: avoid_print
      print('${File(dest).lengthSync()} bytes\n$out');
      expect(out, contains('video'));
      expect(out, contains('audio'));
    } finally {
      await server.close(force: true);
      await dir.delete(recursive: true);
      site.http.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
