import 'dart:async';
import 'dart:io' as io;

import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show InAppWebViewController;
import 'package:pica_comic/pages/webview.dart';
import 'package:pica_comic/tools/translations.dart';

import 'htmanga_main_network.dart';

/// Whether an account page of the site was served to a logged-in user. A
/// visitor gets "您沒有權限，需要登錄".
bool htLoggedIn(String html) =>
    !html.contains('需要登錄') && !html.contains('需要登录');

/// Decides when the cookies of the login page belong to a logged-in user.
///
/// The site asks for a slider puzzle that only its own page can show, so the
/// user logs in there. Every time the cookies change, or the page moves on,
/// they are copied to the app and checked against an account page.
class HtWebLoginFlow {
  HtWebLoginFlow({required this.saveCookies, required this.verify});

  final void Function(Map<String, String> cookies) saveCookies;

  /// Whether the cookies saved so far are a logged-in session.
  final Future<bool> Function() verify;

  String? _checked;
  var _busy = false;
  var _done = false;

  bool get done => _done;

  /// Checks [cookies] when they differ from the ones checked last, or with
  /// [force] (the page navigated: a session cookie may stay the same while
  /// the server logs it in). Returns whether the user is logged in.
  Future<bool> probe(Map<String, String> cookies, {bool force = false}) async {
    if (_done || _busy || cookies.isEmpty) return _done;
    var signature = (cookies.keys.toList()..sort())
        .map((name) => '$name=${cookies[name]}')
        .join(';');
    if (!force && signature == _checked) return false;
    _busy = true;
    try {
      saveCookies(cookies);
      _checked = signature;
      _done = await verify();
    } finally {
      _busy = false;
    }
    return _done;
  }
}

/// Copies the login page's cookies into the app's cookie jar.
void _saveCookies(Map<String, String> cookies) {
  var cookieList = <io.Cookie>[];
  for (var entry in cookies.entries) {
    try {
      cookieList.add(io.Cookie(entry.key, entry.value)..path = '/');
    } catch (_) {
      // A value the HTTP client cannot send is of no use to it either.
    }
  }
  SingleInstanceCookieJar.instance!
      .saveFromResponse(Uri.parse(HtmangaNetwork.baseUrl), cookieList);
}

/// Opens the site's login page. Returns whether the user logged in.
Future<bool> htWebLogin() async {
  var flow = HtWebLoginFlow(
    saveCookies: _saveCookies,
    verify: () => HtmangaNetwork().checkLogin(),
  );
  var result = Completer<bool>();
  Timer? timer;
  void finish() {
    timer?.cancel();
    if (!result.isCompleted) result.complete(flow.done);
  }

  var loginUrl = '${HtmangaNetwork.baseUrl}/users-login.html';
  var siteUrl = '${HtmangaNetwork.baseUrl}/';

  Future<void> check(Future<Map<String, String>?> Function() readCookies,
      void Function() close, bool force) async {
    try {
      if (await flow.probe(await readCookies() ?? {}, force: force)) {
        close();
        finish();
      }
    } catch (e) {
      // Never log cookie values.
      LogManager.addLog(LogLevel.warning, 'htmanga login',
          'check failed: ${e.runtimeType}');
    }
  }

  try {
    if (App.isDesktop && await DesktopWebview.isAvailable()) {
      late DesktopWebview webview;
      Future<void> run(bool force) =>
          check(() => webview.getCookies(siteUrl), webview.close, force);
      webview = DesktopWebview(
        initialUrl: loginUrl,
        onNavigation: (_, __) => run(true),
        onTitleChange: (_, __) => run(true),
        onClose: finish,
      );
      timer = Timer.periodic(
          const Duration(seconds: 1), (_) => run(false));
      await webview.open();
    } else if (App.isMobile) {
      InAppWebViewController? controller;
      Future<void> run(bool force) async {
        var c = controller;
        if (c == null) return;
        await check(() => c.getCookies(siteUrl), () => App.globalBack(), force);
      }

      App.globalTo(
        () => AppWebview(
          initialUrl: loginUrl,
          singlePage: true,
          onStarted: (c) => controller = c,
          onTitleChange: (_, __) => run(true),
          onNavigation: (_) {
            run(true);
            return false;
          },
          onClose: finish,
        ),
      );
      timer = Timer.periodic(
          const Duration(seconds: 1), (_) => run(false));
    } else {
      showToast(message: '当前设备不支持'.tl);
      finish();
    }
  } catch (e) {
    LogManager.addLog(LogLevel.warning, 'htmanga login',
        'Unable to open login window: ${e.runtimeType}');
    finish();
  }
  return result.future;
}
