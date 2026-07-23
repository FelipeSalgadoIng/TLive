import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../models/streamer.dart';
import '../storage/local_storage.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final _plugin  = FlutterLocalNotificationsPlugin();
  final _storage = LocalStorage();
  bool _initialized = false;

  // Cache de imágenes descargadas: login → ruta local
  final Map<String, String> _imageCache = {};

  // ─── INICIALIZAR ──────────────────────────────────────────────────────────

  Future<void> init({bool isBackground = false}) async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const windowsSettings = WindowsInitializationSettings(
      appName: 'TLive',
      appUserModelId: 'com.twitchlive.app',
      guid: 'd49b0314-ee7c-4fd8-9e68-3f5fa3b13d17',
    );

    const settings = InitializationSettings(
      android: androidSettings,
      windows: windowsSettings,
    );

    await _plugin.initialize(settings: settings);

    // Crear el canal de Android explícitamente (necesario para Data-only notifications)
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      const channel = AndroidNotificationChannel(
        'live_channel', // id
        'Streamers en vivo', // title
        description: 'Notifica cuando un streamer inicia un live',
        importance: Importance.max,
        enableVibration: true,
        playSound: true,
      );
      await androidPlugin.createNotificationChannel(channel);
    }

    // Solicitar permiso en Android 13+ SOLO si no estamos en background
    if (!isBackground && !kIsWeb && Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  // ─── VERIFICAR SILENCIO POR HORARIO ──────────────────────────────────────

  Future<bool> _isSilenced() async {
    final settings = await _storage.loadNotificationSettings();
    if (!settings.silenceEnabled) return false;

    final now     = DateTime.now();
    final nowMins = now.hour * 60 + now.minute;
    final fromMin = settings.silenceFromHour * 60 + settings.silenceFromMinute;
    final toMin   = settings.silenceToHour   * 60 + settings.silenceToMinute;

    // Maneja el caso donde el rango cruza medianoche
    if (fromMin <= toMin) {
      return nowMins >= fromMin && nowMins < toMin;
    } else {
      return nowMins >= fromMin || nowMins < toMin;
    }
  }

  // ─── DESCARGAR AVATAR ─────────────────────────────────────────────────────

  Future<String?> _getAvatarPath(Streamer streamer) async {
    if (streamer.avatarUrl.isEmpty) return null;

    if (_imageCache.containsKey(streamer.login)) {
      final cached = _imageCache[streamer.login]!;
      if (File(cached).existsSync()) return cached;
    }

    try {
      final response = await http
          .get(Uri.parse(streamer.avatarUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;

      final dir      = await getTemporaryDirectory();
      final sep      = Platform.pathSeparator;
      final path     = '${dir.path}${sep}twitchlive_avatar_${streamer.login}.jpg';
      await File(path).writeAsBytes(response.bodyBytes);

      _imageCache[streamer.login] = path;
      return path;
    } catch (_) {
      return null;
    }
  }

  // ─── NOTIFICAR STREAM EN VIVO ─────────────────────────────────────────────

  Future<void> notifyStreamerLive(Streamer streamer) async {
    await init();

    // Verificar silencio por horario
    if (await _isSilenced()) return;

    final avatarPath = await _getAvatarPath(streamer);
    final status     = streamer.liveStatus;
    
    // Estilo personalizado: Nombre está en vivo! y cuerpo es el Título del stream
    final title      = '${streamer.name} está en vivo!';
    final body       = status?.title ?? 'Ha iniciado un stream';

    // ── Android ──────────────────────────────────────────────────────────────
    
    final androidDetails = AndroidNotificationDetails(
      'live_channel',
      'Streamers en vivo',
      channelDescription: 'Notifica cuando un streamer inicia un live',
      importance: Importance.max,
      priority: Priority.max,
      showWhen: true,
      largeIcon: avatarPath != null ? FilePathAndroidBitmap(avatarPath) : null,
    );

    // ── Windows ───────────────────────────────────────────────────────────────
    WindowsNotificationDetails windowsDetails;

    if (!kIsWeb && Platform.isWindows) {
      final images = <WindowsImage>[];
      if (avatarPath != null) {
        images.add(WindowsImage(
          Uri.file(avatarPath, windows: true),
          altText: streamer.name,
          placement: WindowsImagePlacement.appLogoOverride,
          crop: WindowsImageCrop.circle,
        ));
      }

      final rows = <WindowsRow>[];
      if (status != null) {
        rows.add(WindowsRow([
          WindowsColumn([
            WindowsNotificationText(
              text: status.title,
              isCaption: true,
            ),
          ]),
        ]));
      }

      windowsDetails = WindowsNotificationDetails(
        images: images,
        rows: rows,
      );
    } else {
      windowsDetails = const WindowsNotificationDetails();
    }

    final details = NotificationDetails(
      android: androidDetails,
      windows: windowsDetails,
    );

    await _plugin.show(
      id: streamer.login.toLowerCase().hashCode.abs() % 100000,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  // ─── CLOUDFLARE Y FIREBASE MESSAGING ──────────────────────────────────────

  Future<void> watchStreamer(String login) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await FirebaseMessaging.instance.subscribeToTopic('streamer_${login.toLowerCase()}');
      await http.post(
        Uri.parse('https://twitch-vigilante.felipe-salgado.workers.dev/watch'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'streamer': login.toLowerCase()}),
      );
    } catch (_) {
      // Ignorar si falla la red
    }
  }

  Future<void> unwatchStreamer(String login) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic('streamer_${login.toLowerCase()}');
    } catch (_) {}
  }

  // --- NUEVO: Suscribir a todos los streamers guardados localmente ---
  Future<void> subscribeToAll() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final streamers = await _storage.loadStreamers();
      // No usamos await dentro del bucle para no bloquear secuencialmente
      for (var s in streamers) {
        FirebaseMessaging.instance.subscribeToTopic('streamer_${s.login.toLowerCase()}');
      }
      if (kDebugMode) print('Lanzadas ${streamers.length} suscripciones a temas');
    } catch (e) {
      if (kDebugMode) print('Error en auto-suscripción: $e');
    }
  }
}