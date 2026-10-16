/// One anime: its episodes, a resolution, and Download.
library;

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../site.dart';
import '../state.dart';
import '../storage.dart';
import 'classic.dart';
import 'search_page.dart';

class AnimePage extends StatefulWidget {
  const AnimePage({super.key, required this.site, required this.search, required this.entry});
  final Anikoto site;
  final Search search;
  final Entry entry;

  @override
  State<AnimePage> createState() => _AnimePageState();
}

class _AnimePageState extends State<AnimePage> {
  Batch? _batch;
  int _height = 0; // 0 = best
  int _preferred = 0; // the last resolution picked, remembered across runs

  Entry get entry => widget.entry;

  @override
  void initState() {
    super.initState();
    entry.addListener(_changed);
    SharedPreferences.getInstance().then((prefs) {
      _preferred = prefs.getInt('quality') ?? 0;
      _changed();
    });
    _changed();
  }

  @override
  void dispose() {
    entry.removeListener(_changed);
    _batch?.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final anime = entry.anime;
    if (anime != null && _batch == null) _batch = Batch(widget.site, anime);
    final heights = _heights;
    _height = heights.contains(_preferred) ? _preferred : heights.first;
    setState(() {});
  }

  List<int> get _heights => entry.heights.isEmpty ? [0] : entry.heights;

  Future<void> _pick(int height) async {
    setState(() => _height = _preferred = height);
    (await SharedPreferences.getInstance()).setInt('quality', height);
  }

  Future<void> _download() async {
    final batch = _batch!;
    if (batch.running) {
      batch.stop();
      return;
    }
    await Permission.notification.request(); // progress while the screen is off; optional
    if (!await hasAccess()) {
      if (!mounted) return;
      await showClassicDialog(
        context,
        title: 'Anikoto Downloader',
        message: 'Storage access was turned off. Turn it back on in settings to save episodes.',
        icon: Icons.warning,
        iconColor: const Color(0xFFC8A000),
      );
      await openAppSettings();
      return;
    }
    await batch.start(_height);
  }

  Future<void> _row(int i) async {
    final batch = _batch!;
    final row = batch.rows[i];
    if (row.state == RowState.done && row.path != null) {
      final result = await OpenFilex.open(row.path!, type: row.path!.endsWith('.ts') ? 'video/mp2t' : 'video/mp4');
      if (result.type != ResultType.done && mounted) {
        await showClassicDialog(
          context,
          title: 'Anikoto Downloader',
          message: 'No app can play this video.\n\n${row.path}',
        );
      }
    } else {
      batch.toggle(i);
    }
  }

  Future<void> _details(int i) async {
    final batch = _batch!, row = batch.rows[i], ep = batch.anime.episodes[i];
    final text = [
      ep.title.isEmpty ? 'Episode ${ep.num}' : ep.title,
      if (!ep.dub) 'No English dub.',
      if (row.error.isNotEmpty) row.error,
      if (row.path != null) row.path!,
    ].join('\n\n');
    await showClassicDialog(context, title: 'Episode ${ep.num}', message: text);
  }

  Future<bool> _confirmLeave() async {
    final answer = await showClassicDialog(
      context,
      title: 'Anikoto Downloader',
      message: 'Stop downloading and go back?',
      icon: Icons.help,
      buttons: const ['Keep going', 'Stop'],
    );
    if (answer == 'Stop') {
      _batch?.stop();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final batch = _batch;
    return ListenableBuilder(
      listenable: batch ?? entry,
      builder: (context, _) {
        final running = batch?.running ?? false;
        return PopScope(
          canPop: !running,
          onPopInvokedWithResult: (didPop, _) async {
            if (!didPop && await _confirmLeave() && context.mounted) Navigator.of(context).pop();
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TitleBar(title: entry.title, onBack: () => Navigator.of(context).maybePop()),
                  _header(),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: ListPanel(child: batch == null ? _loading() : _episodes(batch)),
                    ),
                  ),
                  _controls(batch),
                  StatusBar(message: _message(batch), progress: batch?.overall),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _message(Batch? batch) {
    if (batch != null && (batch.running || batch.message != 'Ready')) return batch.message;
    if (entry.loading) return 'Loading…';
    if (entry.error.isNotEmpty) return entry.error;
    return batch?.message ?? 'Ready';
  }

  Widget _header() {
    final anime = entry.anime;
    final dub = anime?.episodes.where((e) => e.dub).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      child: Row(
        children: [
          Poster(bytes: entry.poster, width: 48),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  anime == null ? '' : '${anime.episodes.length} episodes  ·  $dub English dub',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _loading() => Center(
    child: entry.loading || entry.error.isEmpty
        ? const SizedBox(width: 160, child: ChunkedProgress(value: 0.35))
        : ClassicButton(label: 'Retry', onPressed: () => widget.search.load(entry)),
  );

  Widget _episodes(Batch batch) => ListView.builder(
    itemCount: batch.anime.episodes.length,
    itemExtent: 52,
    itemBuilder: (context, i) {
      final ep = batch.anime.episodes[i], row = batch.rows[i];
      final enabled = ep.dub;
      final color = enabled ? Win.text : Win.disabled;
      return InkWell(
        onTap: enabled || row.path != null ? () => _row(i) : null,
        onLongPress: () => _details(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              ClassicCheck(value: batch.checked.contains(i), enabled: enabled && !batch.running),
              SizedBox(
                width: 40,
                child: Text(
                  ep.num,
                  textAlign: TextAlign.right,
                  style: TextStyle(color: color, fontSize: 14),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  ep.title.isEmpty ? 'Episode ${ep.num}' : ep.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 14),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(width: 92, child: _status(ep, row)),
            ],
          ),
        ),
      );
    },
  );

  Widget _status(Episode ep, EpisodeRow row) {
    if (row.state == RowState.downloading) {
      return Row(
        children: [
          Expanded(child: ChunkedProgress(value: row.progress, height: 16)),
          SizedBox(
            width: 38,
            child: Text(row.label, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)),
          ),
        ],
      );
    }
    final text = ep.dub ? row.label : 'No dub';
    final color = switch (row.state) {
      RowState.failed => const Color(0xFFC00000),
      RowState.done => const Color(0xFF006000),
      _ => ep.dub ? Win.text : Win.disabled,
    };
    return Text(
      text,
      textAlign: TextAlign.right,
      style: TextStyle(fontSize: 13, color: color),
    );
  }

  Widget _controls(Batch? batch) {
    final running = batch?.running ?? false;
    final hasDub = batch != null && batch.anime.episodes.any((e) => e.dub);
    final allChecked = hasDub && batch.checked.length == batch.anime.episodes.where((e) => e.dub).length;
    final heights = _heights;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Row(
        children: [
          ClassicCombo<int>(
            values: heights,
            labels: heights.map(qualityName).toList(),
            value: _height,
            onChanged: running || batch == null ? null : _pick,
          ),
          const SizedBox(width: 6),
          ClassicButton(
            label: allChecked ? 'None' : 'All',
            minWidth: 64,
            onPressed: running || !hasDub ? null : () => batch.checkAll(!allChecked),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ClassicButton(
              label: running ? 'Stop' : 'Download',
              bold: true,
              minWidth: 0,
              onPressed: !hasDub || (batch.stopping) ? null : _download,
            ),
          ),
        ],
      ),
    );
  }
}
