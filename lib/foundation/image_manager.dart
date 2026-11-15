import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/image_loader/image_recombine.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/eh_network/get_gallery_id.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/file_type.dart';

import '../base.dart';
import '../network/eh_network/eh_main_network.dart';
import '../network/hitomi_network/image.dart';
import '../network/jm_network/headers.dart';
import '../network/res.dart';

class BadRequestException {
  final String message;

  const BadRequestException(this.message);

  @override
  String toString() => message;
}

class ImageManager {
  static ImageManager? cache;

  ///用于标记正在加载的项目, 避免出现多个异步函数加载同一张图片
  static Map<String, DownloadProgress> loadingItems = {};

  /// Image cache manager for reader and download manager
  factory ImageManager() => cache ??= ImageManager._create();

  static bool get haveTask => loadingItems.isNotEmpty;

  static void clearTasks() {
    loadingItems.clear();
  }

  ImageManager._create();

  final dio = logDio(BaseOptions())
    ..interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));

  int ehgtLoading = 0;

  /// Loads one image: at most one load per key at a time, the cache is asked
  /// first, the download is written to the cache while it arrives, and the
  /// partial file is removed when the load fails or the listener goes away.
  ///
  /// Only the last event is [DownloadProgress.finished]; by then the file is
  /// complete on disk.
  Stream<DownloadProgress> _load(_ImageJob job) async* {
    final key = job.key;
    await wait(key);
    loadingItems[key] = DownloadProgress(0, 1, job.reportUrl, "");
    CachingFile? caching;

    try {
      var cache = await CacheManager().findCache(key);
      if (cache != null) {
        yield DownloadProgress(
            1, 1, job.reportUrl, cache, null, CacheManager().getType(key));
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 100, job.reportUrl, savePath);

      await job.prepare?.call();

      final buffer = BytesBuilder();
      late Response<ResponseBody> response;
      for (var attempt = 1;; attempt++) {
        try {
          buffer.clear();
          cachingFile.reset();
          response = await job.request();
          final body = response.data;
          if (body == null) {
            throw Exception("Empty Data");
          }
          final total = _contentLength(body);
          await for (var chunk in body.stream) {
            buffer.add(chunk);
            if (job.transform == null) {
              await cachingFile.writeBytes(chunk);
            }
            var progress = DownloadProgress(
                buffer.length,
                job.sizeWhileLoading(buffer.length, total),
                job.reportUrl,
                savePath);
            yield progress;
            loadingItems[key] = progress;
          }
          break;
        } catch (e) {
          if (attempt >= job.attempts) {
            if (job.exhausted != null) {
              throw job.exhausted!;
            }
            rethrow;
          }
          if (job.beforeRetry == null || !await job.beforeRetry!(e)) {
            rethrow;
          }
        }
      }

      var bytes = buffer.takeBytes();
      if (job.transform != null) {
        // Everything is here, the rest is processing.
        var progress = DownloadProgress(bytes.length,
            max(bytes.length + 1, bytes.length * 4 ~/ 3), job.reportUrl, savePath);
        yield progress;
        loadingItems[key] = progress;
        bytes = await job.transform!(bytes, savePath);
        // The transform may have written the file itself.
        cachingFile.reset();
        await cachingFile.writeBytes(bytes);
      }
      await cachingFile.close();
      String? ext;
      if (job.storeType) {
        ext = job.ext != null ? job.ext!(bytes) : getExt(response);
        CacheManager().setType(key, ext);
      }
      yield DownloadProgress(
          bytes.length, bytes.length, job.reportUrl, savePath, bytes, ext);
    } catch (e, s) {
      caching?.cancel();
      log("Failed to load image ${job.reportUrl}\n$e\n$s", "Network",
          LogLevel.error);
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        var statusCode = e.response?.statusCode;
        if (statusCode != null && statusCode >= 400 && statusCode < 500) {
          throw BadRequestException(e.message.toString());
        }
      }
      rethrow;
    } finally {
      job.onDone?.call();
      // Also runs when the listener cancels: drop the partial file.
      caching?.cancel();
      loadingItems.remove(key);
    }
  }

  static int? _contentLength(ResponseBody body) {
    var header = (body.headers["content-length"] ??
            body.headers["Content-Length"])
        ?.firstOrNull;
    var length = header == null ? null : int.tryParse(header);
    return length != null && length > 0 ? length : null;
  }

  static void _refuseHtml(Response<ResponseBody> res) {
    var type = (res.data!.headers["Content-Type"] ??
            res.data!.headers["content-type"])
        ?.firstOrNull;
    if (type == "text/html; charset=UTF-8") {
      throw ImageExceedError();
    }
  }

  /// 获取图片, 适用于没有任何限制的图片链接
  Stream<DownloadProgress> getImage(final String url,
      [Map<String, String>? headers]) {
    headers = headers ?? {};
    headers["User-Agent"] ??= webUA;
    headers["Connection"] = "Keep-Alive";
    var realUrl = url;
    if (url.contains("s.exhentai.org")) {
      // s.exhentai.org 有严格的加载限制
      realUrl = url.replaceFirst("s.exhentai.org", "ehgt.org");
    }
    var countedEhgt = false;

    return _load(_ImageJob(
      key: url,
      reportUrl: url,
      prepare: () async {
        // ehgt.org: three images at a time.
        if (!realUrl.contains("ehgt.org")) return;
        if (ehgtLoading < 3) {
          ehgtLoading++;
          countedEhgt = true;
          await Future.delayed(const Duration(milliseconds: 10));
        } else {
          while (ehgtLoading > 2) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          ehgtLoading++;
          countedEhgt = true;
        }
      },
      request: () => dio.get<ResponseBody>(realUrl,
          options:
              Options(responseType: ResponseType.stream, headers: headers)),
      onDone: () {
        if (countedEhgt) {
          ehgtLoading--;
        }
      },
    ));
  }

  Stream<DownloadProgress> getEhImageNew(final Gallery gallery, final int page) {
    final galleryLink = gallery.link;
    final cacheKey = "$galleryLink$page";
    final gid = getGalleryId(galleryLink);

    late final Dio dio;
    late final String readerLink;
    late final String imgKey;
    late final bool mpv;
    var image = "";
    String? nl;

    Future<void> getShowKey() async {
      while (gallery.auth!["showKey"] == "loading") {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (gallery.auth!["showKey"] != null || gallery.auth!["mpvKey"] != null) {
        return;
      }
      gallery.auth!["showKey"] = "loading";
      try {
        var res = await EhNetwork().request(readerLink);

        var html = parse(res.data);
        var script = html
            .querySelectorAll("script")
            .firstWhereOrNull((element) => element.text.contains("showkey"));
        if (script != null) {
          var match = RegExp(r'showkey="(.*?)"').firstMatch(script.text);
          final showKey = match!.group(1)!;
          gallery.auth!["showKey"] = showKey;
        } else {
          final script = html
              .querySelectorAll("script")
              .firstWhereOrNull((element) => element.text.contains("mpvkey"))
              ?.text;
          if (script == null) {
            throw Exception("Failed to get showKey or mpvkey");
          }
          var mpvKey = script
              .split(";")
              .firstWhere((element) => element.contains("mpvkey"));
          gallery.auth!["mpvKey"] = mpvKey.removeAllBlank
              .replaceFirst("varmpvkey=", "")
              .replaceAll('"', "");
          var imageListScript = script
              .split(";")
              .firstWhere((element) => element.contains("imagelist"))
              .removeAllBlank
              .replaceFirst("varimagelist=", "");
          gallery.auth!["imgKey"] =
              jsonDecode(imageListScript).map((e) => e["k"]).join(",");
          gallery.auth!.remove("showKey");
        }
      } catch (e) {
        gallery.auth!.remove("showKey");
        rethrow;
      }
    }

    // Multi-page viewer: the API hands out the image address directly.
    Future<(String image, String nl)> getImageFromMpvApi([String? nl]) async {
      Res<String>? apiRes = await EhNetwork().apiRequest({
        "gid": int.parse(gid),
        "imgkey": gallery.auth!["imgKey"]!.split(',')[page - 1],
        "method": "imagedispatch",
        "page": page,
        "mpvkey": gallery.auth!["mpvKey"],
        if (nl != null) "nl": nl
      });
      var apiJson = const JsonDecoder().convert(apiRes.data);
      return (apiJson["i"].toString(), apiJson["s"].toString());
    }

    Future<(String, String, String?)> getImageFromApi() async {
      // get image url through api
      Res<String>? apiRes = await EhNetwork().apiRequest({
        "gid": int.parse(gid),
        "imgkey": imgKey,
        "method": "showpage",
        "page": page,
        "showkey": gallery.auth!["showKey"]
      });

      if (apiRes.error && apiRes.errorMessage!.contains("handshake")) {
        throw "Failed to make api request.\n"
            "This may be due to too frequent requests.\n"
            "Try to wait for some time and retry.";
      }

      var apiJson = const JsonDecoder().convert(apiRes.data);

      var i6 = apiJson["i6"] as String;

      RegExp regex = RegExp(r"nl\('(.+?)'\)");
      var nl = regex.firstMatch(i6)?.group(1);

      var originImage = i6.split("<a href=\"").last.split("\">").first;

      var image = apiJson["i3"] as String;

      image = image.substring(
          image.indexOf("src=\"") + 5, image.indexOf("\" style"));

      return (image, originImage, nl);
    }

    Future<(String, String, String?)> getImageFromHtml() async {
      var res = await EhNetwork().request(readerLink);
      if (res.error) {
        throw res.errorMessage ?? "error";
      } else {
        var document = parse(res.data);
        var image =
            document.querySelector("div#i3 > a > img")?.attributes["src"];
        var nl = document
            .querySelector("div#i6 > div > a#loadfail")
            ?.attributes["onclick"]
            ?.split('\'')
            .firstWhereOrNull((element) => element.contains('-'));
        var originImage = document
                .querySelectorAll("div#i6 > div > a")
                .firstWhereOrNull(
                    (element) => element.text.contains("original"))
                ?.attributes["href"] ??
            "";
        return (image ?? "", originImage, nl);
      }
    }

    return _load(_ImageJob(
      key: cacheKey,
      reportUrl: cacheKey,
      // The first address, then up to three others from the reload key.
      attempts: 4,
      exhausted: "Failed to load image.\nMaximum number of retries reached.",
      prepare: () async {
        dio = logDio(BaseOptions(
            followRedirects: true,
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 20),
            headers: {"user-agent": webUA, "cookie": EhNetwork().cookiesStr}));

        readerLink = (await EhNetwork().getReaderLink(galleryLink, page)).data;
        await getShowKey();
        assert(gallery.auth?["showKey"] != null ||
            gallery.auth?["mpvKey"] != null);
        imgKey = readerLink.split('/')[4];
        mpv = gallery.auth?["mpvKey"] != null;

        if (mpv) {
          (image, nl) = await getImageFromMpvApi();
          return;
        }

        String originImage;
        try {
          (image, originImage, nl) = await getImageFromApi();
        } catch (e) {
          (image, originImage, nl) = await getImageFromHtml();
        }
        if (image.contains("509.gif")) {
          throw ImageExceedError();
        }
        if (appdata.settings[29] == "1" && originImage.isURL) {
          image = originImage;
        }
      },
      request: () async {
        if (image == "") {
          throw "empty url";
        }
        var res = await dio.get<ResponseBody>(image,
            options: Options(responseType: ResponseType.stream));
        _refuseHtml(res);
        return res;
      },
      beforeRetry: (error) async {
        if (mpv) {
          (image, nl) = await getImageFromMpvApi(nl);
          return true;
        }
        if (nl == null) {
          return false;
        }
        var (newImage, newNl) = await EhNetwork()
            .getImageLinkWithNL(getGalleryId(galleryLink), imgKey, page, nl!);
        image = newImage;
        if (kDebugMode) {
          print("Get new image: $image, new nl $newNl");
        }
        if (newNl != null) {
          nl = newNl;
        }
        return true;
      },
      ext: (bytes) => detectFileType(bytes).ext.replaceFirst(('.'), ''),
    ));
  }

  ///为Hitomi设计的图片加载函数
  ///
  /// 使用hash标识图片
  Stream<DownloadProgress> getHitomiImage(HitomiFile image, String galleryId) {
    late final String url;
    return _load(_ImageJob(
      key: image.hash,
      reportUrl: image.hash,
      prepare: () async {
        url = await GG().urlFromUrlFromHash(galleryId, image, 'webp', null);
      },
      request: () {
        var dio = logDio();
        dio.options.headers = {
          "User-Agent": webUA,
          "Referer": "https://hitomi.la/reader/$galleryId.html"
        };
        return dio.get<ResponseBody>(url,
            options: Options(responseType: ResponseType.stream));
      },
    ));
  }

  ///获取禁漫图片, 如果缓存中没有, 则尝试下载
  Stream<DownloadProgress> getJmImage(String url, Map<String, String>? headers,
      {required String epsId,
      required String scrambleId,
      required String bookId}) {
    bookId = bookId.replaceAll(RegExp(r"\..+"), "");
    final urlWithoutParam = url.replaceAll(RegExp(r"\?.+"), "");

    return _load(_ImageJob(
      key: urlWithoutParam,
      reportUrl: url,
      request: () => logDio().get<ResponseBody>(url,
          options: Options(
              responseType: ResponseType.stream, headers: getImgHeaders())),
      // 无法获取jm文件大小, 构建虚假的进度条
      sizeWhileLoading: (received, _) => max(1 << 20, received + 1),
      // 需要对图片进行重组, 处理完成后再写入
      transform: url.split('.').last == "gif"
          ? null
          : (bytes, savePath) => startRecombineAndWriteImage(
              bytes, epsId, scrambleId, bookId, savePath),
    ));
  }

  Stream<DownloadProgress> getCustomImage(
      String url, String comicId, String epId, String sourceKey) {
    return _loadWithConfig(
      "$sourceKey$comicId$epId$url",
      url,
      sourceKey,
      (source) => source.getImageLoadingConfig?.call(url, comicId, epId),
    );
  }

  Stream<DownloadProgress> getCustomThumbnail(String url, String sourceKey,
      [Map<String, String>? headers]) {
    return _loadWithConfig(
      "$sourceKey$url",
      url,
      sourceKey,
      (source) => source.getThumbnailLoadingConfig?.call(url),
      headers: headers,
      storeType: false,
    );
  }

  /// An image whose request is described by the comic source: address,
  /// method, headers, and optionally a function that rewrites the bytes.
  Stream<DownloadProgress> _loadWithConfig(
    String cacheKey,
    String url,
    String sourceKey,
    Map<String, dynamic>? Function(ComicSource source) getConfig, {
    Map<String, String>? headers,
    bool storeType = true,
  }) {
    // Resolved by the first step that needs it, after the cache was asked.
    late final Map<String, dynamic> config = () {
      var source = ComicSource.find(sourceKey) ??
          (throw "Unknown Comic Source $sourceKey");
      var config = getConfig(source) ?? <String, dynamic>{};
      if (headers != null) {
        config['headers'] ??= headers;
      }
      return config;
    }();

    late final _ImageJob job;
    job = _ImageJob(
      key: cacheKey,
      reportUrl: url,
      storeType: storeType,
      prepare: () async {
        if (config['onResponse'] == null) return;
        job.transform = (bytes, _) {
          var data = (config['onResponse'] as JSInvokable)(bytes);
          if (data is! Uint8List) {
            throw "Invalid Config: onImageLoad.onResponse return invalid type\n"
                "Expected: Uint8List(ArrayBuffer)\n"
                "Got: ${data.runtimeType}";
          }
          return data;
        };
      },
      request: () => dio.request<ResponseBody>(config['url'] ?? url,
          data: config['data'],
          options: Options(
              method: config['method'] ?? 'GET',
              headers: config['headers'] ?? {'user-agent': webUA},
              responseType: ResponseType.stream)),
    );
    return _load(job);
  }

  Future<void> wait(String cacheKey) {
    int timeout = 50;
    return Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 300));
      timeout--;
      if (timeout == 0) {
        loadingItems.remove(cacheKey);
        return false;
      }
      return loadingItems[cacheKey] != null;
    });
  }

  Future<File?> getFile(String key) async {
    var cache = await CacheManager().findCache(key);
    if (cache != null) {
      return File(cache);
    }
    return null;
  }

  Future<void> clear() async {
    await CacheManager().clear();
  }

  Future<bool> find(String key) async {
    return await CacheManager().findCache(key) != null;
  }

  Future<void> delete(String key) async {
    await CacheManager().delete(key);
  }

  String? getExt(Response res) {
    String? ext;
    var url = res.realUri.toString();
    var contentType =
        (res.headers["Content-Type"] ?? res.headers["content-type"])?[0];
    if (contentType != null) {
      ext = switch (contentType) {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        _ => null
      };
    }
    ext ??= url.split('.').last;
    if (!["jpg", "jpeg", "png", "gif", "webp"].contains(ext)) {
      ext = "jpg";
      LogManager.addLog(
          LogLevel.warning,
          "ImageManager",
          "Unknown image extension: \n"
              "Content-Type: $contentType\n"
              "URL: $url");
    }
    return ext;
  }
}

