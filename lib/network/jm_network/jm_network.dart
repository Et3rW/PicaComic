import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:html/parser.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/jm.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ecb.dart';

import '../../foundation/cache_manager.dart';
import '../../foundation/log.dart';
import '../app_dio.dart';
import '../http_client.dart';
import '../res.dart';
import 'headers.dart';
import 'domain_selection.dart';
import 'jm_image.dart';
import 'jm_models.dart';

extension _CachedNetwork on CachedNetwork {
  Future<CachedNetworkRes<String>> getJm(
      String url, BaseOptions options, int time,
      {CacheExpiredTime expiredTime = CacheExpiredTime.short,
      CookieJar? cookieJar}) async {
    await setNetworkProxy();
    final key = url;
    var cache = await CacheManager().findCache(key);
    if (cache != null) {
      var file = File(cache);
      return CachedNetworkRes(await file.readAsString(), 200, url);
    }
    options.responseType = ResponseType.bytes;
    var dio = logDio(options);
    if (cookieJar != null) {
      dio.interceptors.add(CookieManager(cookieJar));
    }
    var res = await dio.get<Uint8List>(url);
    if (res.data == null) {
      throw Exception("Empty data");
    }
    var body = utf8.decoder.convert(res.data!);
    if (res.statusCode != 200) {
      return CachedNetworkRes(body, res.statusCode, res.realUri.toString());
    }
    var json = const JsonDecoder().convert(body);
    var data = json["data"];
    if (data is List && data.isEmpty) {
      throw Exception("Empty data");
    } else if (data is List) {
      throw Exception("Data parsing error");
    }
    var decodedData = JmNetwork.convertData(
        data,
        "$time${JmNetwork.kJmSecret}"
    );
    if (expiredTime != CacheExpiredTime.no) {
      await CacheManager().writeCache(key, res.data!, expiredTime.time);
    }
    return CachedNetworkRes(
        decodedData, res.statusCode, res.realUri.toString());
  }
}

class JmNetwork {
  static const baseData = "";

  // 禁漫的cookie无需持久化储存, 因为有效期非常短
  final cookieJar = CookieJar(ignoreExpires: true);

  var hotTags = <String>[];

  factory JmNetwork() => cache == null ? (cache = JmNetwork.create()) : cache!;

  JmNetwork.create({Dio Function(BaseOptions)? dioFactory})
      : _dioFactory = dioFactory ?? ((options) => logDio(options));

  final Dio Function(BaseOptions) _dioFactory;

  static JmNetwork? cache;

  static List<String> get domains => appdata.appSettings.jmApiDomains;

  String get baseUrl {
    final index = int.tryParse(appdata.settings[17]) ?? 0;
    return 'https://${domains[index >= 0 && index < domains.length ? index : 0]}';
  }

  static const domainUrls = [
    "https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt",
    "https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt",
  ];

  static const domainSecret = [100, 105, 111, 115, 102, 106, 99, 107, 119, 112, 113, 112, 100, 102, 106, 107, 118, 110, 113, 81, 106, 115, 105, 107];

  static const kJmSecret = '185Hcomic3PAPP7R';

  static const builtInImgUrls = <String>[
    "https://cdn-msp3.jmapiproxy1.cc",
    "https://cdn-msp.jmapiproxy3.cc",
    "https://cdn-msp2.jmapiproxy2.cc",
    "https://cdn-msp3.jmapiproxy3.cc"
  ];

  bool _performingLogin = false;
  int _loginRevision = 0;

  ///解密数据
  static String convertData(String input, String secret) {
    //hash得到密钥
    var key = md5.convert(const Utf8Encoder().convert(secret));
    //先将数据进行base64解码
    final data = base64Decode(input);
    //再进行AES-ECB解密
    BlockCipher cipher = ECBBlockCipher(AESEngine())
      ..init(false, KeyParameter(const Utf8Encoder().convert(key.toString())));
    var offset = 0;
    var paddedPlainText = Uint8List(data.length);
    while (offset < data.length) {
      offset += cipher.processBlock(data, offset, paddedPlainText, offset);
    }
    //将得到的数据进行Utf8解码
    var res = const Utf8Decoder().convert(paddedPlainText);
    //得到的数据在末尾有一些乱码
    int i = res.length - 1;
    for (; i >= 0; i--) {
      if (res[i] == '}' || res[i] == ']') {
        break;
      }
    }
    return res.substring(0, i + 1);
  }

