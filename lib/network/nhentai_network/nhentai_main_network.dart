import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cloudflare.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/tags.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import '../app_dio.dart';
import 'models.dart';
import 'package:html/parser.dart';

export 'models.dart';

class NhentaiNetwork {
  factory NhentaiNetwork() => _cache ?? (_cache = NhentaiNetwork._create());

  NhentaiNetwork._create();

  static NhentaiNetwork? _cache;

  SingleInstanceCookieJar? cookieJar;

  bool logged = false;

  String baseUrl = "https://nhentai.net";

  late Dio dio;

  Future<void> init() async {
    cookieJar = SingleInstanceCookieJar.instance;
    for (var cookie in cookieJar!.loadForRequest(Uri.parse(baseUrl))) {
      // 新版 nhentai 以 access_token 标识登录态(旧版为 sessionid),两者都算已登录
      if (cookie.name == "sessionid" || cookie.name == "access_token") {
        logged = true;
      }
    }
    dio = logDio(BaseOptions(
      headers: {
        "Accept":
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "Accept-Language": "zh-CN,zh-TW;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6",
        "Referer": "$baseUrl/",
      },
      validateStatus: (i) => i != null && i >= 200 && i < 400,
    ));
    dio.interceptors.add(CookieManagerSql(cookieJar!));
    dio.interceptors.add(CloudflareInterceptor());
  }

  void logout() async {
    logged = false;
    cookieJar!.delete(Uri.parse(baseUrl), "sessionid");
    cookieJar!.delete(Uri.parse(baseUrl), "access_token");
  }

  Future<Res<String>> get(String url, [int redirects = 0]) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      var res = await dio.get<String>(url, options: Options(followRedirects: false));
      // nhentai 用 301/302/307/308 迁移路径(如 /favorites -> /user/favorites),
      // 手动跟随并保留 cookie,最多 5 跳防死循环
      if ((res.statusCode == 301 || res.statusCode == 302 ||
              res.statusCode == 307 || res.statusCode == 308) &&
          redirects < 5) {
        var location = res.headers["Location"]?.first ??
            res.headers["location"]?.first ??
            "";
        if (location.isNotEmpty) {
          var next = Uri.parse(location).hasScheme
              ? Uri.parse(location)
              : Uri.parse(url).resolve(location);
          return get(next.toString(), redirects + 1);
        }
      }
      return Res(res.data);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<String>> post(String url, dynamic data,
      [Map<String, String>? headers]) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      var res = await dio.post<String>(url, data: data, options: Options(headers: headers));
      return Res(res.data);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<String>> delete(String url,
      [Map<String, String>? headers]) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      var res = await dio.delete<String>(url, options: Options(headers: headers));
      return Res(res.data);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  /// 从 data-sveltekit-fetched 内嵌 API 数据中读 is_favorited(登录后请求才会带 favorite 字段)
  bool? _isFavoritedFromFetchedData(Document document) {
    for (final script
        in document.querySelectorAll('script[data-sveltekit-fetched]')) {
      try {
        final dataUrl = script.attributes['data-url'] ?? '';
        if (!dataUrl.contains('/api/v2/galleries/')) continue;
        final wrapper = jsonDecode(parseFragment(script.text).text ?? '');
        if (wrapper is! Map || wrapper['body'] is! String) continue;
        final payload = jsonDecode(wrapper['body'] as String);
        if (payload is Map && payload['is_favorited'] is bool) {
          return payload['is_favorited'] as bool;
        }
      } catch (_) {
        // 解析失败则跳过
      }
    }
    return null;
  }

