import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/cookie_jar.dart';

void main() {
  late CookieJarSql jar;
  final site = Uri.parse('https://nhentai.net');
  setUp(() => jar = CookieJarSql(':memory:'));
  tearDown(() => jar.dispose());

  test('deleting at a host-only URL removes root-path cookie', () {
    jar.saveFromResponse(site, [Cookie('sessionid', 'dummy')]);
    jar.delete(site, 'sessionid');
    expect(jar.loadForRequest(site), isEmpty);
  });

  test(
    'logout clears auth at all paths and keeps clearance and other sites',
    () {
      jar.saveFromResponse(site, [
        Cookie('access_token', 'dummy')..domain = '.nhentai.net',
        Cookie('refresh_token', 'dummy')
          ..domain = '.nhentai.net'
          ..path = '/auth',
        Cookie('sessionid', 'dummy'),
        Cookie('cf_clearance', 'dummy'),
      ]);
      final other = Uri.parse('https://example.com');
      jar.saveFromResponse(other, [Cookie('access_token', 'other')]);
      for (final name in ['sessionid', 'access_token', 'refresh_token']) {
        jar.deleteNamed(site, name);
      }
      expect(jar.loadForRequest(site.resolve('/auth')).map((c) => c.name), [
        'cf_clearance',
      ]);
      expect(jar.loadForRequest(other).single.value, 'other');
    },
  );
}
