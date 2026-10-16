import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kotodl/site.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Serves canned pages by path; anything else is a 404.
class FakeHttp extends Http {
  FakeHttp(this.pages);
  final Map<String, String> pages;
  final requests = <Uri>[];

  @override
  Future<Page> send(Uri url, {Map<String, String>? headers}) async {
    requests.add(url);
    final body = pages[url.path];
    return Page(url, body == null ? 404 : 200, Uint8List.fromList(utf8.encode(body ?? '')));
  }
}
