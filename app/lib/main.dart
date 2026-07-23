import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:system_tray/system_tray.dart';
import 'screens/home_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'services/notification_service.dart';
import 'models/streamer.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    if (kDebugMode) print("Mensaje FCM recibido en background: ${message.data}");
    
    if (message.data.isNotEmpty) {
      final login = message.data['login'] ?? 'Desconocido';
      final titleFromData = message.data['title'] ?? 'Stream en vivo';
      final body  = message.data['body'] ?? '';
      final game  = message.data['game'] ?? '';
      final avatar = message.data['avatar_url'] ?? '';
      
      // En background, el nombre visible debe ser el título que enviamos (Nombre está en vivo!)
      final streamer = Streamer(
        id: '',
        login: login,
        name: titleFromData.split(' ').first,
        avatarUrl: avatar, 
        liveStatus: StreamStatus(
          streamId: '',
          title: body, 
          gameName: game,
          viewerCount: 0,
          startedAt: DateTime.now(),
          thumbnailUrl: '',
        ),
      );

      final notifications = NotificationService();
      await notifications.init(isBackground: true);
      await notifications.notifyStreamerLive(streamer);
    }
  } catch (e) {
    if (kDebugMode) print("Error en Background Handler: $e");
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android: fuerza orientación portrait y configura la barra de estado
  if (!kIsDesktop) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0E0E10),
      systemNavigationBarIconBrightness: Brightness.light,
    ));

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      // Auto-suscribir a todos los streamers guardados (sin bloquear el arranque)
      NotificationService().subscribeToAll();
    } catch (_) {
      // Ignorar si Firebase falla en inicializar
    }
  }

  runApp(const TLiveApp());
}

bool get kIsDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

class TLiveApp extends StatelessWidget {
  const TLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TLive',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          surface: Color(0xFF0E0E10),
          surfaceContainerHighest: Color(0xFF2D2D35),
          primary: Color(0xFF9146FF),
          onSurface: Colors.white,
          error: Colors.red,
          errorContainer: Color(0xFF4D1515),
          onErrorContainer: Color(0xFFFFAAAA),
        ),
        useMaterial3: true,
      ),
      home: kIsDesktop ? const AppShell() : const _AndroidShell(),
    );
  }
}

// ─── SHELL ANDROID ────────────────────────────────────────────────────────────

class _AndroidShell extends StatelessWidget {
  const _AndroidShell();

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: HomeScreen(),
    );
  }
}

// ─── SHELL DESKTOP (con system tray) ─────────────────────────────────────────

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final SystemTray _systemTray = SystemTray();
  final AppWindow _appWindow = AppWindow();

  @override
  void initState() {
    super.initState();
    _initTray();
  }

  Future<void> _initTray() async {
    try {
      await _systemTray.initSystemTray(
        title: 'TLive',
        iconPath: 'assets/tray_icon.ico',
      );

      final menu = Menu();
      await menu.buildFrom([
        MenuItemLabel(
          label: 'Mostrar',
          onClicked: (_) => _appWindow.show(),
        ),
        MenuSeparator(),
        MenuItemLabel(
          label: 'Salir',
          onClicked: (_) => _appWindow.close(),
        ),
      ]);

      await _systemTray.setContextMenu(menu);

      _systemTray.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick) {
          _appWindow.show();
        } else if (eventName == kSystemTrayEventRightClick) {
          _systemTray.popUpContextMenu();
        }
      });
    } catch (_) {
      // Sin soporte de tray, ignoramos
    }
  }

  @override
  void dispose() {
    _systemTray.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
  }
}