  Map<String, String> languagesFromFetchedData(Document document) {
    final languages = <String, String>{};
    for (final script in document.querySelectorAll('script[data-sveltekit-fetched]')) {
      try {
        // Server-rendered script text may encode quotes as HTML entities.
        final wrapper = jsonDecode(parseFragment(script.text).text ?? '');
        if (wrapper is! Map || wrapper['body'] is! String) continue;
        final payload = jsonDecode(wrapper['body'] as String);
        // /api/v2/galleries/popular 的 payload 直接是 List;其余是 {result: [...]}
        final galleries = payload is List
            ? payload
            : (payload is Map ? payload['result'] : null);
        if (galleries is! List) continue;
        for (final gallery in galleries) {
          if (gallery is! Map || gallery['id'] == null || gallery['tag_ids'] is! List) continue;
          final tags = (gallery['tag_ids'] as List).map((tag) => tag.toString()).toSet();
          final id = gallery['id'].toString();
          if (tags.contains('12227')) {
            languages[id] = 'English';
          } else if (tags.contains('6346')) {
            languages[id] = '\u65e5\u672c\u8a9e';
          } else if (tags.contains('29963')) {
            languages[id] = '\u4e2d\u6587';
          }
        }
      } catch (_) {
        // Other SvelteKit blocks may have a different shape; use card tags.
      }
    }
    return languages;
  }

  NhentaiComicBrief parseComic(Element comicDom,
      [Map<String, String>? languagesById]) {
    var img = comicDom.querySelector("a > img")!.attributes["src"]!;
    var name = comicDom.querySelector("div.caption")!.text;
    var id = comicDom.querySelector("a")!.attributes["href"]!.nums;
    var lang = languagesById?[id] ?? "Unknown";
    var tags = comicDom.attributes["data-tags"] ?? "";
    if (tags.contains("12227")) {
      lang = "English";
    } else if (tags.contains("6346")) {
      lang = "日本語";
    } else if (tags.contains("29963")) {
      lang = "中文";
    }
    var tagsRes = <String>[];
    for (var tag in tags.split(" ")) {
      if (nhentaiTags[tag] != null) {
        tagsRes.add(nhentaiTags[tag]!);
      }
    }
    return NhentaiComicBrief(name, img, id, lang, tagsRes);
  }

  List<T> removeNullValue<T extends Object>(List<T?> list) {
    while (list.remove(null)) {}
    return List.from(list);
  }

