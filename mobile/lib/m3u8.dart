/// Just enough HLS playlist parsing for the dub streams.
library;

Map<String, String> _attributes(String line) => {
  for (final m in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)').allMatches(line.substring(line.indexOf(':') + 1)))
    m[1]!: m[2]!.replaceAll('"', ''),
};

/// Variant streams of a master playlist as height (0 = unknown) -> absolute URL.
/// Highest bandwidth wins per height. Empty for a media playlist.
Map<int, String> parseMaster(String text, Uri base) {
  final found = <(int, int, String)>[]; // bandwidth, height, url
  Map<String, String>? pending;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pending = _attributes(line);
    } else if (pending != null && line.isNotEmpty && !line.startsWith('#')) {
      final resolution = pending['RESOLUTION']?.split('x');
      found.add((
        int.tryParse(pending['BANDWIDTH'] ?? '') ?? 0,
        resolution != null && resolution.length == 2 ? int.tryParse(resolution[1]) ?? 0 : 0,
        base.resolve(line).toString(),
      ));
      pending = null;
    }
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return {for (final (_, height, url) in found) height: url};
}

class MediaPlaylist {
  MediaPlaylist(this.segments, this.encrypted);
  final List<String> segments; // absolute URLs
  final bool encrypted;
}

MediaPlaylist parseMedia(String text, Uri base) {
  final segments = <String>[];
  var encrypted = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-KEY:')) {
      final method = _attributes(line)['METHOD'];
      if (method != null && method != 'NONE') encrypted = true;
    } else if (!line.startsWith('#')) {
      segments.add(base.resolve(line).toString());
    }
  }
  return MediaPlaylist(segments, encrypted);
}
