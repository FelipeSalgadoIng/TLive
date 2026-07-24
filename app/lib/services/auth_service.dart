import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import '../app_config.dart';

class AuthService {
  static const String _clientId     = AppConfig.twitchClientId;
  static const String _clientSecret = AppConfig.twitchClientSecret;
  static const String _redirectUri  = 'http://localhost:3000';
  static const String _scope        = 'user:read:follows';

  // ─── URI DE AUTORIZACIÓN ──────────────────────────────────────────────────

  String _buildAuthUrl(String state) {
    final params = {
      'client_id':     _clientId,
      'redirect_uri':  _redirectUri,
      'response_type': 'code',
      'scope':         _scope,
      'state':         state,
      'force_verify':  'false',
    };
    return Uri.parse('https://id.twitch.tv/oauth2/authorize')
        .replace(queryParameters: params)
        .toString();
  }

  // ─── FLUJO PRINCIPAL (SHELF + IN-APP BROWSER / CUSTOM TABS) ─────────────

  Future<TwitchAuthResult> login() async {
    final state   = _generateState();
    final authUrl = _buildAuthUrl(state);

    return await _loginWithServer(authUrl, state);
  }

  Future<TwitchAuthResult> _loginWithServer(String authUrl, String state) async {
    final completer = Completer<TwitchAuthResult>();
    HttpServer? server;

    try {
      server = await shelf_io.serve(
        (Request request) async {
          // Ignores secondary browser requests like /favicon.ico
          if (request.url.path == 'favicon.ico' || request.url.path.isNotEmpty) {
            return Response.notFound('');
          }

          final code          = request.url.queryParameters['code'];
          final returnedState = request.url.queryParameters['state'];
          final error         = request.url.queryParameters['error'];

          if (error != null) {
            if (!completer.isCompleted) {
              completer.completeError(
                  AuthException('Twitch rechazo el acceso: $error'));
            }
            return Response.ok(_htmlCallback(success: false),
                headers: {'content-type': 'text/html; charset=utf-8'});
          }

          if (code == null || returnedState != state) {
            if (!completer.isCompleted) {
              completer
                  .completeError(AuthException('Respuesta invalida de Twitch'));
            }
            return Response.ok(_htmlCallback(success: false),
                headers: {'content-type': 'text/html; charset=utf-8'});
          }

          // Intercambiar token en segundo plano y cerrar la vista web al finalizar
          _exchangeCode(code, _redirectUri).then((result) {
            if (!completer.isCompleted) completer.complete(result);
            closeInAppWebView();
          }).catchError((e) {
            if (!completer.isCompleted) completer.completeError(e);
            closeInAppWebView();
          });

          return Response.ok(
            _htmlCallback(success: true),
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        },
        InternetAddress.loopbackIPv4,
        3000,
      );

      // Usar inAppBrowserView (Chrome Custom Tabs en Android) para mantener la app activa en memoria
      bool launched = false;
      try {
        launched = await launchUrl(
          Uri.parse(authUrl),
          mode: LaunchMode.inAppBrowserView,
        );
      } catch (_) {
        // Fallback a navegador externo si inAppBrowserView no está disponible
        launched = await launchUrl(
          Uri.parse(authUrl),
          mode: LaunchMode.externalApplication,
        );
      }

      if (!launched) {
        throw AuthException('No se pudo abrir el navegador');
      }

      final result = await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          closeInAppWebView();
          throw AuthException('Tiempo de espera agotado');
        },
      );

      return result;
    } finally {
      await server?.close(force: true);
    }
  }

  // ─── INTERCAMBIO DE CÓDIGO POR TOKEN ─────────────────────────────────────

  Future<TwitchAuthResult> _exchangeCode(
      String code, String redirectUri) async {
    final response = await http.post(
      Uri.parse('https://id.twitch.tv/oauth2/token'),
      body: {
        'client_id':     _clientId,
        'client_secret': _clientSecret,
        'code':          code,
        'grant_type':    'authorization_code',
        'redirect_uri':  redirectUri,
      },
    );

    if (response.statusCode != 200) {
      throw AuthException(
          'Error al obtener token: ${response.statusCode} — ${response.body}');
    }

    final data = jsonDecode(response.body);
    return TwitchAuthResult(
      accessToken:  data['access_token'],
      refreshToken: data['refresh_token'] ?? '',
      expiresIn:    data['expires_in']    ?? 0,
    );
  }

  // ─── OBTENER USUARIO AUTENTICADO ──────────────────────────────────────────

  Future<Map<String, dynamic>> getAuthenticatedUser(
      String accessToken) async {
    final response = await http.get(
      Uri.parse('https://api.twitch.tv/helix/users'),
      headers: {
        'Client-Id':     _clientId,
        'Authorization': 'Bearer $accessToken',
      },
    );

    if (response.statusCode != 200) {
      throw AuthException(
          'Error al obtener usuario: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    return data['data'][0];
  }

  // ─── OBTENER LISTA DE SEGUIDOS ────────────────────────────────────────────

  Future<List<String>> getFollowedLogins(
      String userId, String accessToken) async {
    final logins = <String>[];
    String? cursor;

    do {
      final params = <String, String>{
        'user_id': userId,
        'first':   '100',
        if (cursor != null) 'after': cursor!,
      };

      final response = await http.get(
        Uri.parse('https://api.twitch.tv/helix/channels/followed')
            .replace(queryParameters: params),
        headers: {
          'Client-Id':     _clientId,
          'Authorization': 'Bearer $accessToken',
        },
      );

      if (response.statusCode != 200) {
        throw AuthException(
            'Error al obtener seguidos: ${response.statusCode}');
      }

      final data     = jsonDecode(response.body);
      final channels = data['data'] as List;
      logins.addAll(channels.map((c) => c['broadcaster_login'] as String));
      cursor = data['pagination']?['cursor'];
    } while (cursor != null);

    return logins;
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────────

  String _generateState() {
    final random = DateTime.now().millisecondsSinceEpoch.toString();
    return random.hashCode.abs().toRadixString(16);
  }

  String _htmlCallback({required bool success}) {
    final message = success
        ? 'Autenticacion exitosa. Ya puedes volver a la aplicacion.'
        : 'Ocurrio un error al autenticar con Twitch.';
    final color = success ? '#9146FF' : '#FF4444';
    final icon  = success ? 'check_circle' : 'error';
    return '''<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>TLive</title>
  <link href="https://fonts.googleapis.com/icon?family=Material+Icons" rel="stylesheet">
</head>
<body style="font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#0E0E10;">
  <div style="text-align:center;color:white;padding:24px;">
    <div style="font-size:64px;color:$color;margin-bottom:16px;">
      <span class="material-icons" style="font-size:64px;color:$color;">$icon</span>
    </div>
    <div style="font-size:22px;color:$color;margin-bottom:8px;font-weight:700;">
      ${success ? '¡Autenticado!' : 'Error'}
    </div>
    <div style="font-size:14px;color:#AAA;margin-bottom:28px;">$message</div>
    <button onclick="window.close();" style="background:$color;color:white;border:none;padding:12px 28px;border-radius:24px;font-size:15px;font-weight:600;cursor:pointer;box-shadow:0 4px 12px rgba(145,70,255,0.4);">
      Volver a TLive
    </button>
  </div>
  <script>
    setTimeout(() => { try { window.close(); } catch(e){} }, 1000);
  </script>
</body>
</html>''';
  }
}

// ─── MODELOS ──────────────────────────────────────────────────────────────────

class TwitchAuthResult {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;

  const TwitchAuthResult({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);

  @override
  String toString() => 'AuthException: $message';
}