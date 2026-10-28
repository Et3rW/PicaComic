import 'dart:async';
import 'dart:convert';

const nhentaiAuthCookieNames = {'sessionid', 'access_token', 'refresh_token'};

bool hasNhentaiSession(Map<String, String> values) =>
    ['sessionid', 'access_token'].any(
      (name) =>
          values[name]?.trim().isNotEmpty == true &&
          values[name] != 'null' &&
          values[name] != 'undefined',
    );

Map<String, String> decodeNhentaiStorage(dynamic result) {
  try {
    dynamic decoded = result is String ? jsonDecode(result) : result;
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  } catch (_) {
    return {};
  }
}

/// Owns one login window. Cancellation also invalidates pending async probes.
class NhentaiLoginFlow {
  final _result = Completer<bool>();
  bool _probing = false;

  Future<bool> get result => _result.future;
  bool get active => !_result.isCompleted;

  void cancel() {
    if (active) _result.complete(false);
  }

  Future<void> probe({
    required Future<Map<String, String>> Function() readCookies,
    required Future<Map<String, String>> Function() readStorage,
    required Future<String?> Function() readUserAgent,
    required void Function(Map<String, String>, String?) persist,
    required void Function() close,
  }) async {
    if (!active || _probing) return;
    _probing = true;
    try {
      final cookies = Map<String, String>.from(await readCookies());
      final storage = await readStorage();
      // Native cookies take precedence. Only known auth keys may be recovered
      // from browser storage; CSRF tokens and preferences are not sessions.
      for (final name in nhentaiAuthCookieNames) {
        if ((cookies[name]?.isEmpty ?? true) &&
            storage[name]?.isNotEmpty == true) {
          cookies[name] = storage[name]!;
        }
      }
      if (!active || !hasNhentaiSession(cookies)) return;
      final userAgent = await readUserAgent();
      if (!active) return;
      persist(cookies, userAgent);
      _result.complete(true);
      close();
    } finally {
      _probing = false;
    }
  }
}
