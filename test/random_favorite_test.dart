import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/comic_source/built_in/rule34video.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/rule34video/models.dart';
import 'package:pica_comic/pages/favorites/random_favorite.dart';
import 'package:pica_comic/tools/translations.dart';

/// Hands out the numbers it was given, then zeros.
class ScriptedRandom implements Random {
  ScriptedRandom(this.numbers);

  final List<int> numbers;

  @override
  int nextInt(int max) {
    var n = numbers.isEmpty ? 0 : numbers.removeAt(0);
    expect(n, lessThan(max), reason: 'drew $n of $max');
    return n;
  }

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

FavoriteItem item(FavoriteType type, String target) => FavoriteItem(
    target: target,
    name: target,
    coverPath: 'cover/$target',
    author: '',
    type: type,
    tags: const []);

CustomComic comic(String id) =>
    CustomComic(id, '', 'cover/$id', id, const [], '', 'nhentai');

void main() {
  late List<ComicSource> saved;

  setUpAll(() => AppTranslation.translations = {});

  setUp(() {
    saved = List.of(ComicSource.sources);
    // picacg is turned off.
    ComicSource.sources
      ..clear()
      ..addAll([nhentai, rule34video]);
  });

  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(saved);
  });

  test('drawing again does not give the one just drawn', () {
    var random = Random(1);
    for (var i = 0; i < 50; i++) {
      expect(pickAtRandom([1, 2], random, avoid: (n) => n == 1), 2);
    }
    // Unless there is nothing else.
    expect(pickAtRandom([1], random, avoid: (n) => n == 1), 1);
  });

  group('a local folder', () {
    final folder = [
      item(FavoriteType.picacg, 'p1'),
      item(FavoriteType.nhentai, '123'),
      item(FavoriteType(rule34videoKey.hashCode), '4742602/the-witch'),
    ];

    test('mixes every source, videos too, but not turned-off ones', () async {
      var draw = drawFromLocalFolder('f',
          comics: (name) => name == 'f' ? folder : [],
          random: ScriptedRandom([0, 0, 0]));
      var first = (await draw()).data;
      expect(first.sourceKey, 'nhentai');
      expect(first.id, '123');
      expect(first.cover, 'cover/123');
      // The other one now, never the one before.
      var second = (await draw()).data;
      expect(second.sourceKey, rule34videoKey);
      expect(second.id, '4742602/the-witch');
      expect((await draw()).data.id, '123');
    });

    test('with nothing that can be opened, says so', () async {
      var draw = drawFromLocalFolder('f',
          comics: (_) => [item(FavoriteType.picacg, 'p1')]);
      var res = await draw();
      expect(res.error, isTrue);
    });

    test('sees what was added since the last draw', () async {
      var contents = [item(FavoriteType.nhentai, '1')];
      var draw = drawFromLocalFolder('f',
          comics: (_) => contents, random: ScriptedRandom([0, 0]));
      expect((await draw()).data.id, '1');
      contents = [...contents, item(FavoriteType.nhentai, '2')];
      expect((await draw()).data.id, '2');
    });
  });

  group('the favorites of a site', () {
    late List<int> requested;
    late Map<int, Res<List<BaseComic>>> answers;

    Future<Res<List<BaseComic>>> load(int page) async {
      requested.add(page);
      return answers[page] ?? const Res([], subData: 3);
    }

    setUp(() {
      requested = [];
      answers = {
        1: Res([comic('a'), comic('b')], subData: 3),
        2: Res([comic('c')], subData: 3),
        3: Res([comic('d'), comic('e')], subData: 3),
      };
    });

    test('draw a page, then an item, and keep the pages', () async {
      var draw = drawFromNetworkFavorites('nhentai', load,
          // page 3, item 1; page 3 again, the item not drawn before; page 1.
          random: ScriptedRandom([2, 1, 2, 0, 0, 0]));
      var first = (await draw()).data;
      expect(first.key, 'nhentai/e');
      expect(requested, [1, 3]);
      expect((await draw()).data.id, 'd');
      expect((await draw()).data.id, 'a');
      // Every page was loaded once.
      expect(requested, [1, 3]);
    });

    test('without a page count, only the first page is drawn from', () async {
      answers[1] = Res([comic('a'), comic('b')]);
      var draw = drawFromNetworkFavorites('nhentai', load,
          random: ScriptedRandom([0, 1]));
      expect((await draw()).data.id, 'b');
      expect(requested, [1]);
    });

    test('an empty page falls back to the first', () async {
      answers[2] = const Res([], subData: 3);
      var draw = drawFromNetworkFavorites('nhentai', load,
          random: ScriptedRandom([1, 0]));
      expect((await draw()).data.id, 'a');
    });

    test('errors and empty favorites are told', () async {
      answers[1] = const Res(null, errorMessage: 'login');
      var res = await drawFromNetworkFavorites('nhentai', load)();
      expect(res.errorMessage, 'login');

      answers[1] = const Res([], subData: 1);
      res = await drawFromNetworkFavorites('nhentai', load)();
      expect(res.error, isTrue);
    });

    test('the pick opens the source the favorites belong to', () {
      expect(sourceKeyOfFavorites(nhentai.favoriteData!), 'nhentai');
    });
  });

  testWidgets('another one replaces the page in place', (tester) async {
    var shown = ComicSource.named(
      name: 'shown',
      key: 'shown',
      filePath: 'built-in',
      comicPageBuilder: (context, id, cover) =>
          Scaffold(body: Text('page $id')),
    );
    ComicSource.sources.add(shown);
    var ids = ['b', 'c'];
    Future<Res<RandomPick>> draw() async =>
        Res(RandomPick('shown', ids.removeAt(0), null));
    await tester.pumpWidget(MaterialApp(
      home: RandomFavoritePage(
          first: const RandomPick('shown', 'a', null), draw: draw),
    ));
    expect(find.text('page a'), findsOneWidget);
    await tester.tap(find.text('换一个'));
    await tester.pumpAndSettle();
    expect(find.text('page a'), findsNothing);
    expect(find.text('page b'), findsOneWidget);
    await tester.tap(find.text('换一个'));
    await tester.pumpAndSettle();
    expect(find.text('page c'), findsOneWidget);
  });
}
