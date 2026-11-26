import 'package:dio/dio.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/res.dart';

import 'models.dart';
import 'parser.dart';

/// Requests to rule34video.com. Lists and video pages are plain HTML; nothing
/// needs an account.
class Rule34VideoNetwork {
  factory Rule34VideoNetwork() => _instance;

  Rule34VideoNetwork._();

  static final _instance = Rule34VideoNetwork._();

  static const baseUrl = R34Parser.baseUrl;

  /// Paths of the lists that are not a category, tag or person.
  static const latestPath = '/latest-updates/';
  static const popularPath = '/most-popular/';
  static const topRatedPath = '/top-rated/';

  Future<Res<String>> _get(String url) async {
    try {
      var res = await CachedNetwork().get(
        url,
        BaseOptions(headers: {
          'User-Agent': webUA,
          'Referer': '$baseUrl/',
        }),
        cookieJar: SingleInstanceCookieJar.instance,
        // Lists change by the minute, and a video's addresses expire.
        expiredTime: CacheExpiredTime.no,
      );
      return Res(res.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return const Res(null, errorMessage: 'Not found');
      }
      return Res(null, errorMessage: e.message ?? e.toString());
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  /// Address of page [page] of the list at [path] in [sort] order.
  static String listUrl(String path, int page, R34Sort sort) {
    if (!path.startsWith('/')) path = '/$path';
    if (!path.endsWith('/')) path = '$path/';
    var url = '$baseUrl$path';
    if (page > 1) url += '$page/';
    return '$url?sort_by=${sort.value}';
  }

  /// Videos of the list at [path]: `/latest-updates/`, `/categories/3d/`,
  /// `/tags/elf/`, `/models/name/`, `/members/123/`. [Res.subData] is the
  /// number of pages.
  Future<Res<List<R34VideoBrief>>> getList(String path, int page,
      [R34Sort sort = R34Sort.latest]) async {
    var res = await _get(listUrl(path, page, sort));
    if (res.error) return Res.fromErrorRes(res);
    return _parseList(res.data);
  }

  /// Videos matching [keyword].
  Future<Res<List<R34VideoBrief>>> search(String keyword, int page,
      [R34Sort sort = R34Sort.latest]) async {
    var query =
        Uri.encodeComponent(keyword.trim().replaceAll(RegExp(r'\s+'), '-'));
    var res = await _get(listUrl('/search/$query/', page, sort));
    if (res.error) return Res.fromErrorRes(res);
    return _parseList(res.data);
  }

  Res<List<R34VideoBrief>> _parseList(String page) {
    try {
      var (videos, pages) = R34Parser.videoList(page);
      return Res(videos, subData: pages);
    } catch (e) {
      return Res(null, errorMessage: 'Failed to parse the list: $e');
    }
  }

  /// A page of the site's categories, with the most videos first.
  Future<Res<List<R34Category>>> getCategories(int page) async {
    var url = '$baseUrl/categories/${page > 1 ? '$page/' : ''}'
        '?sort_by=total_videos';
    var res = await _get(url);
    if (res.error) return Res.fromErrorRes(res);
    try {
      var (categories, pages) = R34Parser.categoryList(res.data);
      return Res(categories, subData: pages);
    } catch (e) {
      return Res(null, errorMessage: 'Failed to parse the categories: $e');
    }
  }

  /// The video [id], with addresses that can be played right now.
  Future<Res<R34Video>> getVideo(String id) async {
    var res = await _get('$baseUrl/video/$id/');
    if (res.error) return Res.fromErrorRes(res);
    try {
      return Res(R34Parser.video(res.data, id));
    } on FormatException {
      return const Res(null,
          errorMessage: 'This video cannot be played (removed or private)');
    } catch (e) {
      return Res(null, errorMessage: 'Failed to parse the video page: $e');
    }
  }
}
