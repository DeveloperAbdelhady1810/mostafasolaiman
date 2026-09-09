import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'api_exception.dart';

/// Thin wrapper over http for the /api/assistant/* and /api/auth/* surface.
/// Stateless by design - the caller passes its own bearer token in on every
/// call rather than this class holding one, so AuthProvider stays the single
/// source of truth for the current session.
class ApiClient {
  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse('$apiBaseUrl$path').replace(queryParameters: query);
  }

  Map<String, String> _headers(String? token) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  dynamic _decode(http.Response response) {
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
    final response = await http.get(_uri(path, query), headers: _headers(token));
    return _decode(response);
  }

  Future<dynamic> post(String path, {String? token, Map<String, dynamic>? body}) async {
    final response = await http.post(
      _uri(path),
      headers: _headers(token),
      body: body != null ? jsonEncode(body) : null,
    );
    return _decode(response);
  }

  Future<dynamic> put(String path, {String? token, Map<String, dynamic>? body}) async {
    final response = await http.put(
      _uri(path),
      headers: _headers(token),
      body: body != null ? jsonEncode(body) : null,
    );
    return _decode(response);
  }
}
