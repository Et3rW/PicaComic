import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/rule34video.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/rule34video/download.dart';
import 'package:pica_comic/network/rule34video/models.dart';
import 'package:pica_comic/network/rule34video/parser.dart';
import 'package:pica_comic/network/rule34video/rule34video_network.dart';
import 'package:pica_comic/pages/rule34video/r34_video_page.dart';
import 'package:pica_comic/tools/translations.dart';

import 'support/fake_http.dart';

// rule34video pages, cut down to what the app reads. The site runs on
// Kernel Video Sharing: lists are blocks of cards, a video page hands its
// player the address of every quality.
String card(int id, String slug, String title,
        {String time = '8:28', bool hd = true}) =>
    '''
<div class="item thumb video_1" data-video-card-id="$id">
  <a class="th js-open-popup" href="https://rule34video.com/video/$id/$slug/" title="$title">
    <div class="img wrap_image">
      <img class="thumb" src="https://rule34video.com/contents/videos_screenshots/$id/336x189/1.jpg" alt="$title"/>
      ${hd ? '<div class="quality"><svg></svg></div>' : ''}
      <div class="time">$time</div>
    </div>
    <div class="thumb_title">$title</div>
    <div class="thumb_info video-card-meta">
      <div class="added video-card-meta__item" title="Submitted: 1 hour ago"><svg></svg> 1 hour ago </div>
      <div class="rating video-card-meta__item"><svg></svg> 100% (33) </div>
      <div class="views video-card-meta__item" title="Views: 861"><svg></svg> 861 </div>
    </div>
  </a>
</div>''';

String listPage(List<String> cards, {int last = 14983}) => '''
<html><body>
<div class="item thumb" data-video-card-id="1"><a class="th" href="https://rule34video.com/video/1/aside/">Aside</a></div>
<div id="custom_list_videos_latest_videos_list">
  <div id="custom_list_videos_latest_videos_list_items">${cards.join()}</div>
  <div class="pagination" id="custom_list_videos_latest_videos_list_pagination">
    <div class="item active"><a href="" data-parameters="sort_by:post_date;from:01">01</a></div>
    <div class="item"><a href="/latest-updates/2/" data-parameters="sort_by:post_date;from:02">02</a></div>
    <div class="item"><a href="/latest-updates/$last/" data-parameters="sort_by:post_date;from:$last">Last</a></div>
  </div>
</div>
</body></html>''';

const videoPage = '''
<html><body>
<h1 class="title_video">The Witch of the Woods Episode Two</h1>
<div class="info">
  <span class="item_info"><svg></svg><span>22 seconds ago</span></span>
  <span class="item_info"><svg></svg><span>2</span></span>
  <span class="item_info"><svg></svg><span>8:54</span></span>
</div>
<div class="row">
  <div class="label">Artist</div>
  <span class="tag_vote_chip" data-item-type="model" data-item-id="43263">
    <a class="item btn_link video_meta_pill" href="https://rule34video.com/models/fideos/"><span class="name">Fideos</span></a>
  </span>
  <div class="label">Categories</div>
  <span class="tag_vote_chip" data-item-type="category" data-item-id="199">
    <a class="item btn_link video_meta_pill" href="https://rule34video.com/categories/3d/"><div class="wrap_image"><img alt="3D"/></div><span>3D</span></a>
  </span>
  <div class="label">Uploaded by</div>
  <a class="item btn_link video_meta_pill" href="https://rule34video.com/members/4035802/"><div class="wrap_image"><img alt="Rhemy"/></div> Rhemy <div class="verified-status"></div></a>
</div>
<div class="row vp-tags">
  <span class="tag_vote_chip" data-item-type="tag" data-item-id="29"><a class="tag_item" href="https://rule34video.com/tags/elf/">elf</a></span>
  <span class="tag_vote_chip" data-item-type="tag" data-item-id="30"><a class="tag_item" href="https://rule34video.com/tags/forest/">forest</a></span>
</div>
<script>
var flashvars = {
  video_id: '4742602',
  license_code: '\$611881720187049',
  rnd: '1795370785',
  video_url: 'https://rule34video.com/get_file/51/aa/4742000/4742602/4742602_360.mp4/?v-acctoken=A',
  postfix: '_360.mp4',
  video_url_text: '360p',
  video_alt_url: 'https://rule34video.com/get_file/51/bb/4742000/4742602/4742602_480p.mp4/?v-acctoken=B',
  video_alt_url_text: '480p',
  video_alt_url2: 'https://rule34video.com/get_file/51/cc/4742000/4742602/4742602_2160p.mp4/?v-acctoken=C',
  video_alt_url2_text: '4k',
  video_alt_url2_hd: '1',
  video_alt_url3: 'https://rule34video.com/get_file/51/dd/4742000/4742602/4742602_1080p.mp4/?v-acctoken=D',
  video_alt_url3_text: '1080p',
  timeline_screens_url: 'https://rule34video.com/contents/videos_screenshots/4742000/4742602/timelines/360p/196x109/{time}.jpg',
  timeline_screens_interval: '50',
  timeline_screens_count: '11',
  preview_url: 'https://rule34video.com/contents/videos_screenshots/4742000/4742602/preview.jpg',
  video_title: 'The Witch of the Woods Episode Two'
};
</script>
</body></html>''';

