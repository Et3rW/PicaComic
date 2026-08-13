import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/pages/webview.dart';
import 'package:pica_comic/tools/translations.dart';

/// Opens nhentai's SPA login page and detects credentials exposed through
/// either the native cookie store or browser storage.
void nhLogin(void Function() onFinished) async {
  var active = true;
  var completed = false;
  Timer? timer;

  void stop() {
    active = false;
    timer?.cancel();
  }

  bool isCredential(String key, String value) =>
      value.isNotEmpty && (key.toLowerCase() == 'sessionid' ||
          key.toLowerCase().contains('session') || key.toLowerCase().contains('token'));

  Future<Map<String, String>> storageCredentials(
      Future<dynamic> Function() evaluateJavascript) async {
    try {
      final result = await evaluateJavascript();
      if (result is! String || result.isEmpty) return {};
      dynamic decoded = jsonDecode(result);
      // flutter_inappwebview returns a JSON-encoded JS string on some platforms.
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is! Map) return {};
      return decoded.map((key, value) => MapEntry('$key', '$value'));
    } catch (_) {
      return {};
    }
  }

  Future<void> tryComplete({
    required Future<Map<String, String>?> Function() getCookies,
    required Future<dynamic> Function() evaluateJavascript,
    required Future<String?> Function() getUA,
    required void Function() close,
    required String reason,
  }) async {
    if (!active || completed) return;
    try {
      final cookies = await getCookies() ?? {};
      final storage = await storageCredentials(evaluateJavascript);
      final cookieKeys = cookies.keys.join(',');
      final storageKeys = storage.keys.join(',');
      final hasCookieCredential = cookies.entries.any((entry) => isCredential(entry.key, entry.value));
      MapEntry<String, String>? storageCredential;
      for (final entry in storage.entries) {
        if (isCredential(entry.key, entry.value)) {
          storageCredential = entry;
          break;
        }
      }
      LogManager.addLog(LogLevel.info, 'nhentai login probe',
          '$reason cookies=[$cookieKeys] storageKeys=[$storageKeys] credential=${hasCookieCredential || storageCredential != null}');
      if (!hasCookieCredential && storageCredential == null) return;

      if (storageCredential != null && !hasCookieCredential) {
        LogManager.addLog(LogLevel.warning, 'nhentai login',
            'Credential found only in browser storage: ${storageCredential.key}');
      }
      completed = true;
      final ua = await getUA();
      if (ua != null && ua.isNotEmpty) {
        appdata.implicitData[3] = ua;
        appdata.writeImplicitData();
      }
      final persistable = <io.Cookie>[];
      cookies.forEach((key, value) {
        if (key != 'cf_clearance') persistable.add(io.Cookie(key, value)..domain = '.nhentai.net');
      });
      NhentaiNetwork().cookieJar!.saveFromResponse(
          Uri.parse(NhentaiNetwork().baseUrl), persistable);
      NhentaiNetwork().logged = true;
      stop();
      onFinished();
      close();
    } catch (e) {
      LogManager.addLog(LogLevel.warning, 'nhentai login probe', '$reason failed: $e');
    }
  }

  void poll(Future<void> Function(String reason) check) {
    timer = Timer.periodic(const Duration(milliseconds: 800), (current) {
      if (!active || completed) {
        current.cancel();
      } else {
        check('timer');
      }
    });
  }

  if (App.isDesktop && await DesktopWebview.isAvailable()) {
    late DesktopWebview webview;
    Future<void> check(String reason) => tryComplete(
      getCookies: () => webview.getCookies('${NhentaiNetwork().baseUrl}/'),
      evaluateJavascript: () => webview.evaluateJavascript('''(() => { try { const entries = {}; for (const cookie of document.cookie.split(';')) { const i = cookie.indexOf('='); if (i > 0) entries[cookie.substring(0,i).trim()] = cookie.substring(i+1).trim(); } for (const storage of [localStorage, sessionStorage]) for (let i=0;i<storage.length;i++) { const key=storage.key(i); if(key) entries[key]=storage.getItem(key)||''; } return JSON.stringify(entries); } catch (_) { return '{}'; } })();'''),
      getUA: () async => webview.userAgent,
      close: webview.close,
      reason: reason,
    );
    webview = DesktopWebview(
      initialUrl: '${NhentaiNetwork().baseUrl}/login/?next=/',
      onNavigation: (url, _) { if (!url.contains('/login')) check('navigation'); },
      onTitleChange: (_, __) => check('title'),
      onClose: stop,
    );
    poll(check);
    webview.open();
  } else if (App.isMobile) {
    Future<void> Function(String reason)? check;
    App.globalTo(() => AppWebview(
      initialUrl: '${NhentaiNetwork().baseUrl}/login/?next=/',
      singlePage: true,
      onStarted: (controller) {
        check = (reason) => tryComplete(
          getCookies: () => controller.getCookies('${NhentaiNetwork().baseUrl}/'),
          evaluateJavascript: () => controller.evaluateJavascript(source: '''(() => { try { const entries = {}; for (const cookie of document.cookie.split(';')) { const i = cookie.indexOf('='); if (i > 0) entries[cookie.substring(0,i).trim()] = cookie.substring(i+1).trim(); } for (const storage of [localStorage, sessionStorage]) for (let i=0;i<storage.length;i++) { const key=storage.key(i); if(key) entries[key]=storage.getItem(key)||''; } return JSON.stringify(entries); } catch (_) { return '{}'; } })();'''),
          getUA: controller.getUA,
          close: () => App.globalBack(),
          reason: reason,
        );
      },
      onNavigation: (url) { if (!url.contains('/login')) check?.call('navigation'); return false; },
      onClose: stop,
    ));
    poll((reason) async => check?.call(reason));
  } else {
    stop();
    showToast(message: '\u5f53\u524d\u8bbe\u5907\u4e0d\u652f\u6301'.tl);
  }
}
