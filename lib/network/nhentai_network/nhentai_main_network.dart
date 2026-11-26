import 'dart:convert';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cloudflare.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/tags.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import '../app_dio.dart';
import 'models.dart';
import 'login_flow.dart';
import 'page_parser.dart';
import 'tag_query.dart';

export 'models.dart';
export 'tag_query.dart' show NhentaiTagSuggestion;

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

  /// Image servers, from `/api/v2/cdn`. These are the answer of 2026-11 and
  /// are used until that request succeeds.
  String imageServer = 'https://i1.nhentai.net';
  String thumbServer = 'https://t1.nhentai.net';
  bool _cdnKnown = false;

  /// How long to wait before asking again when nhentai limits requests.
  static Duration rateLimitDelay = const Duration(seconds: 5);

  /// The longest wait a `Retry-After` header may ask for.
  static Duration maxRateLimitDelay = const Duration(seconds: 20);

  Future<void> _loadCdn() async {
    if (_cdnKnown) return;
    var res = await api('/api/v2/cdn');
    // On failure the known servers are kept and it is asked again next time.
    if (res.error || res.data is! Map) return;
    String? first(Object? servers) =>
        servers is List && servers.isNotEmpty ? '${servers.first}' : null;
    imageServer = first(res.data['image_servers']) ?? imageServer;
    thumbServer = first(res.data['thumb_servers']) ?? thumbServer;
    _cdnKnown = true;
  }

  /// The address of an image the API gives by its path.
  String imageUrl(String path) => _join(imageServer, path);

  String thumbUrl(String path) => _join(thumbServer, path);

  static String _join(String server, String path) {
    if (path.startsWith('http')) return path;
    return '${server.replaceFirst(RegExp(r'/+$'), '')}/'
        '${path.replaceFirst(RegExp(r'^/+'), '')}';
  }

  /// Calls nhentai's API. Logged in, the request carries the user's token,
  /// which also doubles the rate limits. When nhentai limits requests (429)
  /// it waits and asks once more.
  Future<Res<dynamic>> api(
    String path, {
    Map<String, String>? query,
    String method = 'GET',
    Object? data,
    bool needsLogin = false,
  }) async {
    if (cookieJar == null) {
      await init();
    }
    var uri = Uri.parse(baseUrl).resolve(path).replace(queryParameters: query);
    var token = await _getAccessToken();
    if (needsLogin && token == null) {
      return const Res(null, errorMessage: 'login required');
    }
    var refreshed = false;
    var waited = false;
    while (true) {
      try {
        var res = await dio.requestUri<String>(
          uri,
          data: data,
          options: Options(
            method: method,
            headers: {
              'Accept': 'application/json',
              if (token != null) 'Authorization': 'User $token',
            },
            contentType: data == null ? null : Headers.jsonContentType,
            responseType: ResponseType.plain,
          ),
        );
        var body = res.data ?? '';
        return Res(body.trim().isEmpty ? null : jsonDecode(body));
      } on DioException catch (e) {
        var status = e.response?.statusCode;
        if (status == 429 && !waited) {
          waited = true;
          await Future.delayed(_retryAfter(e.response!));
          continue;
        }
        if (status == 401 && token != null && !refreshed) {
          refreshed = true;
          await _refreshAccessToken();
          var newToken = await _getAccessToken();
          // A public request still works without a token.
          token = newToken != token ? newToken : null;
          if (token != null || !needsLogin) continue;
        }
        return Res(null, errorMessage: _apiError(e));
      } catch (e) {
        return Res(null, errorMessage: e.toString());
      }
    }
  }

  Duration _retryAfter(Response response) {
    var seconds = int.tryParse(
        response.headers.value('retry-after')?.trim() ?? '');
    if (seconds == null) return rateLimitDelay;
    var wait = Duration(seconds: seconds);
    return wait > maxRateLimitDelay ? maxRateLimitDelay : wait;
  }

  String _apiError(DioException e) {
    if (e is CloudflareException) return e.toString();
    var status = e.response?.statusCode;
    if (status == 429) return '请求太频繁, 请稍后再试'.tl;
    if (status == 401) return 'login required';
    if (status == 404) return 'Not Found';
    var data = e.response?.data;
    if (data is String && data.trim().startsWith('{')) {
      try {
        var json = jsonDecode(data);
        if (json is Map && json['error'] != null) {
          return '${json['error']}${json['details'] == null ? '' : ': ${json['details']}'}';
        }
      } catch (_) {
        // Not JSON after all; fall back to the status.
      }
    }
    return e.message ?? 'HTTP $status';
  }

  /// A comic of a list (`GalleryListItem`).
  NhentaiComicBrief parseComic(Map<String, dynamic> json) {
    var tagIds = <String>{
      for (var id in json['tag_ids'] as List? ?? const []) '$id',
    };
    var title = json['english_title'] as String?;
    if (title == null || title.isEmpty) {
      title = json['japanese_title'] as String? ?? '';
    }
    return NhentaiComicBrief(
      title,
      thumbUrl(json['thumbnail'] as String? ?? ''),
      '${json['id']}',
      nhentaiLanguage(tagIds),
      [
        for (var id in tagIds)
          if (nhentaiTags[id] case final String name) name,
      ],
    );
  }

  /// The comics of a list, without those the user's blacklist hides.
  List<NhentaiComicBrief> _comics(Object? list) => [
        for (var item in list as List? ?? const [])
          if (item is Map<String, dynamic> && item['blacklisted'] != true)
            parseComic(item),
      ];

  /// A page of a paginated list, with the number of pages as `subData`.
  Future<Res<List<NhentaiComicBrief>>> _list(String path,
      {Map<String, String>? query, bool needsLogin = false}) async {
    await _loadCdn();
    var res = await api(path, query: query, needsLogin: needsLogin);
    if (res.error) return Res.fromErrorRes(res);
    try {
      var data = res.data as Map<String, dynamic>;
      var pages = data['num_pages'];
      return Res(_comics(data['result']), subData: pages is int ? pages : 1);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  Future<Res<NhentaiHomePageData>> getHomePage([int? page]) async {
    await _loadCdn();
    page ??= 1;
    var [popular, latest] = await Future.wait([
      page == 1
          ? api('/api/v2/galleries/popular')
          : Future.value(const Res<dynamic>([])),
      _list('/api/v2/galleries', query: {'page': '$page'}),
    ]);
    if (latest.error) return Res.fromErrorRes(latest);
    // The popular strip is only a bonus: the newest still show without it.
    var data = NhentaiHomePageData(
      popular.error ? [] : _comics(popular.data),
      latest.data as List<NhentaiComicBrief>,
    );
    data.page = page;
    return Res(data);
  }

  Future<Res<bool>> loadMoreHomePageData(NhentaiHomePageData data) async {
    var res = await _list('/api/v2/galleries',
        query: {'page': '${data.page + 1}'});
    if (res.error) return Res.fromErrorRes(res);
    data.latest.addAll(res.data);
    data.page++;
    return const Res(true);
  }

  Future<Res<List<NhentaiComicBrief>>> search(String keyword, int page,
      [NhentaiSort sort = NhentaiSort.recent]) async {
    addSearchHistory(keyword);
    return _search(keyword, page, sort);
  }

  void addSearchHistory(String keyword) {
    if (appdata.searchHistory.contains(keyword)) {
      appdata.searchHistory.remove(keyword);
    }
    appdata.searchHistory.add(keyword);
    appdata.writeHistory();
  }

  /// Runs [query] without touching the search history.
  Future<Res<List<NhentaiComicBrief>>> searchQuery(
          String query, int page, NhentaiSort sort) =>
      _search(query, page, sort);

  /// Tag suggestions from `POST /api/v2/tags/search`.
  ///
  /// The endpoint works without login and returns
  /// `[{"type": "tag", "name": "big breasts", "count": 240332, ...}]`.
  /// Without [type] it mixes all namespaces in one request, which keeps
  /// typing from firing several requests (nhentai rate-limits bursts).
  Future<Res<List<NhentaiTagSuggestion>>> autocompleteTags(
    String query, {
    String? type,
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    if (cookieJar == null) {
      await init();
    }
    try {
      final res = await dio.post<dynamic>(
        '$baseUrl/api/v2/tags/search',
        data: {
          'type': type,
          'query': query,
          'limit': limit.clamp(1, 50),
        },
        options: Options(
          headers: {'Accept': 'application/json'},
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
        ),
        cancelToken: cancelToken,
      );
      return Res(parseNhentaiTagSuggestions(res.data));
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        return const Res(null, errorMessage: 'cancelled');
      }
      return Res(null, errorMessage: _apiError(e));
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<NhentaiComicBrief>>> _search(
      String keyword, int page, NhentaiSort sort) async {
    Future.microtask(() {
      try {
        StateController.find<PreSearchController>().update();
      } catch (e) {
        //
      }
    });
    if (keyword.trim().isEmpty && sort == NhentaiSort.recent) {
      return _list('/api/v2/galleries', query: {'page': '$page'});
    }
    return _list('/api/v2/search', query: {
      // The API wants at least one character; a space finds everything.
      'query': keyword.trim().isEmpty ? ' ' : keyword,
      'sort': sort.apiValue,
      'page': '$page',
    });
  }

  /// Field names of the detail page, in the order the site shows them.
  static const _fields = {
    'parody': 'Parodies',
    'character': 'Characters',
    'tag': 'Tags',
    'artist': 'Artists',
    'group': 'Groups',
    'language': 'Languages',
    'category': 'Categories',
  };

  Future<Res<NhentaiComic>> getComicInfo(String id) async {
    await _loadCdn();
    if (id == "") {
      var random = await api('/api/v2/galleries/random');
      if (random.error) return Res.fromErrorRes(random);
      id = '${(random.data as Map)['id']}';
    }
    var res = await api('/api/v2/galleries/$id', query: {
      'include': logged ? 'related,favorite' : 'related',
    });
    if (res.error) return Res.fromErrorRes(res);
    try {
      return Res(parseComicInfo(res.data as Map<String, dynamic>));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: "Failed to Parse Data: $e");
    }
  }

  /// A comic's page from `GET /api/v2/galleries/{id}`.
  NhentaiComic parseComicInfo(Map<String, dynamic> json) {
    var title = json['title'] as Map? ?? const {};
    var tags = <String, List<String>>{
      for (var field in _fields.values) field: <String>[],
    };
    for (var tag in json['tags'] as List? ?? const []) {
      var field = _fields[tag['type']];
      if (field != null) tags[field]!.add('${tag['name']}');
    }
    tags['Pages'] = ['${json['num_pages']}'];
    if (json['upload_date'] case int date) {
      tags["时间".tl] = [
        timeToString(DateTime.fromMillisecondsSinceEpoch(date * 1000))
      ];
    }
    String? path(Object? info) => info is Map ? info['path'] as String? : null;
    return NhentaiComic(
      '${json['id']}',
      '${title['english'] ?? title['pretty'] ?? ''}',
      '${title['japanese'] ?? ''}',
      thumbUrl(path(json['cover']) ?? path(json['thumbnail']) ?? ''),
      tags,
      logged && json['is_favorited'] == true,
      [
        for (var page in json['pages'] as List? ?? const [])
          if (page['thumbnail'] case String thumb) thumbUrl(thumb),
      ],
      _comics(json['related']),
      "",
    );
  }

  /// The first pages of comments, newest first.
  Future<Res<List<NhentaiComment>>> getComments(String id) async {
    await _loadCdn();
    var comments = <NhentaiComment>[];
    for (var page = 1; page <= 4; page++) {
      var res = await api('/api/v2/galleries/$id/comments',
          query: {'page': '$page'});
      if (res.error) {
        if (comments.isNotEmpty) break;
        return Res.fromErrorRes(res);
      }
      try {
        var data = res.data as Map<String, dynamic>;
        for (var c in data['result'] as List) {
          var avatar = c['poster']?['avatar_url'] as String?;
          comments.add(NhentaiComment(
            '${c['poster']?['username'] ?? ''}',
            avatar == null || avatar.isEmpty ? '' : imageUrl(avatar),
            '${c['body'] ?? ''}',
            c['post_date'] as int? ?? 0,
          ));
        }
        if (page >= (data['num_pages'] as int? ?? 1)) break;
      } catch (e, s) {
        LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
        return Res(null, errorMessage: "Failed to Parse Data: $e");
      }
    }
    return Res(comments);
  }

  Future<Res<List<String>>> getImages(String id) async {
    await _loadCdn();
    var res = await api('/api/v2/galleries/$id');
    if (res.error) return Res.fromErrorRes(res);
    try {
      return Res([
        for (var page in res.data['pages'] as List) imageUrl(page['path']),
      ]);
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
    return _list('/api/v2/favorites',
        query: {'page': '$page'}, needsLogin: true);
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

  /// Exchanges the refresh token for new tokens (`POST /api/v2/auth/refresh`)
  /// and keeps them where the login put them.
  Future<void> _refreshAccessToken() async {
    String? refreshToken;
    for (var cookie in cookieJar!.loadForRequest(Uri.parse(baseUrl))) {
      if (cookie.name == "refresh_token" && cookie.value.isNotEmpty) {
        refreshToken = cookie.value;
      }
    }
    if (refreshToken == null) return;
    try {
      var res = await dio.post<String>(
        '$baseUrl/api/v2/auth/refresh',
        data: {'refresh_token': refreshToken},
        options: Options(
          headers: {'Accept': 'application/json'},
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
        ),
      );
      var data = jsonDecode(res.data ?? '');
      if (data is! Map) return;
      cookieJar!.saveFromResponse(Uri.parse(baseUrl), [
        for (var name in const ['access_token', 'refresh_token'])
          if (data[name] case String value when value.isNotEmpty)
            io.Cookie(name, value)
              ..domain = '.nhentai.net'
              ..path = '/',
      ]);
    } catch (_) {
      // 会话失效/网络错误时忽略,由调用方处理
    }
  }

  /// 新版收藏 API:/api/v2/galleries/{id}/favorite,鉴权走 Authorization: User <token>
  Future<Res<bool>> _favoriteRequest(String method, String id) async {
    var res = await api('/api/v2/galleries/$id/favorite',
        method: method, needsLogin: true);
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  Future<Res<bool>> favoriteComic(String id) => _favoriteRequest("POST", id);

  Future<Res<bool>> unfavoriteComic(String id) =>
      _favoriteRequest("DELETE", id);

  /// Every gallery, with no tag and no language: the newest list, or a
  /// search when sorted by popularity or when tags are excluded.
  Future<Res<List<NhentaiComicBrief>>> getAllComics(int page, NhentaiSort sort,
      {String excludes = ''}) {
    excludes = excludes.trim();
    if (excludes.isNotEmpty) return _searchEverything(excludes, page, sort);
    if (sort == NhentaiSort.recent) {
      return _list('/api/v2/galleries', query: {'page': '$page'});
    }
    // A search needs some text; a space matches every gallery.
    return _searchEverything(' ', page, sort);
  }

  /// A search over every gallery is slow for the site, which then sometimes
  /// answers "no results"; asking again a little later usually works.
  Future<Res<List<NhentaiComicBrief>>> _searchEverything(
      String query, int page, NhentaiSort sort) async {
    var res = await _search(query, page, sort);
    for (var retry = 1; retry <= 2; retry++) {
      if (res.error || res.data.isNotEmpty) break;
      await Future<void>.delayed(retryDelay * retry);
      res = await _search(query, page, sort);
    }
    return res;
  }

  /// Wait before asking again, see [_searchEverything]. Tests shorten it.
  static Duration retryDelay = const Duration(seconds: 2);

  /// The comics of a category page such as `/tag/big-breasts`, through
  /// search, which takes the same namespace filter with every sort.
  Future<Res<List<NhentaiComicBrief>>> getCategoryComics(
      String path, int page, NhentaiSort sort) async {
    var parts =
        Uri.parse(path).pathSegments.where((s) => s.isNotEmpty).toList();
    if (parts.length == 2 && parts.first == 'search') {
      return _search(Uri.decodeComponent(parts.last), page, sort);
    }
    String query;
    try {
      query = nhentaiCategoryQuery(path);
    } on FormatException {
      return Res(null, errorMessage: 'Unknown nhentai category: $path');
    }
    return _search(query, page, sort);
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

  /// The `sort` parameter of `/api/v2/search`.
  String get apiValue => switch (this) {
        NhentaiSort.recent => 'date',
        NhentaiSort.popularToday => 'popular-today',
        NhentaiSort.popularWeek => 'popular-week',
        NhentaiSort.popularMonth => 'popular-month',
        NhentaiSort.popularAll => 'popular',
      };

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
