// The segment downloader against a local server: order, PNG-disguised segments,
// retries, and resuming a stopped download.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kotodl/hls.dart';

const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 0x49, 0x45, 0x4E, 0x44, 9, 9, 9, 9];

void main() {
  late HttpServer server;
  late Directory dir;
  final hits = <String, int>{};
  var failFirst = <String>{};
  var gate = <String, Future<void>>{}; // segment -> held until completed

  Uint8List segment(int i) => Uint8List.fromList(List.filled(1000 + i, 0x40 + i));

  setUp(() async {
    hits.clear();
    failFirst = {};
    gate = {};
    dir = await Directory.systemTemp.createTemp('kotodl_hls');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      if (request.headers.value('referer') != 'https://ref/') {
        request.response.statusCode = 403;
      } else if (path == '/master.m3u8') {
        request.response.write(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1x360\nlow.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=9,RESOLUTION=1x720\nmedia.m3u8\n',
        );
      } else if (path == '/media.m3u8') {
        request.response.write('#EXTM3U\n${[for (var i = 0; i < 20; i++) '#EXTINF:1,\nseg-$i.ts'].join('\n')}\n');
      } else if (path.startsWith('/seg-')) {
        final i = int.parse(path.substring(5, path.length - 3));
        await gate[path];
        if (failFirst.remove(path)) {
          request.response.statusCode = 500;
        } else {
          if (i == 3) request.response.add(png); // a segment disguised as an image
          request.response.add(segment(i));
        }
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  Future<String> copyRemux(String ts, String dest) async {
    await File(ts).copy(dest);
    return dest;
  }

  final whole = [for (var i = 0; i < 20; i++) ...List.filled(1000 + i, 0x40 + i)];

  test('downloads the tallest variant in order', () async {
    final dest = '${dir.path}/ep.mp4';
    final seen = <int>[];
    failFirst = {'/seg-5.ts'}; // one transient error is retried
    final saved = await download(
      url('/master.m3u8'),
      'https://ref/',
      dest,
      remux: copyRemux,
      progress: (done, total, _) => seen.add(done),
    );
    expect(saved, dest);
    expect(File(dest).readAsBytesSync(), whole);
    expect(seen, [for (var i = 1; i <= 20; i++) i]);
    expect(hits['/low.m3u8'], isNull);
    expect(hits['/seg-5.ts'], 2);
    expect(File('$dest.part.ts').existsSync(), isFalse);
    expect(File('$dest.part.ts.done').existsSync(), isFalse);
  });

  test('a stopped download resumes where it left off', () async {
    final dest = '${dir.path}/ep.mp4';
    final cancel = CancelToken();
    gate = {'/seg-10.ts': Future.delayed(const Duration(milliseconds: 300))};
    await expectLater(
      download(
        url('/media.m3u8'),
        'https://ref/',
        dest,
        remux: copyRemux,
        cancel: cancel,
        workers: 2,
        progress: (done, _, _) {
          if (done == 10) cancel.set();
        },
      ),
      throwsA(isA<Cancelled>()),
    );
    expect(File(dest).existsSync(), isFalse);
    expect(File('$dest.part.ts.done').readAsStringSync().split(' ').first, '10');

    hits.clear();
    gate = {};
    await download(url('/media.m3u8'), 'https://ref/', dest, remux: copyRemux);
    expect(File(dest).readAsBytesSync(), whole);
    expect(hits.keys.where((k) => k.startsWith('/seg-')).length, 10, reason: 'only the missing half is fetched');
  });

  test('a segment that keeps failing fails the download', () async {
    failFirst = {'/seg-2.ts'};
    final flaky = download(url('/media.m3u8'), 'https://ref/', '${dir.path}/ep.mp4', remux: copyRemux, retries: 1);
    await expectLater(flaky, throwsA(anything));
  });
}
