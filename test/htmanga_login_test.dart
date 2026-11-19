import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/htmanga_network/web_login.dart';

import 'support/fake_http.dart';

// The site asks for a slider puzzle at login, so the app opens its login
// page and keeps the cookies once an account page is served with them.
void main() {
  final http = useFakeHttp();

  const loggedOut = '<div class="title title_c">您沒有權限，需要登錄！  </div>'
      '<a onclick="Mui.box.show(\'/users-login.html\')">點擊這裡登錄</a>';
  const loggedIn = '<div class="title title_c">我的書架</div>'
      '<a href="/users-fav_del-id-1.html">刪除</a>';

  test('an account page tells a visitor from a logged-in user', () {
    expect(htLoggedIn(loggedOut), isFalse);
    expect(htLoggedIn(loggedIn), isTrue);
  });

  test('the saved session is checked against the bookshelf', () async {
    http.text('users-users_fav.html', loggedOut);
    expect(await HtmangaNetwork().checkLogin(), isFalse);
    http.text('users-users_fav.html', loggedIn);
    expect(await HtmangaNetwork().checkLogin(), isTrue);
    expect(http.urls.last, 'https://www.wnacg.com/users-users_fav.html');
  });

  group('the login page', () {
    late List<Map<String, String>> saved;
    late bool session;
    late int checks;
    late HtWebLoginFlow flow;

    setUp(() {
      saved = [];
      session = false;
      checks = 0;
      flow = HtWebLoginFlow(
        saveCookies: saved.add,
        verify: () async {
          checks++;
          return session;
        },
      );
    });

    test('is checked again only when its cookies change', () async {
      expect(await flow.probe({}), isFalse);
      expect(checks, 0);

      expect(await flow.probe({'PHPSESSID': 'a'}), isFalse);
      expect(await flow.probe({'PHPSESSID': 'a'}), isFalse);
      expect(checks, 1);

      session = true;
      expect(await flow.probe({'PHPSESSID': 'a', 'remember': 'x'}), isTrue);
      expect(checks, 2);
      expect(saved.last, {'PHPSESSID': 'a', 'remember': 'x'});
      expect(flow.done, isTrue);

      // Done: nothing more is checked.
      expect(await flow.probe({'PHPSESSID': 'b'}), isTrue);
      expect(checks, 2);
    });

    test('a navigation checks the same cookies again', () async {
      // The server may log the same session in without a new cookie.
      expect(await flow.probe({'PHPSESSID': 'a'}), isFalse);
      session = true;
      expect(await flow.probe({'PHPSESSID': 'a'}), isFalse);
      expect(await flow.probe({'PHPSESSID': 'a'}, force: true), isTrue);
      expect(checks, 2);
    });
  });
}
