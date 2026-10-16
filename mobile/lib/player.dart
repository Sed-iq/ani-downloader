/// MegaPlay player helpers, ported from the upstream `anikoto` package
/// (clean_name, js_string, unpack_player_strings, player_parameters, signed_url,
/// decrypt_source). The player script is read statically, never executed.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

class SiteError implements Exception {
  SiteError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The player's public AES key/IV and CDN signing parameters.
typedef PlayerParams = ({String key, String iv, String secret, int ttl});

String cleanName(String name) => name.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();

const _jsString = r'"(?:\\.|[^"\\])*"';

/// Decode a quoted JS string as data, including JS-only escape sequences.
String jsString(String literal) {
  const escapes = {'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v', '0': '\x00'};
  return literal.substring(1, literal.length - 1).replaceAllMapped(
    RegExp(r'\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|\r\n|[\s\S])'),
    (m) {
      final value = m[1]!;
      if ((value.startsWith('x') || value.startsWith('u')) && value.length > 1) {
        return String.fromCharCode(int.parse(value.substring(1), radix: 16));
      }
      if (value == '\n' || value == '\r\n') return '';
      return escapes[value] ?? value;
    },
  );
}

/// Statically decode the player's XOR wrapper and string table.
///
/// The wrapper encrypts an initializer beginning '(function(){function '.
/// Its repeating XOR key is recovered from that known prefix.
String unpackPlayerStrings(String script) {
  final wrapperMatch = RegExp(r'\breturn\s+eval\((' + _jsString + r')\)').firstMatch(script);
  final objectMatch = RegExp(r'^\s*let\s+([\w$]+)\s*;').firstMatch(script);
  if (wrapperMatch == null || objectMatch == null) {
    throw SiteError('Unrecognized player wrapper');
  }
  final wrapper = jsString(wrapperMatch[1]!);
  final payloadMatch = RegExp(r'\}\)\((' + _jsString + r')\)\s*$').firstMatch(wrapper);
  if (payloadMatch == null) throw SiteError('Player payload missing');
  // JS decodeURI leaves reserved URI punctuation escaped.
  final payload = jsString(payloadMatch[1]!).replaceAllMapped(RegExp(r'%[0-9a-fA-F]{2}'), (m) {
    final code = int.parse(m[0]!.substring(1), radix: 16);
    if (code >= 0x80) return '\uFFFD';
    final char = String.fromCharCode(code);
    return ';/?:@&=+\$,#'.contains(char) ? m[0]! : char;
  });

  const prefix = '(function(){function ';
  final n = payload.length < prefix.length ? payload.length : prefix.length;
  final known = [for (var i = 0; i < n; i++) payload.codeUnitAt(i) ^ prefix.codeUnitAt(i)];
  String? decoded;
  for (var size = 1; size <= known.length ~/ 2; size++) {
    var repeats = true;
    for (var i = 0; i < known.length; i++) {
      if (known[i] != known[i % size]) {
        repeats = false;
        break;
      }
    }
    if (!repeats) continue;
    final codes = payload.codeUnits;
    final candidate = String.fromCharCodes([for (var i = 0; i < codes.length; i++) codes[i] ^ known[i % size]]);
    if (candidate.startsWith(prefix) && candidate.trimRight().endsWith('})')) {
      decoded = candidate;
      break;
    }
  }
  if (decoded == null) throw SiteError('Player XOR wrapper changed');

  String unmask(String value, int mask) => String.fromCharCodes(value.codeUnits.map((c) => c ^ mask));
  List<String>? table;
  final arrays = RegExp(r'(?:let|const|var)\s+[\w$]+\s*=\s*(\[\s*(?:' + _jsString + r'\s*,?\s*)*\])');
  for (final array in arrays.allMatches(decoded)) {
    final entries = [for (final m in RegExp(_jsString).allMatches(array[1]!)) jsString(m[0]!)];
    for (final entry in entries) {
      if (entry.length != 'AES-CBC'.length) continue;
      final mask = entry.codeUnitAt(0) ^ 'A'.codeUnitAt(0);
      if (unmask(entry, mask) != 'AES-CBC') continue;
      final candidate = [for (final value in entries) unmask(value, mask)];
      if (['HMAC', 'SHA-256', 'importKey', 'decrypt'].every(candidate.contains)) {
        table = candidate;
        break;
      }
    }
    if (table != null) break;
  }
  if (table == null) throw SiteError('Player string table changed');

  return script.replaceAllMapped(RegExp(RegExp.escape(objectMatch[1]!) + r'\.[\w$]+\((\d+)\)'), (m) {
    final index = int.parse(m[1]!);
    if (index >= table!.length) throw SiteError('Player string index out of range');
    return jsonEncode(table[index]);
  });
}

PlayerParams playerParameters(String script) {
  if (!script.contains('AES-CBC')) script = unpackPlayerStrings(script);
  const literal = '($_jsString)';
  const separator = r'\s*(?:,|;\s*const\s+)\s*';
  final pattern = RegExp(
    r'\bconst\s+[\w$]+\s*=\s*' +
        literal +
        separator +
        r'[\w$]+\s*=\s*' +
        literal +
        separator +
        r'[\w$]+\s*=\s*' +
        literal +
        separator +
        r'[\w$]+\s*=\s*(\d+)\s*;\s*function\s+[\w$]+\(',
  );
  for (final m in pattern.allMatches(script)) {
    final end = m.end + 12000 < script.length ? m.end + 12000 : script.length;
    final nearby = script.substring(m.end, end);
    if (nearby.contains('AES-CBC') && nearby.contains('HMAC')) {
      return (key: jsString(m[1]!), iv: jsString(m[2]!), secret: jsString(m[3]!), ttl: int.parse(m[4]!));
    }
  }
  throw SiteError('Player crypto parameters changed');
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Append the CDN token the player would compute, unless the URL already has one.
String signedUrl(String url, String secret, int ttl, {DateTime? now}) {
  final uri = Uri.parse(url);
  if (uri.queryParameters.containsKey('token')) return url;
  final path = RegExp(r'/([a-f0-9]{32})/([a-f0-9]{32})/', caseSensitive: false).firstMatch(uri.path);
  if (path == null) throw SiteError('Unexpected CDN path');
  final expires = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 + ttl;
  final message = utf8.encode('$expires|${path[1]!.toLowerCase()}/${path[2]!.toLowerCase()}');
  final signature = Hmac(sha256, utf8.encode(secret)).convert(message).bytes;
  final token = '${_b64url(message)}.${_b64url(signature)}';
  return '$url${uri.query.isEmpty ? '?' : '&'}token=${Uri.encodeQueryComponent(token)}';
}

Uint8List _fit(String text, int size) {
  // The JS TextEncoder helper truncates/zero-pads to the AES key/IV size.
  final bytes = utf8.encode(text);
  return Uint8List(size)..setRange(0, bytes.length < size ? bytes.length : size, bytes);
}

dynamic decryptSource(String encoded, String key, String iv) {
  final data = base64Url.decode(encoded.padRight(encoded.length + (-encoded.length % 4), '='));
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(false, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(_fit(key, 32)), _fit(iv, 16)), null));
  return jsonDecode(utf8.decode(cipher.process(Uint8List.fromList(data))));
}