void main() {
  final http = useFakeHttp();

  group('lists', () {
    test('every card of the list, and how many pages there are', () {
      var (videos, pages) = R34Parser.videoList(listPage([
        card(4742494, 'visiting-nihilux', 'Visiting Nihilux'),
        card(4742254, 'a-little-bedtime-fun', 'A Little Bedtime Fun',
            time: '1:02:11', hd: false),
      ]));
      // The card outside the list is not one of its videos.
      expect(videos.map((v) => v.id),
          ['4742494/visiting-nihilux', '4742254/a-little-bedtime-fun']);
      var first = videos.first;
      expect(first.title, 'Visiting Nihilux');
      expect(first.cover,
          'https://rule34video.com/contents/videos_screenshots/4742494/336x189/1.jpg');
      expect(first.duration, '8:28');
      expect(first.subTitle, '8:28');
      expect(first.info, '1 hour ago · 100% (33)');
      expect(first.hd, isTrue);
      expect(first.sourceKey, rule34videoKey);
      expect(videos.last.duration, '1:02:11');
      expect(videos.last.hd, isFalse);
      expect(pages, 14983);
    });

    test('a list without pagination has one page', () {
      var (videos, pages) = R34Parser.videoList('<div id="x_items"></div>');
      expect(videos, isEmpty);
      expect(pages, 1);
    });

    test('addresses: the page goes in the path, the order in the query', () {
      expect(Rule34VideoNetwork.listUrl('/latest-updates/', 1, R34Sort.latest),
          'https://rule34video.com/latest-updates/?sort_by=post_date');
      expect(Rule34VideoNetwork.listUrl('categories/3d', 3, R34Sort.viewedWeek),
          'https://rule34video.com/categories/3d/3/?sort_by=video_viewed_week');
    });

    test('a search puts dashes between words', () async {
      http.text('rule34video.com/search/', listPage([card(5, 'x', 'X')]));
      var res = await Rule34VideoNetwork()
          .search(' big  boobs ', 2, R34Sort.topRated);
      expect(res.error, isFalse);
      expect(http.urls.last,
          'https://rule34video.com/search/big-boobs/2/?sort_by=rating');
      expect(res.data.single.id, '5/x');
      expect(res.subData, 14983);
    });

    test('the category list skips the top categories at the side', () {
      var (categories, pages) = R34Parser.categoryList('''
<div class="aside_wrap"><a href="https://rule34video.com/categories/doraemon/" class="item"><div class="name">doraemon</div></a></div>
<div id="list_categories_categories_list_items">
  <div class="thumb item"><a class="th" href="https://rule34video.com/categories/3d/"><div class="wrap_image"><img src="https://rule34video.com/contents/categories/199/s1_199.jpg" alt="3D"/></div><div class="thumb_title">3D</div></a></div>
  <div class="thumb item"><a class="th" href="https://rule34video.com/categories/genshin-impact/"><div class="wrap_image"><img src="g.jpg" alt="Genshin Impact"/></div><div class="thumb_title">Genshin Impact</div></a></div>
</div>
<div class="pagination"><a href="/categories/9/" data-parameters="sort_by:total_videos;from:09">9</a></div>''');
      expect(categories.map((c) => (c.name, c.path)), [
        ('3D', '/categories/3d/'),
        ('Genshin Impact', '/categories/genshin-impact/'),
      ]);
      expect(categories.first.image,
          'https://rule34video.com/contents/categories/199/s1_199.jpg');
      expect(pages, 9);
    });
  });

  group('a video page', () {
    test('gives every quality, lowest first, 4k last', () {
      var video = R34Parser.video(videoPage, '4742602/the-witch');
      expect(
          video.sources.map((s) => s.label), ['360p', '480p', '1080p', '4k']);
      expect(video.sources.last.url, contains('4742602_2160p.mp4'));
      expect(video.title, 'The Witch of the Woods Episode Two');
      expect(video.poster, endsWith('/4742602/preview.jpg'));
      expect(video.added, '22 seconds ago');
      expect(video.views, '2');
      expect(video.duration, '8:54');
      expect(video.artists, [const R34Link('Fideos', '/models/fideos/')]);
      expect(video.uploader, const R34Link('Rhemy', '/members/4035802/'));
      expect(video.categories, [const R34Link('3D', '/categories/3d/')]);
      expect(video.tags.map((t) => t.path), ['/tags/elf/', '/tags/forest/']);
      expect(video.subTitle, 'Fideos');
      expect(video.number, '4742602');
      expect(video.historyType.value, rule34videoKey.hashCode);
    });

    test('the seeking pictures follow the position', () {
      var timeline = R34Parser.video(videoPage, 'x/y').timeline!;
      expect(timeline.at(Duration.zero), endsWith('/196x109/1.jpg'));
      expect(timeline.at(const Duration(seconds: 120)),
          endsWith('/196x109/3.jpg'));
      // Past the last picture, the last one.
      expect(
          timeline.at(const Duration(hours: 1)), endsWith('/196x109/11.jpg'));
    });

    test('a page without a player is a video that cannot be played', () async {
      expect(() => R34Parser.video('<h1 class="title_video">Gone</h1>', 'x/y'),
          throwsFormatException);
      http.text('rule34video.com/video/9/gone/', '<h1>Gone</h1>');
      var res = await Rule34VideoNetwork().getVideo('9/gone');
      expect(res.error, isTrue);
      expect(res.errorMessage, contains('cannot be played'));
    });

    test('is asked for without a cache: its addresses expire', () async {
      http.text('rule34video.com/video/4742602/the-witch/', videoPage);
      await Rule34VideoNetwork().getVideo('4742602/the-witch');
      var before = http.requests.length;
      await Rule34VideoNetwork().getVideo('4742602/the-witch');
      expect(http.requests.length, before + 1);
    });

    test('what a download keeps comes back without the addresses', () {
      var video = R34Parser.video(videoPage, '4742602/the-witch');
      var again = R34Video.fromJson(video.toJson());
      expect(again.id, video.id);
      expect(again.title, video.title);
      expect(again.artists, video.artists);
      expect(again.uploader, video.uploader);
      expect(again.tags, video.tags);
      expect(again.sources, isEmpty);
      expect(again.toBrief().id, video.id);
    });
  });

  group('qualities', () {
    const sources = [
      R34VideoSource('360p', 'a'),
      R34VideoSource('480p', 'b'),
      R34VideoSource('1080p', 'c'),
      R34VideoSource('4k', 'd'),
    ];

    test('labels are ordered by their lines', () {
      expect(const R34VideoSource('4k', '').height, 2160);
      expect(const R34VideoSource('2K', '').height, 1440);
      expect(const R34VideoSource('720p', '').height, 720);
      expect(const R34VideoSource('HD', '').height, 0);
    });

    test('a download takes the best up to 1080p unless told otherwise', () {
      expect(defaultR34Quality(sources), '1080p');
      expect(defaultR34Quality(const [R34VideoSource('4k', 'd')]), '4k');
    });

    test('a quality gone from the page falls back to the closest lower one',
        () {
      expect(pickR34Source(sources, '480p')!.url, 'b');
      expect(pickR34Source(sources, '720p')!.url, 'b');
      expect(pickR34Source(sources, '240p')!.url, 'a');
      expect(pickR34Source(const [], '720p'), isNull);
    });

    test('download ids use the number only', () {
      expect(r34DownloadId('4742602'), 'rule34video-4742602');
    });
  });

  group('the source', () {
    test('lists open in the order their name asks for', () async {
      http.text('rule34video.com/most-popular/', listPage([card(7, 'p', 'P')]));
      var data = rule34video.categoryComicsData!;
      var week =
          data.options.firstWhere((o) => o.showWhen?.contains('本周热门') ?? false);
      expect(week.options.keys.first, R34Sort.viewedWeek.value);
      var other = data.options.firstWhere((o) => o.showWhen == null);
      expect(other.options.keys.first, R34Sort.latest.value);
      expect(other.notShowWhen, containsAll(['本周热门', '最高评分']));

      var res = await data.load('本周热门', Rule34VideoNetwork.popularPath,
          [R34Sort.viewedWeek.value], 2);
      expect(res.error, isFalse);
      expect(http.urls.last,
          'https://rule34video.com/most-popular/2/?sort_by=video_viewed_week');
      expect(res.data.single.id, '7/p');
    });

    test('is a built-in source, on for new installs and after an update', () {
      expect(builtInSources.last, rule34videoKey);
      var settings = List.of(appdata.settings);
      settings[82] = '111111';
      settings[77] = 'picacg,nhentai';
      settings[67] = 'picacg';
      Appdata.addNewBuiltInSources(settings);
      expect(settings[82], '1111111');
      expect(settings[77], 'picacg,nhentai,rule34video');
      expect(settings[67], 'picacg,rule34video');
      // Nothing changes the second time.
      Appdata.addNewBuiltInSources(settings);
      expect(settings[77], 'picacg,nhentai,rule34video');

      var saved = appdata.settings[82];
      addTearDown(() => appdata.settings[82] = saved);
      // Settings synced from an older version know six sources.
      appdata.settings[82] = '111110';
      expect(appdata.appSettings.isComicSourceEnabled(rule34videoKey), isTrue);
      expect(appdata.appSettings.isComicSourceEnabled('nhentai'), isFalse);
      appdata.appSettings.setComicSourceEnabled(rule34videoKey, false);
      expect(appdata.settings[82], '1111100');
    });
  });

  test('a downloading video keeps its state across a restart', () {
    var video = R34Parser.video(videoPage, '4742602/the-witch');
    var item = R34VideoDownloadingItem(video, '1080p', null, null, null);
    expect(item.id, 'rule34video-4742602');
    expect(item.countsBytes, isTrue);
    expect(item.haveEps, isFalse);
    var map = item.toMap();
    expect(map['type'], 8);
    var again = R34VideoDownloadingItem.fromMap(
        Map<String, dynamic>.from(map), () {}, () {}, () async {});
    expect(again.video.id, video.id);
    expect(again.quality, '1080p');
    expect(again.title, video.title);
    expect(again.cover, video.poster);
  });

  // The detail page once failed to build: it wrote into the const map of
  // headers the video page gives, so there was no play or download button.
  testWidgets('the video page shows its play and download buttons',
      (tester) async {
    final previous = [for (var i in [22, 72, 73]) appdata.settings[i]];
    addTearDown(() {
      for (var (n, i) in [22, 72, 73].indexed) {
        appdata.settings[i] = previous[n];
      }
    });
    // A phone: the play and download buttons are under the cover.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AppTranslation.translations = {};
    appdata.settings[72] = '0';
    appdata.settings[73] = '0';
    http.text('rule34video.com/video/4742602/the-witch/', videoPage);
    await tester.runAsync(() async {
      // The page looks the video up in history, local favorites and
      // downloads.
      final data = Directory.systemTemp.createTempSync('pica_r34_page');
      addTearDown(() => data.deleteSync(recursive: true));
      App.dataPath = data.path;
      appdata.settings[22] = '${data.path}/download';
      await HistoryManager().init();
      await LocalFavoritesManager().init();
      await DownloadManager().init();
      await tester.pumpWidget(const MaterialApp(
          home: R34VideoPage('4742602/the-witch',
              cover: 'https://rule34video.com/cover.jpg')));
      for (var i = 0; i < 20 && find.text('播放').evaluate().isEmpty; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(tester.takeException(), isNull);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
  });

  for (final detailed in [true, false]) {
    // A list of videos is drawn with these tiles. A video has no tags, and
    // its list of them is a const one, which the tile must not change.
    testWidgets(
        'a video tile is drawn in ${detailed ? 'detailed' : 'brief'} mode',
        (tester) async {
      // 44: the tile layout; 72, 73: marks for favorites and history, which
      // need the databases.
      final previous = [for (var i in [44, 72, 73]) appdata.settings[i]];
      addTearDown(() {
        for (var (n, i) in [44, 72, 73].indexed) {
          appdata.settings[i] = previous[n];
        }
      });
      appdata.settings[44] = detailed ? '0,1.0' : '1,1.0';
      appdata.settings[72] = '0';
      appdata.settings[73] = '0';
      final videos = R34Parser.videoList(listPage([
        card(4221840, 'ellie-in-the-rain', 'Ellie in the rain'),
      ])).$1;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
        child: SizedBox(
            width: 400, height: 220, child: _TestVideoTile(videos.single)),
      ))));
      expect(tester.takeException(), isNull);
      expect(find.text('Ellie in the rain'), findsWidgets);
    });
  }
}

class _TestVideoTile extends R34VideoTile {
  const _TestVideoTile(super.comic);

  @override
  Widget get image => const ColoredBox(color: Colors.grey);
}
