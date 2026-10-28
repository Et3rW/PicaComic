import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/jm.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/jm_network/domain_selection.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LoginNetwork extends JmNetwork {
  LoginNetwork() : super.create();
  int? selected = 0;
  bool throwSelection = false;
  int posts = 0;
  int images = 0;
  int checkins = 0;
  bool? imageRelogin;
  bool? checkinRelogin;
  Future<Res<dynamic>>? pendingPost;
  Completer<void>? pendingImage;
  final imageStarted = Completer<void>();
  final checkinStarted = Completer<void>();
  Res<dynamic> response = const Res.error('Incorrect credentials');

  @override
  Future<int?> selectDomain() async {
    if (throwSelection) throw StateError('selection failed');
    return selected;
  }

  @override
  Future<Res<dynamic>> post(String url, String data) async {
    posts++;
    return pendingPost == null ? response : await pendingPost!;
  }

  @override
  Future<void> updateImgUrl(int index, {bool allowReLogin = true}) async {
    images++;
    imageRelogin = allowReLogin;
    if (!imageStarted.isCompleted) imageStarted.complete();
    await pendingImage?.future;
  }

  @override
  Future<Res<bool>> dailyChk({bool allowReLogin = true}) async {
    checkins++;
    checkinRelogin = allowReLogin;
    if (!checkinStarted.isCompleted) checkinStarted.complete();
    return const Res.error('Optional check-in unavailable');
  }
}

