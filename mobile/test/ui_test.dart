// The screens on a small phone, against canned site pages: search, pick, episodes, select.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotodl/site.dart';
import 'package:kotodl/ui/classic.dart';
import 'package:kotodl/ui/search_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_http.dart';

final pages = {
  '/filter': fixture('filter.html'),
  '/watch/one-punch-man-jylym/ep-1': '<h1 class="d-title">One Punch Man</h1><script>"/anime/getinfo/1607"</script>',
  '/ajax/episode/list/1607': fixture('episodes.json'),
};

Future<void> pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 640) * 3; // a small phone
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(MaterialApp(home: SearchPage(site: Anikoto(FakeHttp(pages)))));
}

void main() {
  testWidgets('search, open a title, pick episodes', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'one punch man');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.text('One Punch Man'), findsOneWidget);
    expect(find.text('30 found'), findsOneWidget);

    await tester.tap(find.text('One Punch Man'));
    await tester.pumpAndSettle();
    expect(find.text('12 episodes  ·  12 English dub'), findsOneWidget);
    expect(find.text('The Strongest Man'), findsOneWidget);
    expect(find.text('Best'), findsOneWidget, reason: 'no resolutions found, so the server picks');

    ClassicCheck check(int i) => tester.widgetList<ClassicCheck>(find.byType(ClassicCheck)).elementAt(i);
    expect(check(0).value, isTrue, reason: 'every dubbed episode starts checked');
    await tester.tap(find.text('The Strongest Man'));
    await tester.pump();
    expect(check(0).value, isFalse);
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(check(0).value, isTrue);
    await tester.tap(find.text('None'));
    await tester.pump();
    expect(check(1).value, isFalse);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('30 found'), findsOneWidget);
  });

  testWidgets('a pasted link opens directly', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'https://anikoto.net/watch/one-punch-man-jylym/ep-1');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    // The probe loads it straight away, and the row takes the anime's title.
    expect(find.textContaining('https://'), findsOneWidget, reason: 'only the search field');
    await tester.tap(find.descendant(of: find.byType(ListView), matching: find.text('One Punch Man')));
    await tester.pumpAndSettle();
    expect(find.text('One Punch Man'), findsWidgets);
    expect(find.text('The Strongest Man'), findsOneWidget);
  });
}