/// What differs between the kinds of image. Everything else is shared in
/// [ImageManager._load].
class _ImageJob {
  _ImageJob({
    required this.key,
    required this.reportUrl,
    required this.request,
    this.prepare,
    this.attempts = 1,
    this.beforeRetry,
    this.exhausted,
    this.transform,
    this.ext,
    this.storeType = true,
    this.sizeWhileLoading = _knownOrGrowing,
    this.onDone,
  });

  /// Cache key. Also marks the image as being loaded.
  final String key;

  /// Reported as [DownloadProgress.url].
  final String reportUrl;

  /// Runs once after a cache miss and before the first request, e.g. to
  /// find out the address of the image.
  final Future<void> Function()? prepare;

  /// Opens the image. Called once per attempt.
  final Future<Response<ResponseBody>> Function() request;

  /// How many times [request] may be tried.
  final int attempts;

  /// Runs after a failed attempt that is not the last one, e.g. to get
  /// another address. Returning false gives up with the error of that
  /// attempt. Without it there are no retries.
  final Future<bool> Function(Object error)? beforeRetry;

  /// Thrown when every attempt failed; the last error when null.
  final Object? exhausted;

  /// Rewrites the downloaded bytes before they are cached. When set, nothing
  /// is written to the cache file until the download is complete.
  FutureOr<Uint8List> Function(Uint8List bytes, String savePath)? transform;

  /// File type of the image; from the response headers and address when null.
  final String? Function(Uint8List bytes)? ext;

  /// Whether the file type is stored with the cache entry and reported.
  final bool storeType;

  /// Total size to report while [received] bytes have arrived.
  final int Function(int received, int? contentLength) sizeWhileLoading;

  /// Runs when the load ends, however it ends.
  final void Function()? onDone;

  /// The announced size, but never equal to what has arrived: only the last
  /// event of a load may look finished.
  static int _knownOrGrowing(int received, int? contentLength) =>
      contentLength != null && contentLength > received
          ? contentLength
          : received + 1;
}

class DownloadProgress {
  final int _currentBytes;
  final int _expectedBytes;
  final String url;
  final String savePath;
  final Uint8List? data;
  final String? ext;

  int get currentBytes => _currentBytes;

  int get expectedBytes => _expectedBytes;

  bool get finished => _currentBytes == _expectedBytes;

  const DownloadProgress(
      this._currentBytes, this._expectedBytes, this.url, this.savePath,
      [this.data, this.ext]);

  File getFile() => File(savePath);
}

class ImageExceedError extends Error {
  @override
  String toString() => "Maximum image loading limit reached.";
}
