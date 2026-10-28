import 'dart:async';
import 'dart:io' as io;

import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/pages/webview.dart';
import 'package:pica_comic/tools/translations.dart';
import 'login_flow.dart';

/// Opens nhentai's SPA login page and detects credentials exposed through
/// either the native cookie store or browser storage.
Future<bool> nhLogin() async {
  final flow = NhentaiLoginFlow();
  Timer? timer;

  void stop() {
    timer?.cancel();
    flow.cancel();
  }

  Future<void> tryComplete({
    required Future<Map<String, String>?> Function() getCookies,
    required Future<dynamic> Function() evaluateJavascript,
    required Future<String?> Function() getUA,
    required void Function() close,
    required String reason,
  }) async {
    try {
      await flow.probe(
        readCookies: () async => await getCookies() ?? {},
        readStorage: () async {
          try {
            return decodeNhentaiStorage(await evaluateJavascript());
          } catch (_) {
            return <String, String>{};
          }
        },
        readUserAgent: getUA,
        persist: (cookies, ua) {
          if (ua != null && ua.isNotEmpty) {
            appdata.implicitData[3] = ua;
            appdata.writeImplicitData();
          }
          final persistable = <io.Cookie>[
            for (final entry in cookies.entries)
              if (entry.value.isNotEmpty &&
                  (entry.key != 'cf_clearance' || (ua?.isNotEmpty ?? false)))
                io.Cookie(entry.key, entry.value)
                  ..domain = '.nhentai.net'
                  ..path = '/',
          ];
          NhentaiNetwork().cookieJar!.saveFromResponse(
            Uri.parse(NhentaiNetwork().baseUrl),
            persistable,
          );
          NhentaiNetwork().logged = true;
          timer?.cancel();
        },
        close: close,
      );
    } catch (e) {
      // Never include cookie values or JS/storage results in logs.
      LogManager.addLog(
        LogLevel.warning,
        'nhentai login probe',
        '$reason failed: ${e.runtimeType}',
      );
    }
  }

  void poll(Future<void> Function(String reason) check) {
    timer = Timer.periodic(const Duration(milliseconds: 800), (current) {
      if (!flow.active) {
        current.cancel();
      } else {
        check('timer');
      }
    });
  }

  try {
    if (App.isDesktop && await DesktopWebview.isAvailable()) {
      late DesktopWebview webview;
      Future<void> check(String reason) => tryComplete(
        getCookies: () => webview.getCookies('${NhentaiNetwork().baseUrl}/'),
        evaluateJavascript: () => webview.evaluateJavascript(
          '''(() => { try { const entries = {}; for (const cookie of document.cookie.split(';')) { const i = cookie.indexOf('='); if (i > 0) entries[cookie.substring(0,i).trim()] = cookie.substring(i+1).trim(); } for (const storage of [localStorage, sessionStorage]) for (let i=0;i<storage.length;i++) { const key=storage.key(i); if(key) entries[key]=storage.getItem(key)||''; } return JSON.stringify(entries); } catch (_) { return '{}'; } })();''',
        ),
        getUA: () async => webview.userAgent,
        close: webview.close,
        reason: reason,
      );
      webview = DesktopWebview(
        initialUrl: '${NhentaiNetwork().baseUrl}/login/?next=/',
        onNavigation: (url, _) {
          if (!url.contains('/login')) check('navigation');
        },
        onTitleChange: (_, __) => check('title'),
        onClose: stop,
      );
      poll(check);
      await webview.open();
    } else if (App.isMobile) {
      Future<void> Function(String reason)? check;
      final route = App.globalTo(
        () => AppWebview(
          initialUrl: '${NhentaiNetwork().baseUrl}/login/?next=/',
          singlePage: true,
          onStarted: (controller) {
            check = (reason) => tryComplete(
              getCookies: () =>
                  controller.getCookies('${NhentaiNetwork().baseUrl}/'),
              evaluateJavascript: () => controller.evaluateJavascript(
                source:
                    '''(() => { try { const entries = {}; for (const cookie of document.cookie.split(';')) { const i = cookie.indexOf('='); if (i > 0) entries[cookie.substring(0,i).trim()] = cookie.substring(i+1).trim(); } for (const storage of [localStorage, sessionStorage]) for (let i=0;i<storage.length;i++) { const key=storage.key(i); if(key) entries[key]=storage.getItem(key)||''; } return JSON.stringify(entries); } catch (_) { return '{}'; } })();''',
              ),
              getUA: controller.getUA,
              close: () => App.globalBack(),
              reason: reason,
            );
          },
          onNavigation: (url) {
            if (!url.contains('/login')) check?.call('navigation');
            return false;
          },
          onClose: stop,
        ),
      );
      route.whenComplete(stop);
      poll((reason) async => check?.call(reason));
    } else {
      stop();
      showToast(message: '\u5f53\u524d\u8bbe\u5907\u4e0d\u652f\u6301'.tl);
    }
  } catch (e) {
    stop();
    LogManager.addLog(
      LogLevel.warning,
      'nhentai login',
      'Unable to open login window: ${e.runtimeType}',
    );
  }
  return flow.result;
}
