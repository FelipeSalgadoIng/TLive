import 'dart:async';
import 'package:flutter/material.dart';
import '../models/streamer.dart';
import '../services/twitch_service.dart';
import '../services/notification_service.dart';
import '../services/auth_service.dart';
import '../storage/local_storage.dart';
import 'add_streamer_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _twitch        = TwitchService();
  final _storage       = LocalStorage();
  final _notifications = NotificationService();
  final _auth          = AuthService();

  List<Streamer>  _streamers      = [];
  TwitchSession?  _session;
  bool            _initialLoading = true;
  bool            _polling        = false;
  bool            _importingFollows = false;
  bool            _isLiveExpanded = true;
  bool            _isOfflineExpanded = true;
  String?         _lastError;
  Timer?          _pollTimer;

  final Set<String> _notifiedLive = {};
  static const _pollInterval = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Al volver a la app después de horas, refrescar inmediatamente
      _refresh(silent: true);
    }
  }

  Future<void> _init() async {
    await _notifications.init();
    final saved    = await _storage.loadStreamers();
    final session  = await _storage.loadSession();
    final collapse = await _storage.loadSectionCollapse();
    setState(() {
      _streamers = saved;
      _session   = session;
      _isLiveExpanded = collapse['live'] ?? true;
      _isOfflineExpanded = collapse['offline'] ?? true;
    });
    await _refresh(silent: true);
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_streamers.isEmpty) {
      setState(() => _initialLoading = false);
      return;
    }
    if (_polling) return;

    setState(() {
      _polling   = true;
      _lastError = null;
    });

    try {
      final updated = await _twitch.updateLiveStatus(_streamers);

      for (final streamer in updated) {
        if (streamer.isLive) {
          if (!_notifiedLive.contains(streamer.login)) {
            _notifiedLive.add(streamer.login);
            if (!silent) await _notifications.notifyStreamerLive(streamer);
          }
        } else {
          _notifiedLive.remove(streamer.login);
        }
      }

      if (mounted) {
        setState(() {
          _streamers      = updated;
          _initialLoading = false;
        });
      }
    } on TwitchException catch (e) {
      if (mounted) setState(() => _lastError = e.message);
    } catch (_) {
      if (mounted) setState(() => _lastError = 'Error de conexion');
    } finally {
      if (mounted) setState(() => _polling = false);
    }
  }

  // ─── AUTH ─────────────────────────────────────────────────────────────────

  Future<void> _login() async {
    try {
      final result = await _auth.login();
      final user   = await _auth.getAuthenticatedUser(result.accessToken);

      await _storage.saveAuth(
        accessToken: result.accessToken,
        userId:      user['id'],
        userLogin:   user['login'],
        userName:    user['display_name'],
      );

      final session = TwitchSession(
        accessToken: result.accessToken,
        userId:      user['id'],
        userLogin:   user['login'],
        userName:    user['display_name'],
      );

      if (mounted) setState(() => _session = session);
      if (mounted) _showImportDialog();
    } on AuthException catch (e) {
      if (mounted) _showError(e.message);
    } catch (e) {
      if (mounted) _showError('Error al iniciar sesion');
    }
  }

  Future<void> _logout() async {
    await _storage.clearSession();
    if (mounted) setState(() => _session = null);
  }

  Future<void> _importFollows() async {
    final session = _session;
    if (session == null) return;

    setState(() => _importingFollows = true);

    try {
      final logins = await _auth.getFollowedLogins(
          session.userId, session.accessToken);

      if (logins.isEmpty) {
        if (mounted) _showError('No seguis a ningun canal en Twitch');
        return;
      }

      final newLogins = logins
          .where((l) => !_streamers
              .any((s) => s.login.toLowerCase() == l.toLowerCase()))
          .toList();

      if (newLogins.isEmpty) {
        if (mounted) _showError('Todos tus seguidos ya estan en la lista');
        return;
      }

      final newStreamers = <Streamer>[];
      for (var i = 0; i < newLogins.length; i += 100) {
        final batch = newLogins.sublist(
            i, i + 100 > newLogins.length ? newLogins.length : i + 100);
        final found = await _twitch.findStreamers(batch);
        newStreamers.addAll(found);
      }

      var current = _streamers;
      for (final s in newStreamers) {
        current = await _storage.addStreamer(current, s);
        await _notifications.watchStreamer(s.login);
      }

      if (mounted) {
        setState(() => _streamers = current);
        await _refresh(silent: true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${newStreamers.length} streamers importados'),
          backgroundColor: const Color(0xFF9146FF),
        ));
      }
    } on AuthException catch (e) {
      if (mounted) _showError(e.message);
    } catch (e) {
      if (mounted) _showError('Error al importar seguidos');
    } finally {
      if (mounted) setState(() => _importingFollows = false);
    }
  }

  void _showImportDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF18181B),
        title: const Text(
          'Importar seguidos',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text(
          'Queres importar tu lista de canales seguidos de Twitch?',
          style:
              TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Ahora no',
                style: TextStyle(color: Colors.white.withOpacity(0.4))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _importFollows();
            },
            child: const Text('Importar',
                style: TextStyle(color: Color(0xFF9146FF))),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: Colors.red.shade800,
    ));
  }

  // ─── STREAMERS ────────────────────────────────────────────────────────────

  Future<void> _openAddStreamer() async {
    final result = await Navigator.push<Streamer>(
      context,
      MaterialPageRoute(builder: (_) => const AddStreamerScreen()),
    );
    if (result != null) {
      final updated = await _storage.addStreamer(_streamers, result);
      await _notifications.watchStreamer(result.login);
      setState(() => _streamers = updated);
      await _refresh(silent: true);
    }
  }

  Future<void> _removeStreamer(String login) async {
    final updated = await _storage.removeStreamer(_streamers, login);
    _notifiedLive.remove(login);
    await _notifications.unwatchStreamer(login);
    setState(() => _streamers = updated);
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  // ─── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final live = _streamers.where((s) => s.isLive).toList()
      ..sort((a, b) =>
          b.liveStatus!.viewerCount.compareTo(a.liveStatus!.viewerCount));
    final offline = _streamers.where((s) => !s.isLive).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: _buildAppBar(),
      body: _initialLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF9146FF)))
          : _streamers.isEmpty
              ? _buildEmptyState()
              : _buildContent(live, offline),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddStreamer,
        backgroundColor: const Color(0xFF9146FF),
        mini: true,
        child: const Icon(Icons.add, color: Colors.white, size: 20),
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF18181B),
      elevation: 0,
      toolbarHeight: 44,
      title: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _polling
                  ? const Color(0xFF9146FF)
                  : const Color(0xFF00FF7F),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (_polling
                          ? const Color(0xFF9146FF)
                          : const Color(0xFF00FF7F))
                      .withOpacity(0.5),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'TLive',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
      actions: [
        if (_importingFollows)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF9146FF)),
            ),
          ),
        if (_lastError != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Tooltip(
              message: _lastError!,
              child: const Icon(Icons.warning_amber,
                  color: Colors.orange, size: 18),
            ),
          ),
        // Botón cuenta Twitch
        _session != null
            ? PopupMenuButton<String>(
                icon: CircleAvatar(
                  radius: 12,
                  backgroundColor: const Color(0xFF9146FF),
                  child: Text(
                    _session!.userName.isNotEmpty
                        ? _session!.userName[0].toUpperCase()
                        : 'T',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                color: const Color(0xFF18181B),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    enabled: false,
                    child: Text(
                      _session!.userName,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13),
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'import',
                    child: Row(children: [
                      const Icon(Icons.download,
                          color: Colors.white70, size: 16),
                      const SizedBox(width: 8),
                      Text('Importar seguidos',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 13)),
                    ]),
                  ),
                  PopupMenuItem(
                    value: 'logout',
                    child: Row(children: [
                      const Icon(Icons.logout,
                          color: Colors.white70, size: 16),
                      const SizedBox(width: 8),
                      Text('Cerrar sesion',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 13)),
                    ]),
                  ),
                ],
                onSelected: (value) {
                  if (value == 'import') _importFollows();
                  if (value == 'logout') _logout();
                },
              )
            : IconButton(
                icon: const Icon(Icons.login,
                    color: Colors.white70, size: 18),
                onPressed: _login,
                tooltip: 'Iniciar sesion con Twitch',
                padding: const EdgeInsets.all(8),
              ),

        // Settings
        IconButton(
          icon: const Icon(Icons.settings_outlined,
              color: Colors.white70, size: 18),
          onPressed: _openSettings,
          tooltip: 'Configuracion',
          padding: const EdgeInsets.all(8),
        ),
        IconButton(
          icon: const Icon(Icons.refresh, color: Colors.white70, size: 18),
          onPressed: _polling ? null : _refresh,
          tooltip: 'Actualizar ahora',
          padding: const EdgeInsets.all(8),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.live_tv_outlined,
              size: 48, color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 16),
          Text(
            'Sin streamers todavia',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Toca + para agregar streamers',
            style: TextStyle(
                color: Colors.white.withOpacity(0.3), fontSize: 13),
          ),
          if (_session == null) ...[
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _login,
              icon: const Icon(Icons.login,
                  size: 16, color: Color(0xFF9146FF)),
              label: const Text('Importar desde Twitch',
                  style: TextStyle(
                      color: Color(0xFF9146FF), fontSize: 13)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(
                    color: Color(0xFF9146FF), width: 0.5),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContent(List<Streamer> live, List<Streamer> offline) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (live.isNotEmpty) ...[
          _buildSectionHeader(
            'EN VIVO',
            '${live.length}',
            const Color(0xFFFF4444),
            isExpanded: _isLiveExpanded,
            onToggle: () {
              setState(() => _isLiveExpanded = !_isLiveExpanded);
              _storage.saveSectionCollapse(_isLiveExpanded, _isOfflineExpanded);
            },
          ),
          if (_isLiveExpanded)
            ...live.map((s) => _StreamerTile(
                  key: ValueKey(s.login),
                  streamer: s,
                  onRemove: () => _removeStreamer(s.login),
                )),
          const SizedBox(height: 4),
        ],
        if (offline.isNotEmpty) ...[
          _buildSectionHeader(
            'OFFLINE',
            '${offline.length}',
            Colors.white24,
            isExpanded: _isOfflineExpanded,
            onToggle: () {
              setState(() => _isOfflineExpanded = !_isOfflineExpanded);
              _storage.saveSectionCollapse(_isLiveExpanded, _isOfflineExpanded);
            },
          ),
          if (_isOfflineExpanded)
            ...offline.map((s) => _StreamerTile(
                  key: ValueKey(s.login),
                  streamer: s,
                  onRemove: () => _removeStreamer(s.login),
                )),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(
    String label,
    String count,
    Color color, {
    required bool isExpanded,
    required VoidCallback onToggle,
  }) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Row(
          children: [
            Icon(
              isExpanded
                  ? Icons.keyboard_arrow_down
                  : Icons.keyboard_arrow_right,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 4),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                count,
                style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w600),
              ),
            ),
            const Spacer(),
            Text(
              isExpanded ? 'Plegar' : 'Expandir',
              style: TextStyle(
                color: Colors.white.withOpacity(0.25),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TILE DE STREAMER ─────────────────────────────────────────────────────────

class _StreamerTile extends StatefulWidget {
  final Streamer streamer;
  final VoidCallback onRemove;

  const _StreamerTile({
    super.key,
    required this.streamer,
    required this.onRemove,
  });

  @override
  State<_StreamerTile> createState() => _StreamerTileState();
}

class _StreamerTileState extends State<_StreamerTile> {
  double _dragOffset = 0.0;
  static const double _maxDrag = 65.0;

  void _close() {
    if (_dragOffset != 0) {
      setState(() => _dragOffset = 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final streamer = widget.streamer;
    final isLive = streamer.isLive;
    final status = streamer.liveStatus;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      height: 52,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            // Fondo: Botón de confirmación de eliminación (Papelera)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _close();
                  widget.onRemove();
                },
                child: Container(
                  color: Colors.red.shade900,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 18),
                  child: const Icon(
                    Icons.delete_forever,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),

            // Frente: Tarjeta del streamer con desplazamiento animado
            AnimatedPositioned(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              left: _dragOffset,
              right: -_dragOffset,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _dragOffset = (_dragOffset + details.delta.dx).clamp(-_maxDrag, 0.0);
                  });
                },
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  setState(() {
                    if (_dragOffset < -25 || velocity < -150) {
                      _dragOffset = -_maxDrag;
                    } else {
                      _dragOffset = 0.0;
                    }
                  });
                },
                onTap: _close,
                child: Container(
                  decoration: BoxDecoration(
                    color: isLive ? const Color(0xFF1F1F23) : const Color(0xFF18181B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isLive
                          ? const Color(0xFF9146FF).withOpacity(0.25)
                          : Colors.white.withOpacity(0.04),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    children: [
                      // Avatar
                      Stack(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: const Color(0xFF2D2D35),
                            backgroundImage: streamer.avatarUrl.isNotEmpty
                                ? NetworkImage(streamer.avatarUrl)
                                : null,
                            child: streamer.avatarUrl.isEmpty
                                ? Text(
                                    streamer.name[0].toUpperCase(),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12),
                                  )
                                : null,
                          ),
                          if (isLive)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFF4444),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: const Color(0xFF1F1F23), width: 1.5),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 10),
                      // Info central
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  streamer.name,
                                  style: TextStyle(
                                    color: isLive ? Colors.white : Colors.white60,
                                    fontWeight: isLive
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    fontSize: 13,
                                  ),
                                ),
                                if (isLive && status != null) ...[
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      status.gameName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFF9146FF),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (isLive && status != null) ...[
                              const SizedBox(height: 1),
                              Text(
                                status.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.4),
                                  fontSize: 11,
                                ),
                              ),
                            ] else
                              Text(
                                'Offline',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.25),
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                      // Viewers + uptime
                      if (isLive && status != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _formatViewers(status.viewerCount),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              status.uptimeFormatted,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.35),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatViewers(int count) {
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}k';
    return count.toString();
  }
}