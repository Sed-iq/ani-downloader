/// Search a title (or paste a watch URL) and pick a result.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../site.dart';
import '../state.dart';
import 'anime_page.dart';
import 'classic.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.site});
  final Anikoto? site; // for tests

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _site = widget.site ?? Anikoto();
  late final _search = Search(_site);
  final _query = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    _query.dispose();
    _site.http.close();
    super.dispose();
  }

  void _go() {
    FocusScope.of(context).unfocus();
    _search.search(_query.text);
  }

  void _open(Entry entry) {
    _search.load(entry); // retries a failed probe
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AnimePage(site: _site, search: _search, entry: entry),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListenableBuilder(
        listenable: _search,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TitleBar(title: 'Anikoto Downloader'),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: ClassicField(
                      controller: _query,
                      hint: 'Anime name or URL',
                      enabled: !_search.busy,
                      onSubmitted: (_) => _go(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ClassicButton(label: 'Search', bold: true, minWidth: 80, onPressed: _search.busy ? null : _go),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ListPanel(
                  child: _search.entries.isEmpty
                      ? const SizedBox.expand()
                      : ListView.separated(
                          itemCount: _search.entries.length,
                          separatorBuilder: (_, _) => const Divider(height: 1, color: Win.midlight),
                          itemBuilder: (context, i) => _ResultTile(entry: _search.entries[i], onTap: _open),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            StatusBar(message: _search.message),
          ],
        ),
      ),
    ),
  );
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.entry, required this.onTap});
  final Entry entry;
  final ValueChanged<Entry> onTap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: entry,
    builder: (context, _) {
      final r = entry.result;
      final res = entry.heights.isNotEmpty
          ? entry.heights.map(qualityName).join(' · ')
          : entry.loading || entry.queued
          ? '…'
          : entry.done || entry.error.isNotEmpty
          ? '—'
          : '';
      final meta = [
        if (r.kind.isNotEmpty) r.kind,
        if (entry.dub.isNotEmpty) 'Dub ${entry.dub}',
        if (res.isNotEmpty) res,
      ].join('   ');
      return InkWell(
        onTap: () => onTap(entry),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              Poster(bytes: entry.poster, width: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Win.shadow),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A cover image in a sunken frame, blank until it loads.
class Poster extends StatelessWidget {
  const Poster({super.key, required this.bytes, required this.width});
  final Uint8List? bytes;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: width * 66 / 48,
    child: Bevel(
      edge: Edge.sunken,
      child: bytes == null
          ? const SizedBox.expand()
          : Image.memory(
              bytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.expand(),
            ),
    ),
  );
}
