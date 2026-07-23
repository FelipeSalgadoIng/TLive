import 'package:flutter/material.dart';
import '../storage/local_storage.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storage = LocalStorage();
  NotificationSettings _settings = const NotificationSettings();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await _storage.loadNotificationSettings();
    setState(() {
      _settings = settings;
      _loading  = false;
    });
  }

  Future<void> _save(NotificationSettings settings) async {
    await _storage.saveNotificationSettings(settings);
    setState(() => _settings = settings);
  }

  Future<void> _pickTime({required bool isFrom}) async {
    final initial = TimeOfDay(
      hour:   isFrom ? _settings.silenceFromHour   : _settings.silenceToHour,
      minute: isFrom ? _settings.silenceFromMinute : _settings.silenceToMinute,
    );

    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF9146FF),
              surface: Color(0xFF18181B),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null) return;

    if (isFrom) {
      await _save(_settings.copyWith(
        silenceFromHour:   picked.hour,
        silenceFromMinute: picked.minute,
      ));
    } else {
      await _save(_settings.copyWith(
        silenceToHour:   picked.hour,
        silenceToMinute: picked.minute,
      ));
    }
  }

  String _formatTime(int hour, int minute) {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF18181B),
        elevation: 0,
        toolbarHeight: 44,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Configuracion',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF9146FF)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildSection(
                  title: 'Notificaciones',
                  children: [
                    _buildSilenceToggle(),
                    if (_settings.silenceEnabled) ...[
                      const SizedBox(height: 1),
                      _buildTimePicker(
                        label: 'Silenciar desde',
                        hour:   _settings.silenceFromHour,
                        minute: _settings.silenceFromMinute,
                        onTap:  () => _pickTime(isFrom: true),
                      ),
                      const SizedBox(height: 1),
                      _buildTimePicker(
                        label: 'Silenciar hasta',
                        hour:   _settings.silenceToHour,
                        minute: _settings.silenceToMinute,
                        onTap:  () => _pickTime(isFrom: false),
                      ),
                      const SizedBox(height: 8),
                      _buildSilenceSummary(),
                    ],
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF18181B),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildSilenceToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.notifications_off_outlined,
              color: Colors.white54, size: 18),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Silenciar notificaciones',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          Switch(
            value: _settings.silenceEnabled,
            onChanged: (val) =>
                _save(_settings.copyWith(silenceEnabled: val)),
            activeColor: const Color(0xFF9146FF),
            inactiveTrackColor: Colors.white12,
          ),
        ],
      ),
    );
  }

  Widget _buildTimePicker({
    required String label,
    required int hour,
    required int minute,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            const SizedBox(width: 30),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.7), fontSize: 14),
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF9146FF).withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: const Color(0xFF9146FF).withOpacity(0.3)),
              ),
              child: Text(
                _formatTime(hour, minute),
                style: const TextStyle(
                  color: Color(0xFF9146FF),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSilenceSummary() {
    final from = _formatTime(
        _settings.silenceFromHour, _settings.silenceFromMinute);
    final to   = _formatTime(
        _settings.silenceToHour, _settings.silenceToMinute);

    // Determina si el rango cruza medianoche
    final fromMins = _settings.silenceFromHour * 60 + _settings.silenceFromMinute;
    final toMins   = _settings.silenceToHour   * 60 + _settings.silenceToMinute;
    final crosses  = fromMins > toMins;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline,
                color: Colors.white.withOpacity(0.3), size: 14),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                crosses
                    ? 'Sin notificaciones de $from a $to (cruza medianoche)'
                    : 'Sin notificaciones de $from a $to',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}