import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/network/base_comic.dart';

/// Key of the rule34video source. Lists, favorites and history refer to it.
const rule34videoKey = 'rule34video';

/// A video in a list. It is a [CustomComic] of the rule34video source, so the
/// usual list tiles, local favorites and history work with it.
class R34VideoBrief extends CustomComic {
  const R34VideoBrief({
    required String title,
    required String cover,
    required String id,
    required this.duration,
    required this.info,
    this.hd = false,
  }) : super(title, duration, cover, id, const [], info, rule34videoKey);

  /// As shown by the site, `8:28`.
  final String duration;

  /// When it was added and how it is rated, as the site shows them.
  final String info;

  final bool hd;
}

/// A link to a list on the site: a category, tag, artist or uploader.
class R34Link {
  const R34Link(this.name, this.path);

  final String name;

  /// Path of the list on the site, `/categories/3d/`.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is R34Link && other.name == name && other.path == path;

  @override
  int get hashCode => Object.hash(name, path);

  @override
  String toString() => '$name ($path)';
}

/// One quality of a video.
class R34VideoSource {
  const R34VideoSource(this.label, this.url);

  /// `720p`.
  final String label;

  /// Playable address. It carries a token that expires: take it from a fresh
  /// [R34Video] rather than storing it.
  final String url;

  /// Lines of the picture, for ordering; 0 when the label has no number.
  /// `4k` is 2160.
  int get height {
    var match = RegExp(r'(\d+)\s*([kKpP]?)').firstMatch(label);
    if (match == null) return 0;
    var number = int.parse(match[1]!);
    if (match[2]!.toLowerCase() != 'k') return number;
    return number == 2 ? 1440 : number * 540;
  }

  Map<String, dynamic> toJson() => {'label': label, 'url': url};

  R34VideoSource.fromJson(Map<String, dynamic> json)
      : label = json['label'] as String,
        url = json['url'] as String;
}

/// A video page.
class R34Video with HistoryMixin {
  R34Video({
    required this.id,
    required this.title,
    required this.poster,
    required this.sources,
    this.duration = '',
    this.views = '',
    this.added = '',
    this.uploader,
    this.artists = const [],
    this.categories = const [],
    this.tags = const [],
    this.timeline,
  });

  /// `4742602/the-witch-of-the-woods-episode-two`: the site needs both parts
  /// in the address.
  final String id;

  @override
  final String title;

  final String poster;

  /// Lowest quality first.
  final List<R34VideoSource> sources;

  final String duration;

  final String views;

  final String added;

  final R34Link? uploader;

  final List<R34Link> artists;

  final List<R34Link> categories;

  final List<R34Link> tags;

  /// Small pictures along the video, to show while seeking.
  final R34Timeline? timeline;

  /// The number in [id].
  String get number => id.split('/').first;

  @override
  String get subTitle => artists.isNotEmpty
      ? artists.map((a) => a.name).join(', ')
      : uploader?.name ?? '';

  @override
  String get cover => poster;

  @override
  String get target => id;

  @override
  HistoryType get historyType => HistoryType(rule34videoKey.hashCode);

  R34VideoBrief toBrief() => R34VideoBrief(
        title: title,
        cover: poster,
        id: id,
        duration: duration,
        info: added,
      );

  /// What a download keeps: everything but the playable addresses.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'poster': poster,
        'duration': duration,
        'views': views,
        'added': added,
        'uploader': uploader == null ? null : _link(uploader!),
        'artists': artists.map(_link).toList(),
        'categories': categories.map(_link).toList(),
        'tags': tags.map(_link).toList(),
      };

  static Map<String, String> _link(R34Link link) =>
      {'name': link.name, 'path': link.path};

  static R34Link _fromLink(Object? json) {
    var map = json as Map;
    return R34Link(map['name'] as String, map['path'] as String);
  }

  factory R34Video.fromJson(Map<String, dynamic> json) => R34Video(
        id: json['id'] as String,
        title: json['title'] as String,
        poster: json['poster'] as String? ?? '',
        sources: const [],
        duration: json['duration'] as String? ?? '',
        views: json['views'] as String? ?? '',
        added: json['added'] as String? ?? '',
        uploader: json['uploader'] == null ? null : _fromLink(json['uploader']),
        artists: [for (var a in json['artists'] as List? ?? []) _fromLink(a)],
        categories: [
          for (var c in json['categories'] as List? ?? []) _fromLink(c)
        ],
        tags: [for (var t in json['tags'] as List? ?? []) _fromLink(t)],
      );
}

/// Pictures taken every [interval] seconds of a video.
class R34Timeline {
  const R34Timeline(this.urlTemplate, this.interval, this.count);

  /// Address with `{time}` for the picture's number, from 1.
  final String urlTemplate;

  final int interval;

  final int count;

  /// The picture for [position], or null past the last one.
  String? at(Duration position) {
    if (interval <= 0 || count <= 0) return null;
    var index = position.inSeconds ~/ interval + 1;
    if (index > count) index = count;
    return urlTemplate.replaceAll('{time}', '$index');
  }
}

/// A category as the site lists it.
class R34Category {
  const R34Category(this.name, this.path, this.image, this.count);

  final String name;
  final String path;
  final String image;

  /// Number of videos, as shown.
  final String count;
}

/// Orders the site's lists can be sorted in.
enum R34Sort {
  latest('post_date', '最新'),
  mostViewed('video_viewed', '最多观看'),
  topRated('rating', '最高评分'),
  longest('duration', '最长'),
  viewedToday('video_viewed_today', '今日热门'),
  viewedWeek('video_viewed_week', '本周热门'),
  viewedMonth('video_viewed_month', '本月热门');

  const R34Sort(this.value, this.label);

  /// The site's `sort_by`.
  final String value;

  final String label;

  static R34Sort fromValue(String? value) =>
      values.firstWhere((s) => s.value == value, orElse: () => latest);

  /// The orders every list has; the daily, weekly and monthly ones only
  /// exist for the most popular list.
  static const common = [latest, mostViewed, topRated, longest];
}
