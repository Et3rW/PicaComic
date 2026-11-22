import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/rule34video/models.dart';
import 'package:pica_comic/network/rule34video/rule34video_network.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/rule34video/r34_categories_page.dart';
import 'package:pica_comic/pages/rule34video/r34_video_page.dart';
import 'package:pica_comic/tools/translations.dart';

import '../comic_source.dart';

/// The site's sort orders, as category and search options, [first] first:
/// the first is the one a list opens with.
LinkedHashMap<String, String> _sortOptions([R34Sort first = R34Sort.latest]) =>
    LinkedHashMap.of({
      first.value: first.label,
      for (var sort in R34Sort.values)
        if (sort != first) sort.value: sort.label,
    });

/// Lists of the explore page that open in another order than the newest
/// first, by their name.
const _sortedLists = {
  '本周热门': R34Sort.viewedWeek,
  '最高评分': R34Sort.topRated,
};

/// Categories with the most videos, shown without loading the site's list.
const _popularCategories = {
  '3D': '/categories/3d/',
  '2D': '/categories/2d/',
  'MMD': '/categories/mmd/',
  'Hentai': '/categories/hentai/',
  'Koikatsu': '/categories/koikatsu/',
  'iwara': '/categories/iwara/',
  'Virt-A-Mate': '/categories/virt-a-mate/',
  'Blender': '/categories/blender/',
  'Source Filmmaker': '/categories/source-filmmaker/',
  'Genshin Impact': '/categories/genshin-impact/',
  'Honkai Star Rail': '/categories/honkai-star-rail/',
  'Zenless Zone Zero': '/categories/zenless-zone-zero/',
  'Wuthering Waves': '/categories/wuthering-waves/',
  'Blue Archive': '/categories/blue-archive/',
  'Overwatch': '/categories/overwatch/',
  'Final Fantasy': '/categories/final-fantasy/',
  'Resident Evil': '/categories/resident-evil/',
  'Nier Automata': '/categories/nier-automata/',
  'Pokemon': '/categories/pokemon/',
  'Dead or Alive': '/categories/dead-or-alive/',
  'Street Fighter': '/categories/street-fighter/',
  'League of Legends': '/categories/league-of-legends/',
  'Hololive': '/categories/hololive/',
  'Marvel': '/categories/marvel/',
};

Future<Res<List<BaseComic>>> _asComics(
    Future<Res<List<R34VideoBrief>>> request) async {
  var res = await request;
  if (res.error) return Res.fromErrorRes(res);
  return Res(res.data, subData: res.subData);
}

/// rule34video.com: animated videos, played in the app and downloadable.
final rule34video = ComicSource.named(
  name: 'rule34video',
  key: rule34videoKey,
  filePath: 'built-in',
  // Download ids use the number only: `rule34video-4742602`.
  matchBriefIdReg: r'^(\d+)',
  explorePages: [
    ExplorePageData.named(
      title: 'rule34video',
      type: ExplorePageType.singlePageWithMultiPart,
      loadMultiPart: () async {
        var network = Rule34VideoNetwork();
        var parts = [
          ('本周热门', Rule34VideoNetwork.popularPath, R34Sort.viewedWeek),
          ('最新', Rule34VideoNetwork.latestPath, R34Sort.latest),
          ('最高评分', Rule34VideoNetwork.topRatedPath, R34Sort.topRated),
        ];
        var results = await Future.wait([
          for (var (_, path, sort) in parts) network.getList(path, 1, sort),
        ]);
        var first =
            results.firstWhere((r) => r.error, orElse: () => results[0]);
        if (results.every((r) => r.error)) return Res.fromErrorRes(first);
        return Res([
          for (var i = 0; i < parts.length; i++)
            if (!results[i].error)
              ExplorePagePart(
                parts[i].$1.tl,
                results[i].data,
                // The name picks the order the list opens with.
                'category:${parts[i].$1}@${parts[i].$2}',
              ),
        ]);
      },
    ),
  ],
  categoryData: CategoryData(
    title: 'rule34video',
    key: rule34videoKey,
    categories: [
      const FixedCategoryPart(
          '浏览', ['全部视频'], 'category', [Rule34VideoNetwork.latestPath]),
      FixedCategoryPart(
        '热门分类',
        _popularCategories.keys.toList(),
        'category',
        _popularCategories.values.toList(),
      ),
    ],
    enableRankingPage: false,
    buttons: [
      CategoryButtonData(
        label: '所有分类',
        onTap: () => App.mainNavigatorKey?.currentContext
            ?.to(() => const R34CategoriesPage()),
      ),
    ],
  ),
  categoryComicsData: CategoryComicsData.named(
    load: (category, param, options, page) => _asComics(Rule34VideoNetwork()
        .getList(param ?? Rule34VideoNetwork.latestPath, page,
            R34Sort.fromValue(options.firstOrNull))),
    options: [
      for (var MapEntry(key: name, value: sort) in _sortedLists.entries)
        CategoryComicsOptions.named(
            options: _sortOptions(sort), showWhen: [name]),
      CategoryComicsOptions.named(
          options: _sortOptions(), notShowWhen: _sortedLists.keys.toList()),
    ],
  ),
  searchPageData: SearchPageData.named(
    searchOptions: [SearchOptions.named(options: _sortOptions(), label: '排序')],
    loadPage: (keyword, page, options) => _asComics(Rule34VideoNetwork()
        .search(keyword, page, R34Sort.fromValue(options.firstOrNull))),
  ),
  // Favorites check whether a video is still there and refresh its name.
  loadComicInfo: (id) async {
    var res = await Rule34VideoNetwork().getVideo(id);
    if (res.error) return Res.fromErrorRes(res);
    var video = res.data;
    return Res(ComicInfoData(
      video.title,
      video.subTitle,
      video.poster,
      null,
      {'Tags': video.tags.map((t) => t.name).toList()},
      null,
      null,
      null,
      0,
      null,
      rule34videoKey,
      video.id,
    ));
  },
  comicTileBuilderOverride: (context, comic, options) =>
      R34VideoTile(comic as CustomComic, addonMenuOptions: options),
  comicPageBuilder: (context, id, cover) => R34VideoPage(id, cover: cover),
);

/// A video in a list: its picture with the length on it.
class R34VideoTile extends ComicTile {
  const R34VideoTile(this.comic, {super.key, this.addonMenuOptions});

  final CustomComic comic;

  @override
  final List<ComicTileMenuOption>? addonMenuOptions;

  @override
  String get title => comic.title;

  @override
  String get subTitle => comic.subTitle;

  @override
  String get description => comic.description;

  @override
  List<String>? get tags => comic.tags;

  @override
  String? get comicID => comic.id;

  @override
  FavoriteItem? get favoriteItem => FavoriteItem.custom(comic);

  @override
  Widget get image => AnimatedImage(
        image: CachedImageProvider(
          comic.cover,
          headers: const {'User-Agent': webUA},
        ),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        filterQuality: FilterQuality.medium,
      );

  @override
  void onTap_() {
    App.mainNavigatorKey!.currentContext!.to(() => ComicPage(
          sourceKey: rule34videoKey,
          id: comic.id,
          cover: comic.cover,
        ));
  }

  @override
  ActionFunc? get read => () => playR34Video(comic.id);
}
