import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reads a saved response from test/fixtures.
String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

Uint8List fixtureBytes(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

typedef FakeHandler = FutureOr<FakeResponse> Function(RequestOptions request);

class FakeResponse {
  final List<int> bytes;
  final int status;
  final Map<String, List<String>> headers;

  FakeResponse(
    Object body, {
    this.status = 200,
    Map<String, String> headers = const {},
  })  : bytes = body is List<int> ? body : utf8.encode(body as String),
        headers = {
          for (final entry in headers.entries) entry.key: [entry.value],
        };
}

/// Answers every request made through `logDio` / `CachedNetwork` from a table
/// of routes. A request without a route gets a 404, so a test cannot reach the
/// real site by accident.
class FakeHttp implements HttpClientAdapter {
  final _routes = <(Pattern, FakeHandler)>[];

  /// Every request that was sent, in order.
  final requests = <RequestOptions>[];

  List<String> get urls => [for (final r in requests) r.uri.toString()];

  /// Routes are tried in the order they were added. A [String] pattern matches
  /// when the URL contains it.
  void on(Pattern url, FakeHandler handler) => _routes.add((url, handler));

  void text(Pattern url, String body, {Map<String, String> headers = const {}}) =>
      on(url, (_) => FakeResponse(body, headers: headers));

  void file(Pattern url, String name) =>
      on(url, (_) => FakeResponse(fixtureBytes(name)));

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final url = options.uri.toString();
    for (final (pattern, handler) in _routes) {
      final matches =
          pattern is String ? url.contains(pattern) : pattern.allMatches(url).isNotEmpty;
      if (!matches) continue;
      final response = await handler(options);
      return ResponseBody.fromBytes(response.bytes, response.status,
          headers: response.headers);
    }
    return ResponseBody.fromString('no fixture for $url', 404);
  }

  @override
  void close({bool force = false}) {}
}

/// Installs a [FakeHttp] and the in-memory services the network classes
/// expect (cookies, response cache, preferences) for the current test file.
FakeHttp useFakeHttp() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final http = FakeHttp();
  late Directory root;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('pica_source_test');
    CacheManager.instance =
        CacheManager.createForTest('${root.path}/cache', '${root.path}/cache.db');
    SingleInstanceCookieJar.instance = null;
    SingleInstanceCookieJar(':memory:');
    AppHttpAdapter.testAdapter = http;
  });

  tearDownAll(() {
    AppHttpAdapter.testAdapter = null;
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    CacheManager.instance = null;
    root.deleteSync(recursive: true);
  });

  return http;
}
