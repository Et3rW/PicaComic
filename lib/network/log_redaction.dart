import 'dart:convert';

bool _sensitive(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return normalized.contains('token') ||
      normalized.contains('cookie') ||
      normalized.contains('authorization') ||
      normalized.contains('password') ||
      normalized.contains('secret') ||
      normalized.contains('apikey') ||
      normalized == 'sessionid';
}

dynamic _redact(dynamic value) {
  if (value is Map) {
    return value.map(
      (key, item) =>
          MapEntry('$key', _sensitive('$key') ? '[REDACTED]' : _redact(item)),
    );
  }
  if (value is List) return value.map(_redact).toList();
  return value;
}

Map<String, dynamic> networkLogHeaders(Map<String, dynamic> headers) =>
    Map<String, dynamic>.from(_redact(headers) as Map);

String networkLogUrl(Uri uri) {
  if (!uri.hasQuery && uri.userInfo.isEmpty) return uri.toString();
  return uri
      .replace(
        userInfo: '',
        queryParameters: uri.hasQuery
            ? {
                for (final entry in uri.queryParametersAll.entries)
                  entry.key: _sensitive(entry.key)
                      ? ['[REDACTED]']
                      : entry.value,
              }
            : null,
      )
      .toString();
}

String networkLogBody(dynamic body, {bool authenticated = false}) {
  if (body == null) return '<empty>';
  if (authenticated) return '<authenticated body omitted>';
  if (body is List<int>) return '<bytes: ${body.length}>';
  if (body is String) {
    try {
      body = jsonDecode(body);
    } catch (_) {
      // HTML, form strings and JS can embed credentials in arbitrary positions.
      return '<non-JSON body omitted>';
    }
  }
  if (body is! Map && body is! List) return '<body omitted>';
  return jsonEncode(_redact(body));
}

bool isAuthenticatedLogRequest(Uri uri, Map<String, dynamic> headers) =>
    headers.keys.any(_sensitive) ||
    RegExp(r'/(auth|login|signin|register)(/|$)').hasMatch(uri.path);
