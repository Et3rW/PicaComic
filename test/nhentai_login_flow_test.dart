import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/nhentai_network/login_flow.dart';

void main() {
  test('CSRF, refresh-only and session preferences are not a login', () {
    for (final values in [
      {'csrftoken': 'dummy'},
      {'session_preference': 'dummy'},
      {'refresh_token': 'dummy'},
      {'access_token': ''},
      {'access_token': 'null'},
      {'access_token': 'undefined'},
    ]) {
      expect(hasNhentaiSession(values), isFalse);
    }
    expect(hasNhentaiSession({'access_token': 'dummy'}), isTrue);
    expect(hasNhentaiSession({'sessionid': 'dummy'}), isTrue);
  });

  test(
    'native and double-encoded JS strings decode without inventing values',
    () {
      final payload = jsonEncode({'access_token': 'dummy', 'sessionid': null});
      expect(decodeNhentaiStorage(jsonEncode(payload)), {
        'access_token': 'dummy',
      });
      expect(decodeNhentaiStorage(payload), {'access_token': 'dummy'});
      expect(decodeNhentaiStorage('bad json'), isEmpty);
    },
  );

  test(
    'storage credentials are persisted along with clearance and refresh',
    () async {
      final flow = NhentaiLoginFlow();
      Map<String, String>? saved;
      var closes = 0;
      await flow.probe(
        readCookies: () async => {'cf_clearance': 'dummy-clearance'},
        readStorage: () async => {
          'access_token': 'dummy-access',
          'refresh_token': 'dummy-refresh',
          'irrelevant': 'ignored',
        },
        readUserAgent: () async => 'test-agent',
        persist: (cookies, ua) {
          saved = cookies;
          expect(ua, 'test-agent');
        },
        close: () => closes++,
      );
      expect(await flow.result, isTrue);
      expect(saved, {
        'cf_clearance': 'dummy-clearance',
        'access_token': 'dummy-access',
        'refresh_token': 'dummy-refresh',
      });
      expect(closes, 1);
    },
  );

  test(
    'cancelling during an async probe cannot persist or pop another page',
    () async {
      final flow = NhentaiLoginFlow();
      final cookies = Completer<Map<String, String>>();
      final probe = flow.probe(
        readCookies: () => cookies.future,
        readStorage: () async => {},
        readUserAgent: () async => 'test-agent',
        persist: (_, __) => fail('persisted after cancellation'),
        close: () => fail('closed after cancellation'),
      );
      flow.cancel();
      expect(await flow.result, isFalse);
      cookies.complete({'access_token': 'dummy'});
      await probe;
    },
  );

  test(
    'concurrent probes only save and close once; native credential wins',
    () async {
      final flow = NhentaiLoginFlow();
      final cookies = Completer<Map<String, String>>();
      var saves = 0;
      var closes = 0;
      Future<void> probe() => flow.probe(
        readCookies: () => cookies.future,
        readStorage: () async => {'access_token': 'stale-storage'},
        readUserAgent: () async => 'test-agent',
        persist: (values, _) {
          saves++;
          expect(values['access_token'], 'native');
        },
        close: () => closes++,
      );
      final first = probe();
      await probe();
      cookies.complete({'access_token': 'native'});
      await first;
      await probe();
      flow.cancel();
      expect(await flow.result, isTrue);
      expect(saves, 1);
      expect(closes, 1);
    },
  );

  test('a transient read failure allows the next probe to succeed', () async {
    final flow = NhentaiLoginFlow();
    await expectLater(
      flow.probe(
        readCookies: () async => throw StateError('not ready'),
        readStorage: () async => {},
        readUserAgent: () async => null,
        persist: (_, __) {},
        close: () {},
      ),
      throwsStateError,
    );
    await flow.probe(
      readCookies: () async => {'sessionid': 'dummy'},
      readStorage: () async => {},
      readUserAgent: () async => null,
      persist: (_, __) {},
      close: () {},
    );
    expect(await flow.result, isTrue);
  });
}
