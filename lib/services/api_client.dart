import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'package:vesta_tracker/l10n/tr.dart';
/// API error with enough information to decide whether it is a network
/// problem (retry later, keep the local state) or an explicit server
/// response (apply it straight away).
class VestaApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;
  final bool isNetworkError;

  const VestaApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.isNetworkError = false,
  });

  /// Failures that say nothing about the device's authorisation:
  /// no network, timeout, server down or rate-limited.
  bool get isTransient =>
      isNetworkError ||
      statusCode == null ||
      statusCode == 408 ||
      statusCode == 429 ||
      (statusCode != null && statusCode! >= 500);

  @override
  String toString() => message;
}

class VestaApiClient {
  static const String _baseUrl = String.fromEnvironment('VESTA_API_URL');

  static final http.Client _client = http.Client();

  static Future<Map<String, dynamic>> get(String path) {
    return _send('GET', path, timeout: const Duration(seconds: 15));
  }

  static Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic> body = const {},
  }) {
    return _send(
      'POST',
      path,
      body: body,
      timeout: const Duration(seconds: 30),
    );
  }

  static Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    required Duration timeout,
  }) async {
    if (_baseUrl.isEmpty) {
      throw VestaApiException(tr('Falta configurar VESTA_API_URL.'));
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw VestaApiException(
        tr('No existe una sesión autenticada.'),
        isNetworkError: true,
      );
    }

    String? token;
    try {
      token = await user.getIdToken();
    } on FirebaseAuthException catch (e) {
      throw VestaApiException(
        tr('No se pudo obtener el token de autenticación.'),
        code: e.code,
        isNetworkError: e.code == 'network-request-failed',
      );
    }

    if (token == null || token.isEmpty) {
      throw VestaApiException(
        tr('No se pudo obtener el token de autenticación.'),
      );
    }

    final baseUrl = _baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.parse('$baseUrl$path');
    final headers = {
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
      if (body != null) 'Content-Type': 'application/json',
    };

    http.Response response;
    try {
      response = method == 'GET'
          ? await _client.get(uri, headers: headers).timeout(timeout)
          : await _client
              .post(uri, headers: headers, body: jsonEncode(body))
              .timeout(timeout);
    } on TimeoutException {
      throw VestaApiException(
        tr('El servidor tardó demasiado en responder.'),
        isNetworkError: true,
      );
    } on SocketException {
      throw VestaApiException(
        tr('Sin conexión con el servidor.'),
        isNetworkError: true,
      );
    } on http.ClientException catch (e) {
      throw VestaApiException(
        tr('Error de conexión: {0}', [e.message]),
        isNetworkError: true,
      );
    } on HandshakeException {
      throw VestaApiException(
        tr('No se pudo establecer una conexión segura.'),
        isNetworkError: true,
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      // A broken proxy or tunnel usually returns HTML: it is a transient failure.
      throw VestaApiException(
        tr('El servidor devolvió una respuesta no válida.'),
        statusCode: response.statusCode >= 500 ? response.statusCode : 502,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map && decoded['message'] is String
          ? decoded['message'] as String
          : tr('Error del servidor ({0}).', [response.statusCode]);
      final code = decoded is Map && decoded['error'] is String
          ? decoded['error'] as String
          : null;
      throw VestaApiException(
        message,
        statusCode: response.statusCode,
        code: code,
      );
    }

    if (decoded is! Map) {
      throw VestaApiException(
        tr('El servidor devolvió una respuesta inesperada.'),
        statusCode: response.statusCode,
      );
    }

    return Map<String, dynamic>.from(decoded);
  }
}
