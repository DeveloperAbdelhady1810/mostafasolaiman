import 'dart:convert';
import 'dart:io' show HttpDate;
import 'package:http/http.dart' as http;
import '../config.dart';
import 'api_exception.dart';

/// Thin wrapper over http for the /api/assistant/* and /api/auth/* surface.
/// Stateless by design - the caller passes its own bearer token in on every
/// call rather than this class holding one, so AuthProvider stays the single
/// source of truth for the current session.
class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// server clock - this phone's clock, in seconds, learnt from the HTTP `Date`
  /// header of every response. Rotating student codes are checked against the
  /// SERVER's time, so a detection time must not depend on a wrong phone clock.
  static int serverOffsetSeconds = 0;

  /// Current time as the server sees it (unix seconds).
  static int serverNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000 + serverOffsetSeconds;

  static void _learnServerClock(http.Response response) {
    final date = response.headers['date'];
    if (date == null) return;
    try {
      final server = HttpDate.parse(date).millisecondsSinceEpoch ~/ 1000;
      serverOffsetSeconds = server - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    } catch (_) {}
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse('$apiBaseUrl$path').replace(queryParameters: query);
  }

  Map<String, String> _headers(String? token) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  dynamic _decode(http.Response response) {
    _learnServerClock(response);
    Map<String, dynamic> body = {};
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      // Non-JSON error page (e.g. a 500 HTML page) - fall through with an
      // empty body so the generic message below is used instead of crashing.
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }

    final message = body['message'] as String? ??
        'Request failed (${response.statusCode}).';
    throw ApiException(response.statusCode, message);
  }

  Future<dynamic> get(String path, {String? token, Map<String, String>? query}) async {
    final response = await _client.get(_uri(path, query), headers: _headers(token));
    return _decode(response);
  }

  Future<dynamic> post(String path, {String? token, Map<String, dynamic>? body}) async {
    final response = await _client.post(
      _uri(path),
      headers: _headers(token),
      body: body != null ? jsonEncode(body) : null,
    );
    return _decode(response);
  }

  Future<dynamic> put(String path, {String? token, Map<String, dynamic>? body}) async {
    final response = await _client.put(
      _uri(path),
      headers: _headers(token),
      body: body != null ? jsonEncode(body) : null,
    );
    return _decode(response);
  }
}
