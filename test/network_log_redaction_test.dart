import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/log_redaction.dart';

void main() {
  test(
    'headers redact credentials case-insensitively without altering request',
    () {
      final headers = <String, dynamic>{
        'Authorization': 'dummy-auth',
        'Cookie': 'dummy-cookie',
        'Set-Cookie': ['dummy-set-cookie'],
        'X-CSRFToken': 'dummy-csrf',
        'Accept': 'application/json',
      };
      final logged = networkLogHeaders(headers);
      expect(logged['Authorization'], '[REDACTED]');
      expect(logged['Cookie'], '[REDACTED]');
      expect(logged['Set-Cookie'], '[REDACTED]');
      expect(logged['X-CSRFToken'], '[REDACTED]');
      expect(logged['Accept'], 'application/json');
      expect(headers['Authorization'], 'dummy-auth');
    },
  );
  test('JSON auth values and opaque bodies are not logged', () {
    final text = networkLogBody({
      'data': {'access_token': 'dummy-secret', 'password': 'dummy-password'},
      'status': 'ok',
    });
    expect(text, isNot(contains('dummy-secret')));
    expect(text, isNot(contains('dummy-password')));
    expect(text, contains('ok'));
    expect(
      networkLogBody('<html>dummy-secret</html>'),
      isNot(contains('dummy-secret')),
    );
    expect(
      networkLogBody({'data': 'dummy-secret'}, authenticated: true),
      isNot(contains('dummy-secret')),
    );
  });
  test('URL credentials are removed and repeated search values survive', () {
    final url = networkLogUrl(
      Uri.parse(
        'https://user:dummy@example.com/auth?'
        'access_token=dummy-secret&q=a&q=b',
      ),
    );
    expect(url, isNot(contains('dummy')));
    expect(Uri.parse(url).queryParametersAll['q'], ['a', 'b']);
  });
}