  Future<void> init() async {
    loginFromAppdata();
  }

  Future<Res<dynamic>> getAppVersionCode() async {
    var dio = logDio(
        BaseOptions(
          headers: {
            ...getBaseHeaders(),
            "Accept-Encoding": "gzip",
            "user-agent": ua,
          },
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 10),
        )
    );
    try {
      var res = await dio.get("$baseUrl/static/jmapp3apk/version.json")
          .timeout(const Duration(seconds: 20));
      try {
        String version = res.data['version'];
        if (version.isNotEmpty) {
          return Res(version);
        } else {
          return const Res.error("No version code in response.");
        }
      } catch (e) {
        return Res(null, errorMessage: e.toString());
      }
    } catch (e) {
      if (kDebugMode) {
        print(e);
      }
      return Res(null, errorMessage: e.toString());
    } finally {
      dio.close(force: true);
    }
  }

  Future<List<String>> tryFetchAndDecrypt(String url) async {
    var dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 10),
          headers: {
            ...getBaseHeaders(),
            "user-agent": ua,
          },
        )
    );
    try {
      var res = await dio.get(url).timeout(const Duration(seconds: 15));
      var jsonData = json.decode(convertData(
          res.data,
          String.fromCharCodes(domainSecret)
      )) as Map<String, dynamic>;
      var domains = List<String>.from(jsonData['Server']);
      domains = domains.take(4).toList();
      return domains;
    } catch (e, s) {
      if (kDebugMode) {
        print(e);
      }
      LogManager.addLog(LogLevel.error, "Network", "$e\n$s");
      return [];
    } finally {
      dio.close(force: true);
    }
  }

  Future<Res<dynamic>> getApiDomains() async {
    for(String url in domainUrls) {
      var domains = await tryFetchAndDecrypt(url);
      if (domains.isNotEmpty) {
        return Res(domains);
      }
    }
    return const Res.error("Failed to get JM api domains");
  }

  Future<int?> selectDomain() async {
    await setNetworkProxy().timeout(const Duration(seconds: 5));
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dio = _dioFactory(getApiOptions(time, post: true));
    final cancel = CancelToken();
    try {
      return await selectJmDomain(List.of(domains), (domain) async {
        final res = await dio.post(
          'https://$domain/login',
          data: '&',
          options: Options(validateStatus: (_) => true, followRedirects: false),
          cancelToken: cancel,
        );
        // A generic proxy/HTML 401 does not identify a functioning JM API.
        if (res.statusCode != 401) return false;
        final body = res.data is List<int>
            ? jsonDecode(utf8.decode(res.data as List<int>))
            : res.data is String ? jsonDecode(res.data as String) : res.data;
        return body is Map && body['errorMsg'] is String;
      });
    } finally {
      cancel.cancel('JM line selection finished');
      dio.close(force: true);
    }
  }

  ///get请求, 返回Json数据中的data
  Future<Res<dynamic>> get(String url,
      {Map<String, String>? header,
      CacheExpiredTime expiredTime = CacheExpiredTime.long,
      bool isRetry = false}) async {
    while (_performingLogin) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    int time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var dio = CachedNetwork();
    var options = getApiOptions(time);
    options.validateStatus = (i) => i == 200 || i == 401;
    try {
      var res = await dio.getJm(url, options, time,
          cookieJar: cookieJar, expiredTime: CacheExpiredTime.no);
      if (res.statusCode == 401) {
        var message =
            const JsonDecoder().convert(res.data)["errorMsg"] ?? "Error";
        if (message == "請先登入會員" && jm.isLogin && !isRetry) {
          var res = await jm.reLogin();
          if (res) {
            return get(
              url,
              header: header,
              expiredTime: expiredTime,
              isRetry: true,
            );
          }
        }
        return Res(null, errorMessage: message);
      }

      final data = const JsonDecoder().convert(res.data);

      return Res<dynamic>(data);
    } on DioException catch (e) {
      if (kDebugMode) {
        print(e);
      }
      if (e.type != DioExceptionType.unknown) {
        return Res<String>(null, errorMessage: e.message ?? "Network Error");
      } else {
        return Res<String>(null, errorMessage: e.toString().split("\n")[1]);
      }
    } catch (e, s) {
      if (kDebugMode) {
        print(e);
      }
      LogManager.addLog(LogLevel.error, "Network", "$e\n$s");
      return Res<String>(null, errorMessage: e.toString());
    }
  }

  /// post请求
  Future<Res<dynamic>> post(String url, String data) async {
    Dio? dio;
    final cancel = CancelToken();
    try {
      await setNetworkProxy().timeout(const Duration(seconds: 5));
      int time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      dio = _dioFactory(getApiOptions(time, post: true));
      dio.interceptors.add(CookieManager(cookieJar));
      var res = await dio.post(url,
          options: Options(validateStatus: (i) => i == 200 || i == 401),
          data: data, cancelToken: cancel).timeout(const Duration(seconds: 30),
              onTimeout: () {
        cancel.cancel('JM request timed out');
        throw TimeoutException('JM request timed out');
      });
      if (res.statusCode == 401) {
        return Res(null,
            errorMessage: const JsonDecoder().convert(
                    const Utf8Decoder().convert(res.data))["errorMsg"] ??
                "Unknown Error".toString());
      }
      final envelope = jsonDecode(utf8.decode(res.data as List<int>));
      final decoded = jsonDecode(convertData(envelope['data'], '$time$kJmSecret'));
      // Some API versions return the AVS session in the login payload.
      if (Uri.parse(url).path == '/login' && decoded is Map &&
          decoded['username'] != null && decoded['uid'] != null) {
        final session = decoded['s'] ?? envelope['s'];
        if (session is String && session.isNotEmpty) {
          await cookieJar.saveFromResponse(Uri.parse(url), [
            Cookie('AVS', session)..path = '/'..secure = true..httpOnly = true,
          ]);
        }
      }
      return Res<dynamic>(decoded);
    } on TimeoutException {
      return const Res.error('禁漫请求超时，请检查网络或更新 API 域名后重试');
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final timedOut = {
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      }.contains(e.type);
      return Res.error(status == null
          ? '禁漫${timedOut ? "请求超时" : "网络连接失败"}，请检查网络或更新 API 域名'
          : '禁漫服务器返回 HTTP $status，请更新 API 域名或稍后重试');
    } catch (_) {
      return const Res.error('禁漫响应解析失败，请更新 API 域名或稍后重试');
    } finally {
      dio?.close(force: true);
    }
  }

  Future<void> updateImgUrl(int index, {bool allowReLogin = true}) async {
    try {
      var res = await get(
          "$baseUrl/setting?app_img_shunt=$index", isRetry: !allowReLogin,
      );
      var url = res.data["img_host"];
      appdata.settings[86] = url;
      appdata.updateSettings();
      LogManager.addLog(LogLevel.info, "Network", "Updated JM Image URL: $url");
    } on DioException catch (e) {
      if (kDebugMode) {
        print(e);
      }
    } catch (e, s) {
      if (kDebugMode) {
        print(e);
      }
      LogManager.addLog(LogLevel.error, "Network", "$e\n$s");
    }
  }

  ///获取主页
  Future<Res<HomePageData>> getHomePage() async {
    var res = await get("$baseUrl/promote?$baseData&page=0",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var data = HomePageData([]);
      for (var item in res.data) {
        var comics = <JmComicBrief>[];
        for (var comic in item["content"]) {
          try {
            var categories = <ComicCategoryInfo>[];
            if (comic["category"]["id"] != null &&
                comic["category"]["title"] != null) {
              categories.add(ComicCategoryInfo(
                  comic["category"]["id"], comic["category"]["title"]));
            }
            if (comic["category_sub"]["id"] != null &&
                comic["category_sub"]["title"] != null) {
              categories.add(ComicCategoryInfo(
                  comic["category_sub"]["id"], comic["category_sub"]["title"]));
            }
            comics.add(JmComicBrief(comic["id"], comic["author"], comic["name"],
                comic["description"] ?? "", categories));
          } catch (e) {
            continue;
          }
        }
        String type = item["type"];
        String id = item["id"].toString();
        if (type == "category_id") {
          id = item["slug"];
        }
        data.items
            .add(HomePageItem(item["title"], id, comics, type != "promote"));
      }
      return Res(data);
    } catch (e, s) {
      if (kDebugMode) {
        print(e);
      }
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<PromoteList>> getPromoteList(String id) async {
    var res = await get("$baseUrl/promote_list?$baseData&id=$id&page=0",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var list = PromoteList(id, []);
      list.total = int.parse(res.data["total"]);
      for (var comic in (res.data["list"])) {
        var categories = <ComicCategoryInfo>[];
        if (comic["category"]["id"] != null &&
            comic["category"]["title"] != null) {
          categories.add(ComicCategoryInfo(
              comic["category"]["id"], comic["category"]["title"]));
        }
        if (comic["category_sub"]["id"] != null &&
            comic["category_sub"]["title"] != null) {
          categories.add(ComicCategoryInfo(
              comic["category_sub"]["id"], comic["category_sub"]["title"]));
        }
        try {
          list.comics.add(JmComicBrief(comic["id"], comic["author"],
              comic["name"], comic["description"] ?? "", categories));
        } catch (e) {
          //忽略
        }
        list.loaded++;
      }
      list.page++;
      return Res(list);
    } catch (e, s) {
      if (kDebugMode) {
        print(e);
      }
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<void> loadMorePromoteListComics(PromoteList list) async {
    if (list.loaded >= list.total) {
      return;
    }
    var res = await get(
        "$baseUrl/promote_list?$baseData&id=${list.id}&page=${list.page}",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return;
    }
    try {
      for (var comic in (res.data["list"])) {
        var categories = <ComicCategoryInfo>[];
        if (comic["category"]["id"] != null &&
            comic["category"]["title"] != null) {
          categories.add(ComicCategoryInfo(
              comic["category"]["id"], comic["category"]["title"]));
        }
        if (comic["category_sub"]["id"] != null &&
            comic["category_sub"]["title"] != null) {
          categories.add(ComicCategoryInfo(
              comic["category_sub"]["id"], comic["category_sub"]["title"]));
        }
        try {
          list.comics.add(JmComicBrief(comic["id"], comic["author"],
              comic["name"], comic["description"] ?? "", categories));
        } catch (e) {
          //忽视
        }
        list.loaded++;
      }
      list.page++;
      return;
    } catch (e, s) {
      if (kDebugMode) {
        print(e);
      }
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return;
    }
  }

  Future<Res<List<JmComicBrief>>> getLatest(int page) async {
    var res = await get("$baseUrl/latest?$baseData&page=$page",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var comics = <JmComicBrief>[];
      for (var comic in (res.data)) {
        try {
          var categories = <ComicCategoryInfo>[];
          if (comic["category"]["id"] != null &&
              comic["category"]["title"] != null) {
            categories.add(ComicCategoryInfo(
                comic["category"]["id"], comic["category"]["title"]));
          }
          if (comic["category_sub"]["id"] != null &&
              comic["category_sub"]["title"] != null) {
            categories.add(ComicCategoryInfo(
                comic["category_sub"]["id"], comic["category_sub"]["title"]));
          }
          comics.add(JmComicBrief(comic["id"], comic["author"], comic["name"],
              comic["description"] ?? "", categories));
        } catch (e) {
          continue;
        }
      }
      return Res(comics, subData: 99999);
    } catch (e, s) {
      if (kDebugMode) {
        print(e);
      }
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  ///获取热搜词
  Future<Res<bool>> getHotTags() async {
    var res = await get("$baseUrl/hot_tags?$baseData",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    hotTags.clear();
    for (var s in res.data) {
      hotTags.add(s);
    }
    return const Res(true);
  }

  Future<Res<List<JmComicBrief>>> searchNew(
      String keyword, int page, ComicsOrder order) async {
    appdata.searchHistory.remove(keyword);
    appdata.searchHistory.add(keyword);
    keyword = keyword.trim();
    keyword = keyword.replaceAll('  ', ' ');
    keyword = Uri.encodeComponent(keyword);
    keyword = keyword.replaceAll('%20', '+');
    appdata.writeHistory();
    Res res;
    if (page != 1) {
      res = await get(
          "$baseUrl/search?&search_query=$keyword&o=$order&page=$page",
          expiredTime: CacheExpiredTime.no);
    } else {
      res = await get("$baseUrl/search?&search_query=$keyword&o=$order",
          expiredTime: CacheExpiredTime.no);
    }
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var comics = <JmComicBrief>[];
      for (var comic in (res.data["content"])) {
        try {
          var categories = <ComicCategoryInfo>[];
          if (comic["category"]["id"] != null &&
              comic["category"]["title"] != null) {
            categories.add(ComicCategoryInfo(
                comic["category"]["id"], comic["category"]["title"]));
          }
          if (comic["category_sub"]["id"] != null &&
              comic["category_sub"]["title"] != null) {
            categories.add(ComicCategoryInfo(
                comic["category_sub"]["id"], comic["category_sub"]["title"]));
          }
          comics.add(JmComicBrief(comic["id"], comic["author"], comic["name"],
              comic["description"] ?? "", categories));
        } catch (e) {
          continue;
        }
      }
      Future.delayed(const Duration(microseconds: 500), () {
        try {
          StateController.find<PreSearchController>().update();
        } catch (e) {
          //跳过
        }
      });
      // return Res(comics,
      //     subData: comics.isEmpty
      //         ? 0
      //         : (int.parse(res.data["total"]) / res.data["content"].length)
      //             .ceil());
      return Res(comics,
            subData: comics.isEmpty
                ? 0
                : ((res.data["total"] as num) / res.data["content"].length).ceil());
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      Future.delayed(const Duration(microseconds: 500),
          () => StateController.find<PreSearchController>().update());
      return Res(null, errorMessage: e.toString());
    }
  }

  ///获取分类信息
  Future<Res<List<Category>>> getCategories() async {
    var res = await get("$baseUrl/categories?$baseData");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var categories = <Category>[];
      for (var c in res.data["categories"]) {
        var subCategories = <SubCategory>[];
        for (var sc in c["sub_categories"] ?? []) {
          subCategories.add(SubCategory(sc["CID"], sc["name"], sc["slug"]));
        }
        categories.add(Category(c["name"], c["slug"], subCategories));
      }
      return Res(categories);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<JmComicBrief>>> getCategoryComics(
      String category, ComicsOrder order, int page) async {
    var res = await get(
        "$baseUrl/categories/filter?$baseData&o=$order&c=${Uri.encodeComponent(category)}&page=$page",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var comics = <JmComicBrief>[];
      for (var comic in (res.data["content"])) {
        try {
          var categories = <ComicCategoryInfo>[];
          if (comic["category"]["id"] != null &&
              comic["category"]["title"] != null) {
            categories.add(ComicCategoryInfo(
                comic["category"]["id"], comic["category"]["title"]));
          }
          if (comic["category_sub"]["id"] != null &&
              comic["category_sub"]["title"] != null) {
            categories.add(ComicCategoryInfo(
                comic["category_sub"]["id"], comic["category_sub"]["title"]));
          }
          comics.add(JmComicBrief(comic["id"], comic["author"], comic["name"],
              comic["description"] ?? "", categories));
        } catch (e) {
          continue;
        }
      }
      Object total = res.data["total"];
      if (total is String) {
        total = int.parse(total);
      }
      var current = res.data["content"].length;
      var pagesCount = 1;
      if (current != 0) {
        pagesCount = ((total as int) / current).ceil();
      }
      return Res(comics, subData: pagesCount);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<JmComicInfo>> getComicInfo(String id) async {
    var res = await get("$baseUrl/album?id=$id",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      if (res.errorMessage!.contains("Empty data")) {
        throw Exception("漫畫不存在: id = $id");
      }
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var author = <String>[];
      for (var s in res.data["author"] ?? "未知") {
        author.add(s);
      }
      var series = <int, String>{};
      var epNames = <String>[];
      int sort = 1;
      for (var s in res.data["series"] ?? []) {
        series[sort] = s["id"];
        sort++;
        var name = s["name"] as String;
        if (name.isEmpty) {
          name = "第${s["sort"]}話";
        }
        epNames.add(name);
      }
      var tags = <String>[];
      for (var s in res.data["tags"] ?? []) {
        tags.add(s);
      }
      var works = <String>[];
      for (var s in res.data["works"] ?? []) {
        works.add(s);
      }
      var actors = <String>[];
      for (var s in res.data["actors"] ?? []) {
        actors.add(s);
      }
      var related = <JmComicBrief>[];
      for (var c in res.data["related_list"] ?? []) {
        related.add(JmComicBrief(c["id"], c["author"] ?? "Unknown",
            c["name"] ?? "Unknown", c["description"] ?? "None", []));
      }
      return Res(JmComicInfo(
          res.data["name"] ?? "未知",
          id,
          author,
          res.data["description"] ?? "无",
          int.parse(res.data["likes"] ?? "0"),
          int.parse(res.data["total_views"] ?? "0"),
          series,
          tags,
          works,
          actors,
          related,
          res.data["liked"] ?? false,
          res.data["is_favorite"] ?? false,
          int.parse(res.data["comment_total"] ?? "0"),
          epNames));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<bool>> login(String account, String pwd) async {
    if (_performingLogin) return const Res.error('禁漫正在登录，请稍候再试');
    _performingLogin = true;
    final revision = ++_loginRevision;
    try {
      if (appdata.settings[15] == "1") {
        final i = await selectDomain();
        if (i == null) {
          return const Res.error('禁漫所有 API 线路均不可用，请在漫画源设置中更新 API 域名，或关闭自动选择域名后手动切换');
        }
        appdata.settings[17] = i.toString();
      }
      if (revision != _loginRevision) return const Res.error('登录已取消');
      var res = await post("$baseUrl/login",
          "username=${Uri.encodeComponent(account)}&password=${Uri.encodeComponent(pwd)}");
      if (revision != _loginRevision) {
        await cookieJar.deleteAll();
        return const Res.error('登录已取消');
      }
      if (res.error) {
        return Res(null, errorMessage: res.errorMessage);
      }
      if (res.data is! Map || res.data['username'] == null || res.data['uid'] == null) {
        return const Res.error('禁漫登录响应缺少账号信息，请更新 API 域名后重试');
      }
      jm.data['name'] = res.data['username'];
      jm.data['id'] = res.data['uid'];
      unawaited(_finishLogin(revision));
      return const Res(true);
    } catch (_) {
      return const Res.error('禁漫登录失败，请检查网络或更新 API 域名后重试');
    } finally {
      _performingLogin = false;
    }
  }

  Future<void> _finishLogin(int revision) async {
    // Optional work must never keep the account screen waiting or re-enter login.
    await Future<void>.delayed(Duration.zero);
    if (revision != _loginRevision) return;
    try {
      await appdata.updateSettings();
      await updateImgUrl((int.tryParse(appdata.settings[37]) ?? 0) + 1,
          allowReLogin: false);
      if (revision == _loginRevision && appdata.settings[88] == "1") {
        final res = await dailyChk(allowReLogin: false);
        LogManager.addLog(
            res.error ? LogLevel.error : LogLevel.info,
            "Network",
            res.error
                ? "JM auto check-in failed\n${res.errorMessage}"
                : "JM auto check-in succeed\n${res.subData}"
        );
      }
    } catch (_) {
      LogManager.addLog(LogLevel.warning, 'Network', 'JM post-login setup failed');
    }
  }

  /// 使用储存的数据进行登录
  Future<Res<bool>> loginFromAppdata() async {
    var res = await jm.reLogin();
    return res ? const Res(true) : const Res.error("error");
  }

  Future<void> logout() async {
    _loginRevision++;
    await cookieJar.deleteAll();
  }

  Future<void> likeComic(String id) async {
    await post("$baseUrl/like", "id=$id&$baseData");
  }

  ///创建收藏夹
  Future<Res<bool>> createFolder(String name) async {
    var res = await post(
        "$baseUrl/favorite_folder", "type=add&folder_name=$name&$baseData");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    } else {
      return const Res(true);
    }
  }

  Future<Res<List<JmComicBrief>>> getFolderComicsPage(
      String id, int page) async {
    ComicsOrder order =
        appdata.settings[42] == "0" ? ComicsOrder.latest : ComicsOrder.update;
    var res = await get(
        "$baseUrl/favorite?$baseData&page=$page&folder_id=$id&o=$order",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var comics = <JmComicBrief>[];
      for (var comic in (res.data["list"])) {
        var categories = <ComicCategoryInfo>[];
        if (comic["category"]["id"] != null &&
            comic["category"]["title"] != null) {
          categories.add(ComicCategoryInfo(
              comic["category"]["id"], comic["category"]["title"]));
        }
        if (comic["category_sub"]["id"] != null &&
            comic["category_sub"]["title"] != null) {
          categories.add(ComicCategoryInfo(
              comic["category_sub"]["id"], comic["category_sub"]["title"]));
        }
        comics.add(JmComicBrief(comic["id"], comic["author"], comic["name"],
            comic["description"] ?? "", categories));
      }
      int pages;
      if (comics.isNotEmpty) {
        pages = (int.parse(res.data["total"]) / comics.length).ceil();
      } else {
        pages = 0;
      }
      return Res(comics, subData: pages);
    } catch (e, s) {
      if (kDebugMode) {
        print(e);
      }
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  ///获取收藏夹
  Future<Res<Map<String, String>>> getFolders() async {
    var res = await get("$baseUrl/favorite?$baseData",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var folders = <String, String>{};
      for (var folder in res.data["folder_list"]) {
        folders[folder["FID"]] = folder["name"];
      }
      return Res(folders);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  ///移动漫画至指定的收藏夹
  Future<Res<bool>> moveToFolder(String comicId, String folderId) async {
    var res = await post("$baseUrl/favorite_folder",
        "type=move&folder_id=$folderId&aid=$comicId&$baseData");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    } else {
      return const Res(true);
    }
  }

  ///收藏漫画, 如果folder为null, 则为取消收藏
  Future<Res<bool>> favorite(String id, String? folder) async {
    try {
      if (folder != null) {
        var res = await post("$baseUrl/favorite", "aid=$id&$baseData");
        if (res.data["type"] != "add") {
          res = await post("$baseUrl/favorite", "aid=$id&$baseData");
        }
        Res res2 = const Res(true);
        if (folder != "0") {
          res2 = await moveToFolder(id, folder);
        }
        if (res.error || res2.error) {
          return Res(null, errorMessage: res.errorMessage);
        } else {
          return const Res(true);
        }
      } else {
        var res = await post("$baseUrl/favorite", "aid=$id&$baseData");
        if (res.data["type"] == "add") {
          res = await post("$baseUrl/favorite", "aid=$id&$baseData");
        }
        return const Res(false);
      }
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  ///获取漫画图片
  Future<Res<List<String>>> getChapter(String id) async {
    var res = await get("$baseUrl/chapter?&id=$id");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var images = <String>[];
      for (var s in res.data["images"]) {
        images.add(getJmImageUrl(s, id));
      }
      return Res(images);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  ///获取scramble
  ///
  /// 此函数未使用, 因为似乎所有漫画的scramble都一样
  Future<String?> getScramble(String id) async {
    var dio = Dio(
        getApiOptions(DateTime.now().millisecondsSinceEpoch ~/ 1000, byte: false))
      ..interceptors.add(LogInterceptor());
    dio.interceptors.add(CookieManager(cookieJar));
    var res = await dio.get(
        "$baseUrl/chapter_view_template?id=$id&mode=vertical&page=0&app_ima_shunt=NaN&express=off");
    var exp = RegExp(r"(?<=var scramble_id = )\w+");
    return exp.firstMatch(res.data)!.group(0);
  }

  /// 获取评论, 获取章节评论需要mode = all
  Future<Res<List<Comment>>> getComment(String id, int page,
      [String mode = "manhua"]) async {
    var res = await get("$baseUrl/forum?mode=$mode&aid=$id&page=$page",
        expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      String parseContent(String input) {
        var fragment = parseFragment(input);
        return fragment.querySelector("div")?.text ?? "";
      }

      var comments = <Comment>[];
      for (var c in res.data["list"]) {
        var reply = <Comment>[];
        for (var r in c["replys"] ?? []) {
          reply.add(Comment(r["CID"], getJmAvatarUrl(r["photo"]), r["username"],
              r["addtime"], parseContent(r["content"]), []));
        }
        comments.add(Comment(c["CID"], getJmAvatarUrl(c["photo"]),
            c["username"], c["addtime"], parseContent(c["content"]), reply));
      }
      return Res(
        comments,
        subData: res.data["total"] is int
            ? res.data["total"]
            : (int.tryParse(res.data["total"]) ?? 1),
      );
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<bool>> deleteFolder(String id) async {
    var res = await post(
        "$baseUrl/favorite_folder", "type=del&folder_id=$id&$baseData");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    } else {
      if (res.data["code"] == 400) {
        return Res(null, errorMessage: res.data["msg"]);
      }
      return const Res(true);
    }
  }

  ///获取每周必看列表
  ///
  /// 返回Map, 键为ID, 值为名称
  Future<Res<Map<String, String>>> getWeekRecommendation() async {
    var res =
        await get("$baseUrl/week?$baseData", expiredTime: CacheExpiredTime.no);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage!);
    }
    try {
      Map<String, String> categories = {};
      for (var c in res.data["categories"]) {
        categories[c["id"]] = c["time"];
      }
      return Res(categories);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  ///获取单个每周必看中的漫画
  ///
  /// 不需要传递page变量, 因为只有一页
  Future<Res<List<JmComicBrief>>> getWeekRecommendationComics(
      String id, WeekRecommendationType type) async {
    var res = await get("$baseUrl/week/filter?$baseData&id=$id&page=0$type");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage!);
    }
    try {
      var comics = <JmComicBrief>[];
      for (var comic in (res.data["list"])) {
        var categories = <ComicCategoryInfo>[];
        if (comic["category"]["id"] != null &&
            comic["category"]["title"] != null) {
          categories.add(ComicCategoryInfo(
              comic["category"]["id"], comic["category"]["title"]));
        }
        if (comic["category_sub"]["id"] != null &&
            comic["category_sub"]["title"] != null) {
          categories.add(ComicCategoryInfo(
              comic["category_sub"]["id"], comic["category_sub"]["title"]));
        }
        comics.add(JmComicBrief(comic["id"], comic["author"], comic["name"],
            comic["description"] ?? "", categories));
      }
      return Res(comics);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analysis", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<dynamic>> comment(String aid, String content) async {
    var res = await post("$baseUrl/comment",
        "comment=${Uri.encodeComponent(content)}&status=undefined&aid=$aid&$baseData");
    if (res.error) {
      return res;
    } else {
      return Res(res.data["msg"]);
    }
  }

  Future<Res<bool>> dailyChk({bool allowReLogin = true}) async {
    try {
      var res = await get(
          "$baseUrl/daily?user_id=${jm.data['id']}", isRetry: !allowReLogin);
      if (res.error) {
        return Res(null, errorMessage: res.errorMessage);
      }
      final dailyId = res.data['daily_id'];
      if (dailyId == null) {
        return const Res(null, errorMessage: "daily_id not found");
      }
      res = await post(
          "$baseUrl/daily_chk",
          "user_id=${jm.data['id']}&daily_id=$dailyId&"
      );
      if (res.error) {
        return Res(null, errorMessage: res.errorMessage);
      }
      String msg = res.data['msg'];
      if (msg.startsWith("今天")
              || msg.contains("Jcoin")
              || msg.contains("EXP")) {
        return Res(true, subData: msg);
      } else {
        return Res(null, errorMessage: msg);
      }
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }
}

///禁漫漫画排序模式
enum ComicsOrder {
  ///最新
  latest("mr"),

  ///总排行, 或者最多点击
  totalRanking("mv"),

  ///月排行, 仅分类中
  monthRanking("mv_m"),

  ///周排行, 仅分类中
  weekRanking("mv_w"),

  ///日排行, 仅分类中
  dayRanking("mv_t"),

  ///最多图片
  maxPictures("mp"),

  ///最多喜欢
  maxLikes("tf"),

  /// 最新更新(收藏夹)
  update("mp");

  @override
  String toString() => value;

  final String value;

  const ComicsOrder(this.value);

  static ComicsOrder fromValue(String value) {
    for (var v in ComicsOrder.values) {
      if (v.value == value) return v;
    }
    throw UnimplementedError();
  }
}

///每周必看的类型
enum WeekRecommendationType {
  korean("&type=hanman"),
  manga("&type=manga"),
  another("&type=another");

  const WeekRecommendationType(this.value);

  final String value;

  @override
  String toString() => value;
}

var jmNetwork = JmNetwork();
