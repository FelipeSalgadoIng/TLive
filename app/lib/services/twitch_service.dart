import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/streamer.dart';
import '../app_config.dart';
import '../storage/local_storage.dart';

class TwitchService {
  static const String _clientId     = AppConfig.twitchClientId;
  static const String _clientSecret = AppConfig.twitchClientSecret;
  static const String _baseUrl      = 'https://api.twitch.tv/helix';
  static const String _authUrl      = 'https://id.twitch.tv/oauth2/token';

  String? _accessToken;
  DateTime? _tokenExpiry;
  final _storage = LocalStorage();

  // ─── TOKEN ────────────────────────────────────────────────────────────────
  
  void invalidateToken() {
    _accessToken = null;
    _tokenExpiry = null;
    // También limpiamos en persistencia para forzar renovación total
    _storage.saveAppToken('', DateTime.fromMillisecondsSinceEpoch(0));
  }

  Future<String> _getToken() async {
    // 1. Intentar desde RAM
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _accessToken!;
    }

    // 2. Intentar desde LocalStorage
    final saved = await _storage.loadAppToken();
    if (saved != null) {
      final token = saved['token'] as String;
      final expiry = saved['expiry'] as DateTime;
      if (token.isNotEmpty && DateTime.now().isBefore(expiry)) {
        _accessToken = token;
        _tokenExpiry = expiry;
        return _accessToken!;
      }
    }

    // 3. Si nada funciona, pedir nuevo a Twitch
    final response = await http.post(
      Uri.parse(_authUrl),
      body: {
        'client_id':     _clientId,
        'client_secret': _clientSecret,
        'grant_type':    'client_credentials',
      },
    );

    if (response.statusCode != 200) {
      throw TwitchException('Error de autenticacion con Twitch', statusCode: response.statusCode);
    }

    final data = jsonDecode(response.body);
    _accessToken = data['access_token'];
    final expires = data['expires_in'] as int? ?? 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expires - 60)); 
    
    // Persistir para el próximo inicio
    await _storage.saveAppToken(_accessToken!, _tokenExpiry!);
    
    return _accessToken!;
  }

  Map<String, String> _headers(String token) => {
        'Client-Id':     _clientId,
        'Authorization': 'Bearer $token',
      };

  // ─── BUSCAR STREAMER POR NOMBRE ───────────────────────────────────────────

  Future<Streamer?> findStreamer(String login) async {
    final token = await _getToken();
    final uri = Uri.parse('$_baseUrl/users')
        .replace(queryParameters: {'login': login.toLowerCase()});

    final response = await http.get(uri, headers: _headers(token));

    if (response.statusCode == 401) {
      invalidateToken();
      return findStreamer(login); // Reintentar una vez con nuevo token
    }

    if (response.statusCode != 200) {
      throw TwitchException('Error buscando streamer', statusCode: response.statusCode);
    }

    final data  = jsonDecode(response.body);
    final users = data['data'] as List;
    if (users.isEmpty) return null;
    return Streamer.fromTwitchUser(users.first);
  }

  // ─── BUSCAR VARIOS STREAMERS POR NOMBRE (lote) ───────────────────────────

  Future<List<Streamer>> findStreamers(List<String> logins) async {
    if (logins.isEmpty) return [];
    final token = await _getToken();

    final query = logins.map((l) => 'login=${Uri.encodeComponent(l)}').join('&');
    final url   = Uri.parse('$_baseUrl/users?$query');

    final response = await http.get(url, headers: _headers(token));

    if (response.statusCode == 401) {
      invalidateToken();
      return findStreamers(logins);
    }

    if (response.statusCode != 200) {
      throw TwitchException('Error buscando streamers', statusCode: response.statusCode);
    }

    final data  = jsonDecode(response.body);
    final users = data['data'] as List;
    return users.map((u) => Streamer.fromTwitchUser(u)).toList();
  }

  // ─── CONSULTAR STREAMS EN VIVO ────────────────────────────────────────────

  Future<List<Streamer>> updateLiveStatus(List<Streamer> streamers) async {
    if (streamers.isEmpty) return streamers;

    final token   = await _getToken();
    final liveMap = <String, StreamStatus>{};

    for (var i = 0; i < streamers.length; i += 100) {
      final batch = streamers.sublist(
          i, i + 100 > streamers.length ? streamers.length : i + 100);

      final query = batch
          .map((s) => 'user_login=${Uri.encodeComponent(s.login)}')
          .join('&');
      final url = Uri.parse('$_baseUrl/streams?$query&first=100');

      final response = await http.get(url, headers: _headers(token));

      if (response.statusCode == 401) {
        invalidateToken();
        return updateLiveStatus(streamers); // Reintentar lote completo
      }

      if (response.statusCode != 200) {
        throw TwitchException('Error consultando streams', statusCode: response.statusCode);
      }

      final data        = jsonDecode(response.body);
      final liveStreams  = data['data'] as List;

      for (final stream in liveStreams) {
        final login = (stream['user_login'] as String).toLowerCase();
        liveMap[login] = StreamStatus.fromTwitchStream(stream);
      }
    }

    return streamers.map((streamer) {
      final status = liveMap[streamer.login.toLowerCase()];
      return status != null
          ? streamer.copyWith(liveStatus: status)
          : streamer.copyWith(clearLive: true);
    }).toList();
  }
}

// ─── EXCEPCIÓN PERSONALIZADA ──────────────────────────────────────────────────

class TwitchException implements Exception {
  final String message;
  final int? statusCode;
  TwitchException(this.message, {this.statusCode});

  @override
  String toString() => 'TwitchException ($statusCode): $message';
}