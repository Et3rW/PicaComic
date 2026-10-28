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
import 'login_flow.dart';
import 'page_parser.dart';
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
    logged = hasNhentaiSession({
      for (final cookie in cookieJar!.loadForRequest(Uri.parse(baseUrl)))
        cookie.name: cookie.value,
    });
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

  void logout() {
    logged = false;
    for (final name in nhentaiAuthCookieNames) {
      cookieJar?.deleteNamed(Uri.parse(baseUrl), name);
    }
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

  NhentaiComicBrief parseComic(Element comicDom,
      [Map<String, Set<String>>? tagIdsById]) {
    var img = comicDom.querySelector("a > img")!.attributes["src"]!;
    var name = comicDom.querySelector("div.caption")!.text;
    var id = comicDom.querySelector("a")!.attributes["href"]!.nums;
    final tagIds = nhentaiCardTagIds(comicDom, tagIdsById?[id] ?? const <String>{});
    final tags = <String>[
      for (final tag in tagIds)
        if (nhentaiTags[tag] case final String name) name,
    ];
    return NhentaiComicBrief(name, img, id, nhentaiLanguage(tagIds), tags);
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
      final tagIdsById = nhentaiTagIdsFromFetchedData(document);
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
            popularDoms.length, (index) => parseComic(popularDoms[index], tagIdsById))),
        removeNullValue(List.generate(latest.length - popularDoms.length,
            (index) => parseComic(latest[index + popularDoms.length], tagIdsById))),
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
      final tagIdsById = nhentaiTagIdsFromFetchedData(document);

      var latest = document.querySelectorAll("div.gallery");

      data.latest.addAll(removeNullValue(
          List.generate(latest.length, (index) => parseComic(latest[index], tagIdsById))));

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
      final tagIdsById = nhentaiTagIdsFromFetchedData(document);

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
              comicDoms.length, (index) => parseComic(comicDoms[index], tagIdsById))),
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
      final tagIdsById = nhentaiTagIdsFromFetchedData(document);
      
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

      final favorite = logged && nhentaiFavoriteState(document, id);

      var thumbnails = <String>[];
      for (var t in document.querySelectorAll("a.gallerythumb > img")) {
        thumbnails.add(t.attributes["src"]!);
      }

      var recommendations = <NhentaiComicBrief>[];
      for (var comic in document.querySelectorAll("div.gallery")) {
        var c = parseComic(comic, tagIdsById);
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
      final tagIdsById = nhentaiTagIdsFromFetchedData(document);
      var comics = document.querySelectorAll("div.gallery");
      var lastPagination = document
          .querySelector("section.pagination > a.last")
          ?.attributes["href"]
          ?.nums;
      return Res(
          removeNullValue(List.generate(
              comics.length, (index) => parseComic(comics[index], tagIdsById))),
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
      final tagIdsById = nhentaiTagIdsFromFetchedData(document);

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
              comicDoms.length, (index) => parseComic(comicDoms[index], tagIdsById))),
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
