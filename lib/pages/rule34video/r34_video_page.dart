import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/rule34video/download.dart';
import 'package:pica_comic/network/rule34video/models.dart';
import 'package:pica_comic/network/rule34video/rule34video_network.dart';
import 'package:pica_comic/pages/category_comics_page.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/rule34video/video_player_page.dart';
import 'package:pica_comic/tools/translations.dart';

/// Records in [history] how far [video] was watched: from where to go on, or
/// from the start once it was watched to the end.
void saveR34Progress(History history, Duration position, Duration duration) {
  var seconds = position.inSeconds;
  var total = duration.inSeconds;
  if (total > 0 && seconds >= total - 5) seconds = 0;
  history.ep = seconds > 0 ? 1 : 0;
  history.page = seconds;
  history.maxPage = total > 0 ? total : null;
  HistoryManager().saveReadHistory(history);
}

/// Plays [video]: the downloaded file if there is one, otherwise from the
/// site, from where it was left unless [fromStart].
Future<void> playR34VideoData(R34Video video,
    {History? history, bool fromStart = false}) async {
  history = await History.createIfNull(
      history ?? await HistoryManager().find(video.id), video);
  var downloaded = await downloadedR34File(video.number);
  var videos = [
    if (downloaded != null) PlayableVideo.file('已下载'.tl, downloaded),
    for (var source in video.sources)
      PlayableVideo.network(source.label, source.url),
  ];
  var h = history;
  App.globalTo(() => VideoPlayerPage(
        title: video.title,
        videos: videos,
        // The downloaded file needs no network.
        initialIndex: downloaded != null ? 0 : null,
        startAt: fromStart ? Duration.zero : Duration(seconds: h.page),
        timeline: video.timeline,
        onProgress: (position, duration) =>
            saveR34Progress(h, position, duration),
      ));
}

/// Loads the video [id] and plays it; used by the play button of a tile.
Future<void> playR34Video(String id) async {
  var cancelled = false;
  var dialog =
      showLoadingDialog(App.globalContext!, onCancel: () => cancelled = true);
  var res = await Rule34VideoNetwork().getVideo(id);
  if (cancelled) return;
  dialog.close();
  if (res.error) {
    showToast(message: res.errorMessage ?? 'Error');
    return;
  }
  await playR34VideoData(res.data);
}

/// The file of the downloaded video [number], if it is downloaded.
Future<String?> downloadedR34File(String number) async {
  var manager = DownloadManager();
  var id = r34DownloadId(number);
  if (!manager.isExists(id)) return null;
  var path = '${manager.path}/${manager.getDirectory(id)}/$r34VideoFileName';
  return File(path).existsSync() ? path : null;
}

/// Asks which quality to download and adds the download.
void downloadR34Video(BuildContext context, R34Video video) {
  var id = r34DownloadId(video.number);
  if (DownloadManager().isExists(id)) {
    showToast(message: '已下载'.tl);
    return;
  }
  if (DownloadManager().downloading.any((item) => item.id == id)) {
    showToast(message: '下载中'.tl);
    return;
  }
  if (video.sources.isEmpty) {
    showToast(message: '没有可以下载的视频'.tl);
    return;
  }
  showDialog<void>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('选择清晰度'.tl),
      children: [
        for (var source in video.sources.reversed)
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(context).pop();
              DownloadManager().addR34VideoDownload(video, source.label);
              showToast(message: '已加入下载队列'.tl);
            },
            child: Text(source.label),
          ),
      ],
    ),
  );
}

/// A video's page: its picture, who made it, its categories and tags, and
/// buttons to play, download and keep it.
class R34VideoPage extends BaseComicPage<R34Video> {
  const R34VideoPage(this.id, {super.key, String? cover}) : listCover = cover;

  /// `4742602/the-witch-of-the-woods`.
  @override
  final String id;

  /// The picture the list showed, until the page has loaded.
  final String? listCover;

  @override
  String? get cover => data?.poster ?? listCover;

  @override
  String? get title => data?.title;

  @override
  String? get subTitle => data?.subTitle;

  @override
  String get tag => 'rule34video $id';

  @override
  int? get pages => null;

  @override
  String get source => 'rule34video';

  @override
  String get sourceKey => rule34videoKey;

  @override
  String? get url => '${Rule34VideoNetwork.baseUrl}/video/$id/';

  @override
  String get downloadedId => r34DownloadId(id.split('/').first);

  @override
  Map<String, String> get headers => {'User-Agent': webUA};

  @override
  String get readLabel => '播放'.tl;

  @override
  String get continueLabel => '继续播放'.tl;

  @override
  String get restartLabel => '从头播放'.tl;

  @override
  Future<Res<R34Video>> loadData() => Rule34VideoNetwork().getVideo(id);

  @override
  Future<bool> loadFavorite(R34Video data) async =>
      (await LocalFavoritesManager().find(data.id, toLocalFavoriteItem().type))
          .isNotEmpty;

  @override
  FavoriteItem toLocalFavoriteItem() => FavoriteItem.custom(data!.toBrief());

  static const _artists = '作者';
  static const _uploader = '上传者';
  static const _categories = '分类';
  static const _tags = '标签';
  static const _info = '信息';

  @override
  Map<String, List<String>>? get tags {
    var video = data!;
    return {
      if (video.artists.isNotEmpty)
        _artists.tl: video.artists.map((a) => a.name).toList(),
      if (video.uploader != null) _uploader.tl: [video.uploader!.name],
      if (video.categories.isNotEmpty)
        _categories.tl: video.categories.map((c) => c.name).toList(),
      if (video.tags.isNotEmpty)
        _tags.tl: video.tags.map((t) => t.name).toList(),
      _info.tl: [video.duration, video.views, video.added]
          .where((s) => s.isNotEmpty)
          .toList(),
    };
  }

  @override
  void tapOnTag(String tag, String key) {
    var video = data!;
    List<R34Link> links;
    if (key == _artists.tl) {
      links = video.artists;
    } else if (key == _uploader.tl) {
      links = [if (video.uploader != null) video.uploader!];
    } else if (key == _categories.tl) {
      links = video.categories;
    } else if (key == _tags.tl) {
      links = video.tags;
    } else {
      return;
    }
    var link = links.where((l) => l.name == tag).firstOrNull;
    if (link == null) return;
    context.to(() => CategoryComicsPage(
          category: link.name,
          categoryKey: rule34videoKey,
          param: link.path,
        ));
  }

  @override
  // The page passes no history for "from the start".
  void read(History? history) =>
      playR34VideoData(data!, history: history, fromStart: history == null);

  @override
  void download() => downloadR34Video(context, data!);

  @override
  void openFavoritePanel() {
    favoriteComic(FavoriteComicWidget(
      havePlatformFavorite: false,
      needLoadFolderData: false,
      localFavoriteItem: toLocalFavoriteItem(),
      setFavorite: (b) {
        if (favorite != b) {
          favorite = b;
          update();
        }
      },
      selectFolderCallback: (folder, page) {
        LocalFavoritesManager().addComic(folder, toLocalFavoriteItem());
        return const Res(true);
      },
    ));
  }

  @override
  Card? get uploaderInfo => null;

  @override
  EpsData? get eps => null;

  @override
  String? get introduction => null;

  @override
  ThumbnailsData? get thumbnailsCreator => null;

  @override
  Widget? recommendationBuilder(R34Video data) => null;
}
