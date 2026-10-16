import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/classic.dart';
import 'ui/gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Win.highlight,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Win.face,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const KotodlApp());
}

class KotodlApp extends StatelessWidget {
  const KotodlApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Anikoto Downloader',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: false,
      scaffoldBackgroundColor: Win.face,
      colorScheme: const ColorScheme.light(primary: Win.highlight, surface: Win.face),
      textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 15, color: Win.text)),
      textSelectionTheme: const TextSelectionThemeData(
        selectionColor: Win.highlight,
        selectionHandleColor: Win.highlight,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _Instant(), // windows just appear
        },
      ),
    ),
    home: const Gate(),
  );
}

class _Instant extends PageTransitionsBuilder {
  const _Instant();

  @override
  Widget buildTransitions<T>(_, _, _, _, Widget child) => child;
}