String encryptResponse(Map<String, dynamic> body, String time) {
  final bytes = utf8.encode(jsonEncode(body));
  final padding = 16 - bytes.length % 16;
  final input =
      Uint8List.fromList([...bytes, ...List.filled(padding, padding)]);
  final key = utf8.encode(
      md5.convert(utf8.encode('$time${JmNetwork.kJmSecret}')).toString());
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(key)));
  final encrypted = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += 16) {
    cipher.processBlock(input, offset, encrypted, offset);
  }
  return base64Encode(encrypted);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> settings;
  late Map<String, dynamic> data;
  late JmNetwork originalNetwork;
  late List<ComicSource> sources;

  setUpAll(() {
    App.dataPath =
        Directory.systemTemp.createTempSync('pica-jm-login-test-').path;
  });

  setUp(() {
    settings = List.from(appdata.settings);
    data = Map.from(jm.data);
    sources = List.from(ComicSource.sources);
    originalNetwork = jmNetwork;
    SharedPreferences.setMockInitialValues({});
    appdata.settings[8] = '';
    appdata.settings[15] = '1';
    appdata.settings[17] = '0';
    appdata.settings[58] = '0';
    appdata.settings[88] = '0';
    appdata.appSettings.jmApiDomains = ['one.example', 'two.example'];
    jm.data.clear();
  });
  tearDown(() {
    appdata.settings = settings;
    jm.data = data;
    ComicSource.sources = sources;
    jmNetwork = originalNetwork;
  });

  test('empty and fully failed line races finish with no winner', () async {
    expect(await selectJmDomain([], (_) async => true), isNull);
    expect(await selectJmDomain(['a', 'b'], (_) async => false), isNull);
    expect(await selectJmDomain(['a', 'b'], (_) => throw StateError('offline')),
        isNull);
  });

  testWidgets('unresponsive probes time out and late successes cannot win',
      (tester) async {
    final stalled = Completer<bool>();
    var done = false;
    int? result;
    selectJmDomain(['a'], (_) => stalled.future,
            timeout: const Duration(seconds: 2))
        .then((value) {
      done = true;
      result = value;
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(done, isTrue);
    expect(result, isNull);
    stalled.complete(true);
    await tester.pump();
    expect(result, isNull);
  });

  test('fastest available line wins while other probes can fail later',
      () async {
    final slow = Completer<bool>();
    expect(
        await selectJmDomain(['slow', 'fast'],
            (host) => host == 'slow' ? slow.future : Future.value(true)),
        1);
    slow.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
  });

  test('real line selection rejects HTML and accepts the API error envelope',
      () async {
    final network = JmNetwork.create(
        dioFactory: (options) => Dio(options)
          ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
            expect(
                o.data, '&'); // Never send credentials during line selection.
            expect(o.receiveTimeout, isNotNull);
            final content = o.uri.host == 'one.example'
                ? '<html>Proxy</html>'
                : '{"errorMsg":"Missing username"}';
            h.resolve(Response(
                requestOptions: o,
                statusCode: 401,
                data: utf8.encode(content)));
          })));
    expect(await network.selectDomain(), 1);
  });

  test('no available line returns an error without sending credentials',
      () async {
    final network = LoginNetwork()..selected = null;
    final res = await network.login('sample', 'dummy');
    expect(res.error, isTrue);
    expect(network.posts, 0);
    expect(network.images, 0);
    expect(network.checkins, 0);
  });

  test('failed login skips optional requests and releases login lock',
      () async {
    final network = LoginNetwork();
    appdata.settings[88] = '1';
    expect((await network.login('sample', 'dummy')).error, isTrue);
    expect((await network.login('sample', 'dummy')).error, isTrue);
    expect(network.posts, 2);
    expect(network.images, 0);
    expect(network.checkins, 0);
  });

  test('selection exception is reported and a later attempt can run', () async {
    final network = LoginNetwork()..throwSelection = true;
    expect((await network.login('sample', 'dummy')).error, isTrue);
    network.throwSelection = false;
    await network.login('sample', 'dummy');
    expect(network.posts, 1);
  });

  test(
      'successful authentication finishes before image setup and skips re-login',
      () async {
    final network = LoginNetwork()
      ..response = const Res({'username': 'sample', 'uid': '42'})
      ..pendingImage = Completer<void>();
    appdata.settings[88] = '1';
    final result = await network
        .login('sample', 'dummy')
        .timeout(const Duration(seconds: 1));
    expect(result.success, isTrue);
    await network.imageStarted.future.timeout(const Duration(seconds: 5));
    expect(network.images, 1);
    expect(network.imageRelogin, isFalse);
    expect(network.checkins, 0);
    network.pendingImage!.complete();
    await network.checkinStarted.future.timeout(const Duration(seconds: 5));
    expect(network.checkins, 1);
    expect(network.checkinRelogin, isFalse);
  });

  test('parallel login does not post a second set of credentials', () async {
    final pending = Completer<Res<dynamic>>();
    final network = LoginNetwork()..pendingPost = pending.future;
    final first = network.login('one', 'dummy');
    await Future<void>.delayed(Duration.zero);
    expect((await network.login('two', 'dummy')).error, isTrue);
    expect(network.posts, 1);
    pending.complete(const Res.error('Offline'));
    expect((await first).error, isTrue);
  });

  test('malformed success is not accepted as a logged-in account', () async {
    final network = LoginNetwork()
      ..response = const Res({'message': 'unexpected'});
    expect((await network.login('sample', 'dummy')).error, isTrue);
    expect(network.images, 0);
    expect(jm.data['name'], isNull);
  });

  test('logout while a login is pending rejects the late result', () async {
    final pending = Completer<Res<dynamic>>();
    final network = LoginNetwork()..pendingPost = pending.future;
    final result = network.login('sample', 'dummy');
    await Future<void>.delayed(Duration.zero);
    await network.logout();
    pending.complete(const Res({'username': 'sample', 'uid': '42'}));
    expect((await result).error, isTrue);
    expect(jm.data['name'], isNull);
    expect(network.images, 0);
  });

  test('server rejection reports the login error and stores no session',
      () async {
    final network = JmNetwork.create(
        dioFactory: (options) => Dio(options)
          ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
            h.resolve(Response(
                requestOptions: o,
                statusCode: 401,
                data: utf8.encode('{"errorMsg":"Incorrect credentials"}')));
          })));
    final result = await network.post(
        'https://one.example/login', 'username=sample&password=dummy');
    expect(result.errorMessage, 'Incorrect credentials');
    expect(
        await network.cookieJar
            .loadForRequest(Uri.parse('https://one.example/')),
        isEmpty);
  });

  test('failed credentials cannot overwrite the stored account', () async {
    jm.data['account'] = ['existing', 'stored-dummy'];
    jmNetwork = LoginNetwork();
    ComicSource.sources = [jm];
    expect((await jm.account!.login!('new', 'wrong-dummy')).error, isTrue);
    expect(jm.data['account'], ['existing', 'stored-dummy']);
  });

  for (final inPayload in [true, false]) {
    test(
        'login preserves session from ${inPayload ? 'decrypted data' : 'envelope'}',
        () async {
      final network = JmNetwork.create(
          dioFactory: (options) => Dio(options)
            ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
              final time = (o.headers['tokenparam'] as String).split(',').first;
              final body = {
                'username': 'sample',
                'uid': '42',
                if (inPayload) 's': 'synthetic-session'
              };
              h.resolve(Response(
                  requestOptions: o,
                  statusCode: 200,
                  data: utf8.encode(jsonEncode({
                    'data': encryptResponse(body, time),
                    if (!inPayload) 's': 'synthetic-session'
                  }))));
            })));
      final result = await network.post(
          'https://one.example/login', 'username=sample&password=dummy');
      expect(result.success, isTrue);
      final cookies = await network.cookieJar
          .loadForRequest(Uri.parse('https://one.example/favorite'));
      expect(cookies.singleWhere((cookie) => cookie.name == 'AVS').value,
          'synthetic-session');
    });
  }

  testWidgets('stalled login request is cancelled and returns a timeout error',
      (tester) async {
    CancelToken? token;
    final network = JmNetwork.create(
        dioFactory: (options) => Dio(options)
          ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
            token = o.cancelToken;
          })));
    Res<dynamic>? result;
    network
        .post('https://one.example/login', 'username=sample&password=dummy')
        .then((r) => result = r);
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    expect(result?.error, isTrue);
    expect(result?.errorMessage, contains('超时'));
    expect(token?.isCancelled, isTrue);
  });
}
