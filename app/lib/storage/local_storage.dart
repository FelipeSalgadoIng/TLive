import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/streamer.dart';

class LocalStorage {
  static const String _streamersKey    = 'streamers_list';
  static const String _accessTokenKey  = 'twitch_access_token';
  static const String _userIdKey       = 'twitch_user_id';
  static const String _userLoginKey    = 'twitch_user_login';
  static const String _userNameKey     = 'twitch_user_name';
  static const String _liveSetKey      = 'live_set';
  static const String _notifSettingsKey = 'notification_settings';
  static const String _appAccessTokenKey = 'twitch_app_token';
  static const String _appTokenExpiryKey  = 'twitch_app_token_expiry';

  // ─── STREAMERS ────────────────────────────────────────────────────────────

  Future<List<Streamer>> loadStreamers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_streamersKey);
    if (raw == null) return [];
    final List<dynamic> decoded = jsonDecode(raw);
    return decoded
        .map((item) => Streamer.fromLocal(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveStreamers(List<Streamer> streamers) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(streamers.map((s) => s.toLocal()).toList());
    await prefs.setString(_streamersKey, encoded);
  }

  Future<List<Streamer>> addStreamer(
      List<Streamer> current, Streamer newStreamer) async {
    final exists = current
        .any((s) => s.login.toLowerCase() == newStreamer.login.toLowerCase());
    if (exists) return current;
    final updated = [...current, newStreamer];
    await saveStreamers(updated);
    return updated;
  }

  Future<List<Streamer>> removeStreamer(
      List<Streamer> current, String login) async {
    final updated = current
        .where((s) => s.login.toLowerCase() != login.toLowerCase())
        .toList();
    await saveStreamers(updated);
    return updated;
  }

  // ─── AUTH ─────────────────────────────────────────────────────────────────

  Future<void> saveAuth({
    required String accessToken,
    required String userId,
    required String userLogin,
    required String userName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessTokenKey, accessToken);
    await prefs.setString(_userIdKey, userId);
    await prefs.setString(_userLoginKey, userLogin);
    await prefs.setString(_userNameKey, userName);
  }

  Future<TwitchSession?> loadSession() async {
    final prefs     = await SharedPreferences.getInstance();
    final token     = prefs.getString(_accessTokenKey);
    final userId    = prefs.getString(_userIdKey);
    final userLogin = prefs.getString(_userLoginKey);
    final userName  = prefs.getString(_userNameKey);
    if (token == null || userId == null) return null;
    return TwitchSession(
      accessToken: token,
      userId:      userId,
      userLogin:   userLogin ?? '',
      userName:    userName ?? '',
    );
  }

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_userLoginKey);
    await prefs.remove(_userNameKey);
  }

  Future<bool> get hasSession async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_accessTokenKey);
  }

  // ─── LIVE SET (background polling Android) ────────────────────────────────

  Future<Set<String>> loadLiveSet() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getStringList(_liveSetKey);
    return raw?.toSet() ?? {};
  }

  Future<void> saveLiveSet(Set<String> logins) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_liveSetKey, logins.toList());
  }

  // ─── NOTIFICATION SETTINGS ───────────────────────────────────────────────

  Future<NotificationSettings> loadNotificationSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_notifSettingsKey);
    if (raw == null) return const NotificationSettings();
    try {
      return NotificationSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const NotificationSettings();
    }
  }

  Future<void> saveNotificationSettings(NotificationSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_notifSettingsKey, jsonEncode(settings.toJson()));
  }

  // ─── APP ACCESS TOKEN ────────────────────────────────────────────────────

  Future<void> saveAppToken(String token, DateTime expiry) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appAccessTokenKey, token);
    await prefs.setString(_appTokenExpiryKey, expiry.toIso8601String());
  }

  Future<Map<String, dynamic>?> loadAppToken() async {
    final prefs  = await SharedPreferences.getInstance();
    final token  = prefs.getString(_appAccessTokenKey);
    final expiry = prefs.getString(_appTokenExpiryKey);
    if (token == null || expiry == null) return null;
    return {
      'token':  token,
      'expiry': DateTime.parse(expiry),
    };
  }

  // ─── SECTION COLLAPSE ──────────────────────────────────────────────────────

  Future<Map<String, bool>> loadSectionCollapse() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'live': prefs.getBool('section_live_expanded') ?? true,
      'offline': prefs.getBool('section_offline_expanded') ?? true,
    };
  }

  Future<void> saveSectionCollapse(bool liveExpanded, bool offlineExpanded) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('section_live_expanded', liveExpanded);
    await prefs.setBool('section_offline_expanded', offlineExpanded);
  }
}

// ─── MODELOS ──────────────────────────────────────────────────────────────────

class TwitchSession {
  final String accessToken;
  final String userId;
  final String userLogin;
  final String userName;

  const TwitchSession({
    required this.accessToken,
    required this.userId,
    required this.userLogin,
    required this.userName,
  });
}

class NotificationSettings {
  final bool silenceEnabled;
  final int silenceFromHour;
  final int silenceFromMinute;
  final int silenceToHour;
  final int silenceToMinute;

  const NotificationSettings({
    this.silenceEnabled    = false,
    this.silenceFromHour   = 23,
    this.silenceFromMinute = 0,
    this.silenceToHour     = 8,
    this.silenceToMinute   = 0,
  });

  factory NotificationSettings.fromJson(Map<String, dynamic> json) {
    return NotificationSettings(
      silenceEnabled:    json['silenceEnabled']    as bool? ?? false,
      silenceFromHour:   json['silenceFromHour']   as int?  ?? 23,
      silenceFromMinute: json['silenceFromMinute'] as int?  ?? 0,
      silenceToHour:     json['silenceToHour']     as int?  ?? 8,
      silenceToMinute:   json['silenceToMinute']   as int?  ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'silenceEnabled':    silenceEnabled,
        'silenceFromHour':   silenceFromHour,
        'silenceFromMinute': silenceFromMinute,
        'silenceToHour':     silenceToHour,
        'silenceToMinute':   silenceToMinute,
      };

  NotificationSettings copyWith({
    bool? silenceEnabled,
    int? silenceFromHour,
    int? silenceFromMinute,
    int? silenceToHour,
    int? silenceToMinute,
  }) {
    return NotificationSettings(
      silenceEnabled:    silenceEnabled    ?? this.silenceEnabled,
      silenceFromHour:   silenceFromHour   ?? this.silenceFromHour,
      silenceFromMinute: silenceFromMinute ?? this.silenceFromMinute,
      silenceToHour:     silenceToHour     ?? this.silenceToHour,
      silenceToMinute:   silenceToMinute   ?? this.silenceToMinute,
    );
  }
}