/// First screen: storage access, then the download folder, then the app.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../native.dart';
import '../site.dart';
import '../storage.dart';
import 'classic.dart';
import 'search_page.dart';

class Gate extends StatefulWidget {
  const Gate({super.key});

  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  bool _checking = true;
  bool _entered = false;
  bool _blocked = false; // denied for good: only the settings page can grant it now
  bool _modern = true; // Android 11+: "All files access"
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check(); // back from the settings page
  }

  Future<void> _check() async {
    _modern = await sdkInt() >= 30;
    if (await hasAccess()) {
      await _enter();
    } else if (mounted) {
      setState(() => _checking = false);
    }
  }

  Future<void> _request() async {
    if (_blocked) {
      await openAppSettings();
      return;
    }
    final status = await requestAccess();
    if (status.isGranted) {
      await _enter();
    } else if (mounted) {
      setState(() => _blocked = status.isPermanentlyDenied || _modern);
    }
  }

  Future<void> _enter() async {
    if (_entered) return;
    _entered = true;
    try {
      await rootFolder();
    } catch (e) {
      if (mounted) {
        setState(() {
          _checking = _entered = false;
          _error = brief(e);
        });
      }
      return;
    }
    if (!mounted) return;
    WidgetsBinding.instance.removeObserver(this);
    await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SearchPage()));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TitleBar(title: 'Anikoto Downloader'),
          Expanded(
            child: _checking
                ? const SizedBox.shrink()
                : Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: ClassicWindowFrame(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const TitleBar(title: 'Storage access'),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(14, 18, 14, 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.folder, size: 40, color: Color(0xFFE8C34A)),
                                  const SizedBox(width: 14),
                                  Expanded(child: Text(_text, style: const TextStyle(fontSize: 15, height: 1.35))),
                                ],
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(68, 0, 14, 16),
                              child: Bevel(
                                edge: Edge.sunken,
                                color: Win.base,
                                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                child: Text('/$folderName/<Anime>/', style: TextStyle(fontFamily: 'monospace')),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  ClassicButton(
                                    label: _blocked ? 'Open settings' : 'Allow',
                                    bold: true,
                                    onPressed: _request,
                                  ),
                                  const SizedBox(width: 8),
                                  ClassicButton(label: 'Exit', onPressed: () => SystemNavigator.pop()),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );

  String get _text {
    if (_error != null) return "Can't create the download folder: $_error";
    final how = _modern
        ? 'Turn on "Allow access to manage all files" for Anikoto Downloader.'
        : 'Allow access to storage.';
    return _blocked
        ? 'Storage access is off. Open settings and turn it on.\n\n$how'
        : 'Episodes are saved in an "$folderName" folder on your phone, one folder per anime.\n\n$how';
  }
}
