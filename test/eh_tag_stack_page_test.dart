import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/ehentai.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/eh_network/tag_settings.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/translations.dart';

import 'support/fake_http.dart';

void main() {
  final http = useFakeHttp();
  late Map<String, dynamic> data;
  late String language;
  late List<String> history;

  final sources = ComicSource.sources;

  setUpAll(() {
    AppTranslation.translations = {};
    ComicSource.sources = [ehentai];
    // No galleries: keeps the test away from image loading.
    http.text('f_search=', '<html><body></body></html>');
  });

  tearDownAll(() => ComicSource.sources = sources);

  setUp(() {
    data = {};
    EhTagSettings.dataProvider = () => data;
    EhTagSettings.saver = () async {};
    language = appdata.settings[69];
    appdata.settings[69] = '0';
    history = List.of(appdata.searchHistory);
  });

  tearDown(() {
    appdata.settings[69] = language;
    appdata.searchHistory = history;
  });

  /// The request goes through the cookie jar and Dio, which need real
  /// asynchronous time, so let it finish before pumping frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpSearch(WidgetTester tester, String keyword) async {
    await tester.pumpWidget(MaterialApp(
      home: SearchResultPage(keyword: keyword, sourceKey: 'ehentai'),
    ));
    await settle(tester);
  }

  String? lastSearch() =>
      Uri.parse(http.urls.last).queryParameters['f_search'];

  Finder deleteButtonOf(String label) => find.descendant(
        of: find.widgetWithText(InputChip, label),
        matching: find.byTooltip('移除'),
      );

  testWidgets('a stacked search shows its tags as chips and removes them',
      (tester) async {
    await pumpSearch(tester, r'language:chinese female:glasses$');
    expect(find.widgetWithText(InputChip, 'chinese'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'glasses'), findsOneWidget);
    expect(lastSearch(), r'language:chinese female:glasses$');

    await tester.tap(deleteButtonOf('chinese'));
    await settle(tester);
    // One tag left: the page looks like an ordinary search again.
    expect(find.byType(InputChip), findsNothing);
    expect(lastSearch(), r'female:glasses$');
    expect(find.widgetWithText(TextField, r'female:glasses$'), findsOneWidget);
  });

  testWidgets('searches with free text or a single tag have no chips',
      (tester) async {
    await pumpSearch(tester, 'female:glasses');
    expect(find.byType(InputChip), findsNothing);
    await pumpSearch(tester, 'female:glasses touhou');
    expect(find.byType(InputChip), findsNothing);
  });

  testWidgets('no chips when stacking is turned off', (tester) async {
    data['tagStackEnabled'] = false;
    await pumpSearch(tester, 'language:chinese female:glasses');
    expect(find.byType(InputChip), findsNothing);
    expect(lastSearch(), 'language:chinese female:glasses');
  });

  testWidgets('the global language filter becomes a removable chip',
      (tester) async {
    appdata.settings[69] = '1';
    await pumpSearch(tester, 'female:glasses');
    expect(lastSearch(), 'female:glasses language:chinese');
    expect(find.widgetWithText(InputChip, 'chinese'), findsOneWidget);
  });

  testWidgets('a gallery remembers the search it was opened from',
      (tester) async {
    await pumpSearch(tester, 'language:chinese female:glasses');
    SearchPageContext.onComicOpened('ehentai', 'https://e-hentai.org/g/1/a/');
    expect(
        SearchPageContext.keywordForComic(
            'ehentai', 'https://e-hentai.org/g/1/a/'),
        'language:chinese female:glasses');
    // Another source's comics do not pick up an e-hentai search.
    SearchPageContext.onComicOpened('nhentai', '1');
    expect(SearchPageContext.keywordForComic('nhentai', '1'), isNull);
    expect(SearchPageContext.keywordForComic('ehentai', 'unknown'), isNull);

    // Closing the search page forgets it.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(
        SearchPageContext.keywordForComic(
            'ehentai', 'https://e-hentai.org/g/1/a/'),
        isNull);
  });
}
