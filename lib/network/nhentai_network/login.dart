import 'dart:async';
import 'dart:io' as io;

import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/pages/webview.dart';
import 'package:pica_comic/tools/translations.dart';

/// 登录 nhentai。
///
/// 完成检测**不再依赖页面标题**。nhentai 已改为 Svelte SPA:
/// - 登录页标题就是 "nhentai"(不含 Login/Register),旧逻辑会在打开页面
///   的瞬间(桌面端每 2 秒轮询一次标题)误判为"已登录完成",在用户真正
///   登录前就保存空 cookie 并关闭流程;
/// - 登录成功后跳转的主页标题与登录页相同,基于"标题变化"的检测又
///   根本不会触发。
///
/// 新逻辑:轮询 webview 的 cookie,**只要出现 sessionid**(唯一可信的登录
/// 凭据)即视为登录成功,保存 cookie 并结束流程。
void nhLogin(void Function() onFinished) async {
  var active = true; // webview 关闭(无论成败)后置 false
  var completed = false;
  Timer? timer;

  void stop() {
    active = false;
    timer?.cancel();
  }

  /// 尝试完成登录:读取 cookie,若存在 sessionid 则保存并收尾。
  Future<void> tryComplete({
    required Future<Map<String, String>?> Function() getCookies,
    required Future<String?> Function() getUA,
    required void Function() close,
  }) async {
    if (!active || completed) {
      return;
    }
    Map<String, String>? cookies;
    try {
      cookies = await getCookies();
    } catch (_) {
      // webview 已销毁等情况,忽略
      return;
    }
    if (cookies == null || !cookies.containsKey("sessionid")) {
      return;
    }
    completed = true;
    final ua = await getUA();
    if (ua != null && ua.isNotEmpty) {
      appdata.implicitData[3] = ua;
      appdata.writeImplicitData();
    }
    final cookiesList = <io.Cookie>[];
    cookies.forEach((key, value) {
      final cookie = io.Cookie(key, value)..domain = ".nhentai.net";
      if (key != "cf_clearance") {
        // cf_clearance 与 User-Agent 绑定,保存后会导致其他请求被 CF 拒绝
        cookiesList.add(cookie);
      }
    });
    NhentaiNetwork()
        .cookieJar!
        .saveFromResponse(Uri.parse(NhentaiNetwork().baseUrl), cookiesList);
    NhentaiNetwork().logged = true;
    stop();
    onFinished();
    close();
  }

  void startPolling(Future<void> Function() check) {
    timer = Timer.periodic(const Duration(milliseconds: 800), (t) {
      if (!active || completed) {
        t.cancel();
        return;
      }
      check();
    });
  }

  if (App.isDesktop && (await DesktopWebview.isAvailable())) {
    var webview = DesktopWebview(
      initialUrl: "${NhentaiNetwork().baseUrl}/login/?next=/",
      onTitleChange: (title, controller) async {
        // 桌面端标题每 2 秒轮询一次,这里只作为触发点,真正判据是 cookie
        await tryComplete(
          getCookies: () =>
              controller.getCookies("${NhentaiNetwork().baseUrl}/"),
          getUA: () async => controller.userAgent,
          close: controller.close,
        );
      },
      onClose: stop,
    );
    startPolling(() async {
      await tryComplete(
        getCookies: () => webview.getCookies("${NhentaiNetwork().baseUrl}/"),
        getUA: () async => webview.userAgent,
        close: webview.close,
      );
    });
    webview.open();
  } else if (App.isMobile) {
    Future<void> Function()? mobileCheck;
    App.globalTo(() => AppWebview(
          initialUrl: "${NhentaiNetwork().baseUrl}/login/?next=/",
          singlePage: true,
          onStarted: (c) {
            mobileCheck = () => tryComplete(
                  getCookies: () =>
                      c.getCookies("${NhentaiNetwork().baseUrl}/"),
                  getUA: () => c.getUA(),
                  close: () => App.globalBack(),
                );
          },
          onTitleChange: (title, c) async {
            await tryComplete(
              getCookies: () => c.getCookies("${NhentaiNetwork().baseUrl}/"),
              getUA: () => c.getUA(),
              close: () => App.globalBack(),
            );
          },
        ));
    startPolling(() async => mobileCheck?.call());
  } else {
    showToast(message: "当前设备不支持".tl);
  }
}
