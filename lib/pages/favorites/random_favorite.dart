import 'dart:math';

import 'package:collection/collection.dart';

import 'package:flutter/material.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/tools/translations.dart';

/// A comic or video drawn at random: enough to open its page.
class RandomPick {
  const RandomPick(this.sourceKey, this.id, this.cover);

  final String sourceKey;
  final String id;
  final String? cover;

  String get key => '$sourceKey/$id';
}

/// Draws a [RandomPick] each time it is called, not the one drawn just
/// before when there is a choice.
typedef RandomDraw = Future<Res<RandomPick>> Function();

/// One of [items] at random, not [avoid] unless it is the only one.
T pickAtRandom<T>(List<T> items, Random random, {bool Function(T)? avoid}) {
  var choices = avoid == null ? items : items.where((i) => !avoid(i)).toList();
  if (choices.isEmpty) choices = items;
  return choices[random.nextInt(choices.length)];
}

/// The source that opens [item], if it is turned on.
ComicSource? sourceOfFavorite(FavoriteItem item) {
  try {
    return item.type.comicSource;
  } catch (_) {
    // The source was removed or turned off.
    return null;
  }
}

/// Draws from the local folder [folder]: every source, videos included.
/// Items whose source is turned off are left out.
RandomDraw drawFromLocalFolder(String folder,
    {List<FavoriteItem> Function(String folder)? comics, Random? random}) {
  random ??= Random();
  comics ??= LocalFavoritesManager().getAllComics;
  String? last;
  return () async {
    var picks = [
      for (var item in comics!(folder))
        if (sourceOfFavorite(item) case var source?)
          RandomPick(source.key, item.target, item.coverPath),
    ];
    if (picks.isEmpty) {
      return Res.error('这个收藏夹里没有可以打开的内容'.tl);
    }
    var pick = pickAtRandom(picks, random!, avoid: (p) => p.key == last);
    last = pick.key;
    return Res(pick);
  };
}

/// Draws from the favorites of a site, in [folder] when it has folders:
/// a page at random, then an item of it. Pages are kept, so drawing again
/// rarely needs a request. When the site does not say how many pages there
/// are, only the first is drawn from.
RandomDraw drawFromNetworkFavorites(
  String sourceKey,
  Future<Res<List<BaseComic>>> Function(int page) loadPage, {
  Random? random,
}) {
  random ??= Random();
  int? pageCount;
  var pages = <int, List<BaseComic>>{};
  String? last;

  Future<Res<List<BaseComic>>> load(int page) async {
    if (pages[page] case var known?) return Res(known);
    var res = await loadPage(page);
    if (!res.error) pages[page] = res.data;
    return res;
  }

  return () async {
    if (pageCount == null) {
      var first = await load(1);
      if (first.error) return Res.fromErrorRes(first);
      var count = first.subData;
      pageCount = count is int && count > 0 ? count : 1;
    }
    var page = 1 + random!.nextInt(pageCount!);
    var res = await load(page);
    if (res.error) return Res.fromErrorRes(res);
    var comics = res.data;
    // A page past the end, or one that came back empty: the first one.
    if (comics.isEmpty) comics = pages[1] ?? const [];
    if (comics.isEmpty) return Res.error('收藏是空的'.tl);
    var comic = pickAtRandom(comics, random!, avoid: (c) => c.id == last);
    last = comic.id;
    return Res(RandomPick(sourceKey, comic.id, comic.cover));
  };
}

/// The source whose favorites [data] are.
String sourceKeyOfFavorites(FavoriteData data) =>
    ComicSource.sources
        .firstWhereOrNull((source) => identical(source.favoriteData, data))
        ?.key ??
    data.key;

/// Draws once and opens what was drawn, on a page that can draw again.
Future<void> openRandomFavorite(RandomDraw draw) async {
  var cancelled = false;
  var dialog =
      showLoadingDialog(App.globalContext!, onCancel: () => cancelled = true);
  var res = await draw();
  if (cancelled) return;
  dialog.close();
  if (res.error) {
    showToast(message: res.errorMessage ?? 'Error');
    return;
  }
  App.mainNavigatorKey?.currentContext
      ?.to(() => RandomFavoritePage(first: res.data, draw: draw));
}

/// The page of a comic drawn at random, with a button to draw another one
/// in its place.
class RandomFavoritePage extends StatefulWidget {
  const RandomFavoritePage(
      {super.key, required this.first, required this.draw});

  final RandomPick first;
  final RandomDraw draw;

  @override
  State<RandomFavoritePage> createState() => _RandomFavoritePageState();
}

class _RandomFavoritePageState extends State<RandomFavoritePage> {
  late RandomPick current = widget.first;
  bool drawing = false;

  Future<void> _again() async {
    if (drawing) return;
    setState(() => drawing = true);
    var res = await widget.draw();
    if (!mounted) return;
    setState(() {
      drawing = false;
      if (!res.error) current = res.data;
    });
    if (res.error) showToast(message: res.errorMessage ?? 'Error');
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ComicPage(
            key: ValueKey(current.key),
            sourceKey: current.sourceKey,
            id: current.id,
            cover: current.cover,
          ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: SafeArea(
            child: FloatingActionButton.extended(
              heroTag: 'random favorite',
              onPressed: drawing ? null : _again,
              icon: drawing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.shuffle),
              label: Text('换一个'.tl),
            ),
          ),
        ),
      ],
    );
  }
}

/// The button that draws at random from what is shown.
class RandomFavoriteButton extends StatelessWidget {
  const RandomFavoriteButton(this.draw, {super.key});

  /// Made on tap, so that every tap sees the current contents.
  final RandomDraw Function() draw;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '随机'.tl,
      child: IconButton(
        icon: const Icon(Icons.shuffle),
        onPressed: () => openRandomFavorite(draw()),
      ),
    );
  }
}