  Future<Res<NhentaiHomePageData>> getHomePage([int? page]) async {
    var url = baseUrl;
    if (page != null && page != 1) {
      url = "$url?page=$page";
    }
    var res = await get(url);
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      final languagesById = languagesFromFetchedData(document);
      List<Element> popularDoms;
      if (url == baseUrl) {
        popularDoms = document.querySelectorAll(
            "div.container.index-container.index-popular > div.gallery");
      } else {
        popularDoms = const [];
      }
      var latest = document
          .querySelectorAll("div.container.index-container > div.gallery");

      return Res(NhentaiHomePageData(
        removeNullValue(List.generate(
            popularDoms.length, (index) => parseComic(popularDoms[index], languagesById))),
        removeNullValue(List.generate(latest.length - popularDoms.length,
            (index) => parseComic(latest[index + popularDoms.length], languagesById))),
      ));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<bool>> loadMoreHomePageData(NhentaiHomePageData data) async {
    var res = await get("$baseUrl?page=${data.page + 1}");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      final languagesById = languagesFromFetchedData(document);

      var latest = document.querySelectorAll("div.gallery");

      data.latest.addAll(removeNullValue(
          List.generate(latest.length, (index) => parseComic(latest[index], languagesById))));

      data.page++;

      return const Res(true);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<List<NhentaiComicBrief>>> search(String keyword, int page,
      [NhentaiSort sort = NhentaiSort.recent]) async {
    if (appdata.searchHistory.contains(keyword)) {
      appdata.searchHistory.remove(keyword);
    }
    appdata.searchHistory.add(keyword);
    appdata.writeHistory();
    var res = await get(
        "$baseUrl/search?q=${Uri.encodeComponent(keyword)}&page=$page${sort.value}");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      final languagesById = languagesFromFetchedData(document);

      var comicDoms = document.querySelectorAll("div.gallery");

      var lastPagination = document
          .querySelector("section.pagination > a.last")
          ?.attributes["href"]
          ?.nums;

      Future.microtask(() {
        try {
          StateController.find<PreSearchController>().update();
        } catch (e) {
          //
        }
      });

      if (comicDoms.isEmpty) {
        return const Res([], subData: 0);
      }

      return Res(
          removeNullValue(List.generate(
              comicDoms.length, (index) => parseComic(comicDoms[index], languagesById))),
          subData: lastPagination == null ? 1 : int.parse(lastPagination));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<NhentaiComic>> getComicInfo(String id) async {
    Res<String> res;
    if (id == "") {
      res = await get("$baseUrl/random");
      if (res.error) {
        return Res.fromErrorRes(res);
      }
    } else {
      res = await get("$baseUrl/g/$id/");
    }
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      String combineSpans(Element? title) {
        var res = "";
        for (var span in title?.children ?? []) {
          res += span.text;
        }
        return res;
      }

      var document = parse(res.data);
      final languagesById = languagesFromFetchedData(document);
      
      id = id == "" ? document.querySelector("h3#gallery_id")!.text.nums : id;

      var cover = document
          .querySelector("div#cover > a > img")!
          .attributes["src"]!;

      var title = combineSpans(document.querySelector("h1.title")!);

      var subTitle = combineSpans(document.querySelector("h2.title"));

      Map<String, List<String>> tags = {};
      for (var field in document.querySelectorAll("div.tag-container")) {
        var fieldName =
            field.firstChild!.text!.removeAllBlank.replaceLast(":", "");
        if (fieldName == "Uploaded") {
          var timeStr = document.querySelector("time")?.attributes["datetime"];
          if (timeStr != null) {
            tags["时间".tl] = [timeToString(DateTime.parse(timeStr))];
            continue;
          }
        }
        tags[fieldName] = [];
        for (var span in field.querySelectorAll("span.name")) {
          tags[fieldName]!.add(span.text);
        }
      }

      // 新版页面:优先从内嵌 API 数据读 is_favorited(登录后才有),否则回退按钮文案
      bool favorite = false;
      if (logged) {
        favorite = _isFavoritedFromFetchedData(document) ??
            document.querySelector("button#favorite > span.text")?.text !=
                "Favorite";
      }

      var thumbnails = <String>[];
      for (var t in document.querySelectorAll("a.gallerythumb > img")) {
        thumbnails.add(t.attributes["src"]!);
      }

      var recommendations = <NhentaiComicBrief>[];
      for (var comic in document.querySelectorAll("div.gallery")) {
        var c = parseComic(comic, languagesById);
        recommendations.add(c);
      }
      return Res(NhentaiComic(id, title, subTitle, cover, tags, favorite,
          thumbnails, recommendations, ""));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<List<NhentaiComment>>> getComments(String id) async {
    var res = await get("$baseUrl/api/gallery/$id/comments");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var json = const JsonDecoder().convert(res.data);
      var comments = <NhentaiComment>[];
      for (var c in json) {
        comments.add(NhentaiComment(
            c["poster"]["username"],
            "https://i3.nhentai.net/${c["poster"]["avatar_url"]}",
            c["body"],
            c["post_date"]));
      }
      return Res(comments);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<List<String>>> getImages(String id) async {
    var res = await get("$baseUrl/g/$id/1/");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      var scripts = document
          .querySelectorAll("script");

      var script = scripts
          .firstWhere((element) => element.text.contains("media_id"))
          .text;

      var galleryData = json.decode(json.decode(script)["body"]);

      // 新版页面已移除 #image-container,取当前页图片地址推导图片服务器
      var url = (document.querySelector("#image-container > a > img") ??
              document.querySelector("img[loading='eager']"))
          ?.attributes["src"] ??
          "";

      String baseUrl = url.split('/galleries')[0];

      var images = <String>[];
      for (var image in galleryData["pages"]) {
        images.add("$baseUrl/${image["path"]}");
      }

      return Res(images);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  // 一页 25 个
  Future<Res<List<NhentaiComicBrief>>> getFavorites(int page) async {
    if (!logged) {
      return const Res(null, errorMessage: "login required");
    }
    // nhentai 收藏页已迁移到 /user/favorites(旧 /favorites 会 301/308 链式重定向,Dio 不跟随)
    var res = await get("$baseUrl/user/favorites?page=$page");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      final languagesById = languagesFromFetchedData(document);
      var comics = document.querySelectorAll("div.gallery");
      var lastPagination = document
          .querySelector("section.pagination > a.last")
          ?.attributes["href"]
          ?.nums;
      return Res(
          removeNullValue(List.generate(
              comics.length, (index) => parseComic(comics[index], languagesById))),
          subData: lastPagination == null ? 1 : int.parse(lastPagination));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  /// 从 cookieJar 读取新版 API 的 access_token(webview 登录时已保存)
  Future<String?> _getAccessToken() async {
    for (var cookie in cookieJar!.loadForRequest(Uri.parse(baseUrl))) {
      if (cookie.name == "access_token" && cookie.value.isNotEmpty) {
        return cookie.value;
      }
    }
    return null;
  }

  /// 通过 /auth/refresh 刷新 access_token(响应 set-cookie 由 CookieManagerSql 自动入库)
  Future<void> _refreshAccessToken() async {
    try {
      await dio.post<String>("$baseUrl/auth/refresh");
    } catch (_) {
      // 会话失效/网络错误时忽略,由调用方处理
    }
  }

  /// 新版收藏 API:/api/v2/galleries/{id}/favorite,鉴权走 Authorization: User <token>
  Future<Res<bool>> _favoriteRequest(
      String method, String id, String? token) async {
    if (token == null || token.isEmpty) {
      return const Res(null, errorMessage: "login required");
    }
    final headers = <String, String>{
      "Referer": "$baseUrl/g/$id",
      "X-Requested-With": "XMLHttpRequest",
      "Authorization": "User $token",
    };
    final res = method == "DELETE"
        ? await delete("$baseUrl/api/v2/galleries/$id/favorite", headers)
        : await post("$baseUrl/api/v2/galleries/$id/favorite", null, headers);
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return const Res(true);
  }

  Future<Res<bool>> favoriteComic(String id) async {
    var token = await _getAccessToken();
    var res = await _favoriteRequest("POST", id, token);
    if (res.error) {
      // 无 token 或 token 失效:先刷新再重试一次
      await _refreshAccessToken();
      res = await _favoriteRequest("POST", id, await _getAccessToken());
    }
    return res;
  }

  Future<Res<bool>> unfavoriteComic(String id) async {
    var token = await _getAccessToken();
    var res = await _favoriteRequest("DELETE", id, token);
    if (res.error) {
      await _refreshAccessToken();
      res = await _favoriteRequest("DELETE", id, await _getAccessToken());
    }
    return res;
  }

  Future<Res<List<NhentaiComicBrief>>> getCategoryComics(
      String path, int page, NhentaiSort sort) async {
    var param = switch (sort) {
      NhentaiSort.recent => '/',
      NhentaiSort.popularToday => '/popular-today',
      NhentaiSort.popularWeek => '/popular-week',
      NhentaiSort.popularMonth => '/popular-month',
      NhentaiSort.popularAll => '/popular'
    };
    var res = await get("$baseUrl$path$param?page=$page");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      final languagesById = languagesFromFetchedData(document);

      var comicDoms = document.querySelectorAll("div.gallery");

      var lastPagination = document
          .querySelector("section.pagination > a.last")
          ?.attributes["href"]
          ?.nums;

      Future.microtask(() {
        try {
          StateController.find<PreSearchController>().update();
        } catch (e) {
          //
        }
      });

      if (comicDoms.isEmpty) {
        return const Res([], subData: 0);
      }

      return Res(
          removeNullValue(List.generate(
              comicDoms.length, (index) => parseComic(comicDoms[index], languagesById))),
          subData: lastPagination == null ? 1 : int.parse(lastPagination));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }
}

enum NhentaiSort {
  recent(""),
  popularToday("&sort=popular-today"),
  popularWeek("&sort=popular-week"),
  popularMonth("&sort=popular-month"),
  popularAll("&sort=popular");

  final String value;

  const NhentaiSort(this.value);

  static NhentaiSort fromValue(String value) {
    switch (value) {
      case "":
        return NhentaiSort.recent;
      case "&sort=popular-today":
        return NhentaiSort.popularToday;
      case "&sort=popular-week":
        return NhentaiSort.popularWeek;
      case "&sort=popular-month":
        return NhentaiSort.popularMonth;
      case "&sort=popular":
        return NhentaiSort.popularAll;
      default:
        return NhentaiSort.recent;
    }
  }
}
