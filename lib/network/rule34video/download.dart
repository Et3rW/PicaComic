import 'dart:async';
import 'dart:io';

import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/file_downloader.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/tools/io_tools.dart';

import 'models.dart';
import 'rule34video_network.dart';

/// Name of the video file in a download's folder.
const r34VideoFileName = 'video.mp4';

/// Download id of the video [number], as the download list knows it.
String r34DownloadId(String number) => '$rule34videoKey-$number';

/// The quality to download among [sources]: the one labelled [label], or the
/// closest lower one, or the lowest.
R34VideoSource? pickR34Source(List<R34VideoSource> sources, String label) {
  if (sources.isEmpty) return null;
  for (var source in sources) {
    if (source.label == label) return source;
  }
  var height = R34VideoSource(label, '').height;
  R34VideoSource? best;
  for (var source in sources) {
    if (source.height <= height) best = source;
  }
  return best ?? sources.first;
}

/// The quality downloaded when none is picked: the best up to 1080p. 4k
/// files are several times larger for little gain on a phone.
String defaultR34Quality(List<R34VideoSource> sources) {
  String? best;
  for (var source in sources) {
    if (source.height <= 1080) best = source.label;
  }
  return best ?? (sources.isEmpty ? '' : sources.first.label);
}

/// A downloaded video.
class R34DownloadedVideo extends DownloadedItem {
  R34DownloadedVideo(this.video, this.quality, this.size);

  final R34Video video;

  /// The quality downloaded, `720p`.
  final String quality;

  double? size;

  @override
  DownloadType get type => DownloadType.rule34video;

  @override
  String get name => video.title;

  @override
  List<String> get eps => [quality];

  @override
  List<int> get downloadedEps => const [0];

  @override
  String get id => r34DownloadId(video.number);

  @override
  String get subTitle => video.subTitle;

  @override
  double? get comicSize => size;

  @override
  set comicSize(double? value) => size = value;

  @override
  List<String> get tags => [
        for (var link in [...video.artists, ...video.categories, ...video.tags])
          link.name,
      ];

  /// Where the video is, once [directory] is known.
  String filePath(String downloadPath) =>
      '$downloadPath/$directory/$r34VideoFileName';

  @override
  Map<String, dynamic> toJson() =>
      {'video': video.toJson(), 'quality': quality, 'size': size};

  R34DownloadedVideo.fromJson(Map<String, dynamic> json)
      : video = R34Video.fromJson(Map<String, dynamic>.from(json['video'])),
        quality = json['quality'] as String? ?? '',
        size = (json['size'] as num?)?.toDouble();
}

/// Downloads one video file, in parts and resumably. The address is taken
/// from the video page each time the download starts, since the site's
/// addresses expire.
class R34VideoDownloadingItem extends DownloadingItem {
  R34VideoDownloadingItem(
    this.video,
    this.quality,
    DownloadProgressCallback? onFinish,
    DownloadProgressCallback? onError,
    DownloadProgressCallbackAsync? updateInfo,
  ) : super(onFinish, onError, updateInfo, r34DownloadId(video.number),
            type: DownloadType.rule34video);

  final R34Video video;

  /// The quality asked for, `720p`.
  final String quality;

  int? _currentBytes;
  int? _totalBytes;
  int _speed = 0;
  FileDownloader? _downloader;

  /// Counts up on every start and stop, so a stopped run ends quietly.
  int _run = 0;

  /// Replaced in tests.
  static Future<String?> Function() proxy = getProxy;

  @override
  Map<String, String> get headers => const {'User-Agent': webUA};

  @override
  String get cover => video.poster;

  @override
  String get title => video.title;

  @override
  bool get countsBytes => true;

  @override
  int get totalPages => _totalBytes ?? 1;

  @override
  int get downloadedPages => _currentBytes ?? 0;

  @override
  int get currentSpeed => _speed;

  @override
  Future<Map<int, List<String>>> getLinks() async => {
        0: [quality]
      };

  @override
  Stream<DownloadProgress> downloadImage(String link) =>
      throw UnsupportedError('A video is downloaded as one file');

  @override
  void start() async {
    var run = ++_run;
    try {
      await onStart();
      if (run != _run) return;
      try {
        await downloadCover();
      } catch (e) {
        // A video without its picture is still worth having.
        Log.warning('Download', 'cover of ${video.id}: $e');
      }
      var fresh = await Rule34VideoNetwork().getVideo(video.id);
      if (run != _run) return;
      if (fresh.error) throw Exception(fresh.errorMessage);
      var source = pickR34Source(fresh.data.sources, quality);
      if (source == null) throw Exception('No video file');
      var downloader =
          FileDownloader(source.url, '$path/$r34VideoFileName', await proxy());
      _downloader = downloader;
      await for (var status in downloader.start()) {
        if (run != _run) return;
        _currentBytes = status.downloadedBytes;
        _totalBytes = status.totalBytes;
        _speed = status.bytesPerSecond;
        await updateInfo?.call();
        if (status.isFinished ||
            (status.totalBytes > 0 &&
                status.downloadedBytes >= status.totalBytes)) {
          break;
        }
      }
      if (run != _run) return;
      _speed = 0;
      var file = File('$path/$r34VideoFileName');
      if (!file.existsSync() || file.lengthSync() == 0) {
        throw Exception('The site sent no video');
      }
      if (DownloadManager().downloading.firstOrNull != this) return;
      onFinish?.call();
    } catch (e, s) {
      if (run != _run) return;
      Log.error('Download', 'video ${video.id}: $e\n$s');
      _speed = 0;
      onError?.call();
    }
  }

  @override
  void pause() {
    _run++;
    _speed = 0;
    // The parts already written stay, and the next start goes on from them.
    _downloader?.stop();
    _downloader = null;
  }

  @override
  void stop() async {
    pause();
    var directory = Directory(path);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  @override
  Map<String, dynamic> toMap() => {
        'video': video.toJson(),
        'quality': quality,
        'currentBytes': _currentBytes,
        'totalBytes': _totalBytes,
        ...toBaseMap(),
      };

  R34VideoDownloadingItem.fromMap(
    Map<String, dynamic> map,
    DownloadProgressCallback onFinish,
    DownloadProgressCallback onError,
    DownloadProgressCallbackAsync updateInfo,
  )   : video = R34Video.fromJson(Map<String, dynamic>.from(map['video'])),
        quality = map['quality'] as String? ?? '',
        _currentBytes = map['currentBytes'] as int?,
        _totalBytes = map['totalBytes'] as int?,
        super.fromMap(map, onFinish, onError, updateInfo);

  @override
  FutureOr<DownloadedItem> toDownloadedItem() async =>
      R34DownloadedVideo(video, quality, await getFolderSize(Directory(path)));
}
