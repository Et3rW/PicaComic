import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'models.dart';

/// Reading rule34video's pages. The site runs on Kernel Video Sharing: every
/// list is the same block of cards, and a video page hands its player the
/// addresses of each quality in a `flashvars` object.
class R34Parser {
  R34Parser._();

  static const baseUrl = 'https://rule34video.com';

  static final _videoPath = RegExp(r'/video/(\d+)/([^/?#]+)');

  /// The id of a video address: `4742602/the-witch-of-the-woods`.
  static String? idOf(String url) {
    var match = _videoPath.firstMatch(url);
    return match == null ? null : '${match[1]}/${match[2]}';
  }

  /// A site address as a path, `/categories/3d/`; null for other hosts.
  static String? pathOf(String? url) {
    if (url == null || url.isEmpty) return null;
    var uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.hasAuthority && !uri.host.endsWith('rule34video.com')) return null;
    var path = uri.path;
    return path.endsWith('/') ? path : '$path/';
  }

  static String _text(Element? element) =>
      element?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';

  /// The videos of a list page and how many pages the list has.
  static (List<R34VideoBrief>, int) videoList(String page) {
    var document = html.parse(page);
    // The list itself; a page may show other videos beside it.
    var container = document.querySelector('[id\$="_items"]') ?? document;
    var videos = <R34VideoBrief>[];
    var seen = <String>{};
    for (var card in container.querySelectorAll('.item.thumb')) {
      var link = card.querySelector('a.th[href]') ??
          card.querySelector('a[href*="/video/"]');
      var id = idOf(link?.attributes['href'] ?? '');
      if (id == null || !seen.add(id)) continue;
      var image = card.querySelector('img.thumb') ?? card.querySelector('img');
      var cover =
          image?.attributes['data-original'] ?? image?.attributes['src'] ?? '';
      if (cover.startsWith('data:')) {
        cover = image?.attributes['data-rd-jpg'] ?? '';
      }
      var title = _text(card.querySelector('.thumb_title'));
      if (title.isEmpty) title = link?.attributes['title']?.trim() ?? '';
      var info = [
        _text(card.querySelector('.added')),
        _text(card.querySelector('.rating')),
      ].where((s) => s.isNotEmpty).join(' · ');
      videos.add(R34VideoBrief(
        title: title,
        cover: cover,
        id: id,
        duration: _text(card.querySelector('.time')),
        info: info,
        hd: card.querySelector('.quality') != null,
      ));
    }
    return (videos, lastPage(document));
  }

  /// The highest page the pagination links to; 1 without pagination.
  static int lastPage(Document document) {
    var last = 1;
    for (var pagination in document.querySelectorAll('.pagination')) {
      for (var link in pagination.querySelectorAll('a')) {
        var numbers = [
          RegExp(r'from[^:;]*:(\d+)')
              .firstMatch(link.attributes['data-parameters'] ?? '')?[1],
          RegExp(r'/(\d+)/?$').firstMatch(link.attributes['href'] ?? '')?[1],
        ];
        for (var number in numbers) {
          var page = int.tryParse(number ?? '');
          if (page != null && page > last) last = page;
        }
      }
    }
    return last;
  }

  /// The site's categories on a page of its category list.
  static (List<R34Category>, int) categoryList(String page) {
    var document = html.parse(page);
    // The list itself; the side of the page shows the top categories too.
    var container =
        document.querySelector('#list_categories_categories_list_items');
    if (container == null) return (const <R34Category>[], 1);
    var categories = <R34Category>[];
    var seen = <String>{};
    for (var item in container.querySelectorAll('a[href*="/categories/"]')) {
      var path = pathOf(item.attributes['href']);
      if (path == null || !seen.add(path)) continue;
      var name = _text(item.querySelector('.thumb_title'));
      if (name.isEmpty) {
        name = item.querySelector('img')?.attributes['alt']?.trim() ?? '';
      }
      if (name.isEmpty) continue;
      categories.add(R34Category(
        name,
        path,
        item.querySelector('img')?.attributes['src'] ?? '',
        _text(item.querySelector('.count')),
      ));
    }
    return (categories, lastPage(document));
  }

  /// A value of the player's settings, written `name: 'value'`.
  static String? _flashvar(String page, String name) =>
      RegExp('(?:^|[\\s,{])$name:\\s*\'([^\']*)\'').firstMatch(page)?[1];

  /// A video page. Throws [FormatException] when the page has no player,
  /// which is how the site shows a removed or private video.
  static R34Video video(String page, String id) {
    var document = html.parse(page);
    var sources = <R34VideoSource>[];
    for (var key in [
      'video_url',
      'video_alt_url',
      for (var i = 2; i <= 5; i++) 'video_alt_url$i',
    ]) {
      var url = _flashvar(page, key);
      if (url == null || url.isEmpty) continue;
      var label = _flashvar(page, '${key}_text') ?? '';
      sources.add(R34VideoSource(label, url));
    }
    if (sources.isEmpty) {
      throw const FormatException('No video on this page');
    }
    sources.sort((a, b) => a.height.compareTo(b.height));

    var title = _text(document.querySelector('h1.title_video'));
    if (title.isEmpty) title = _flashvar(page, 'video_title') ?? '';

    var info = [
      for (var span in document.querySelectorAll('.item_info span'))
        _text(span),
    ];

    List<R34Link> links(String type) => [
          for (var chip
              in document.querySelectorAll('[data-item-type="$type"]'))
            if (chip.querySelector('a[href]') case var a?)
              if (pathOf(a.attributes['href']) case var path?)
                R34Link(_text(a), path),
        ];

    R34Link? uploader;
    for (var a
        in document.querySelectorAll('a.video_meta_pill[href*="/members/"]')) {
      var path = pathOf(a.attributes['href']);
      if (path == null) continue;
      uploader = R34Link(
          a.nodes.whereType<Text>().map((t) => t.text).join().trim(), path);
      break;
    }

    R34Timeline? timeline;
    var template = _flashvar(page, 'timeline_screens_url');
    if (template != null && template.contains('{time}')) {
      timeline = R34Timeline(
        template,
        int.tryParse(_flashvar(page, 'timeline_screens_interval') ?? '') ?? 0,
        int.tryParse(_flashvar(page, 'timeline_screens_count') ?? '') ?? 0,
      );
    }

    return R34Video(
      id: id,
      title: title,
      poster: _flashvar(page, 'preview_url') ?? '',
      sources: sources,
      added: info.elementAtOrNull(0) ?? '',
      views: info.elementAtOrNull(1) ?? '',
      duration: info.elementAtOrNull(2) ?? '',
      uploader: uploader,
      artists: links('model'),
      categories: links('category'),
      tags: links('tag'),
      timeline: timeline,
    );
  }
}
