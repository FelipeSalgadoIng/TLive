class Streamer {
  final String id;
  final String login;      // nombre en minúsculas (usado en la API)
  final String name;       // nombre con capitalización original
  final String avatarUrl;

  // Estado del stream actual (null = offline)
  final StreamStatus? liveStatus;

  const Streamer({
    required this.id,
    required this.login,
    required this.name,
    required this.avatarUrl,
    this.liveStatus,
  });

  bool get isLive => liveStatus != null;

  // Crea un Streamer desde la respuesta de /helix/users
  factory Streamer.fromTwitchUser(Map<String, dynamic> json) {
    return Streamer(
      id:        json['id'],
      login:     json['login'],
      name:      json['display_name'],
      avatarUrl: json['profile_image_url'],
    );
  }

  // Crea un Streamer desde los datos guardados localmente
  factory Streamer.fromLocal(Map<String, dynamic> json) {
    return Streamer(
      id:        json['id'],
      login:     json['login'],
      name:      json['name'],
      avatarUrl: json['avatarUrl'],
    );
  }

  // Convierte a Map para guardar localmente
  Map<String, dynamic> toLocal() {
    return {
      'id':        id,
      'login':     login,
      'name':      name,
      'avatarUrl': avatarUrl,
    };
  }

  // Retorna una copia del streamer con el estado de stream actualizado
  Streamer copyWith({StreamStatus? liveStatus, bool clearLive = false}) {
    return Streamer(
      id:          id,
      login:       login,
      name:        name,
      avatarUrl:   avatarUrl,
      liveStatus:  clearLive ? null : (liveStatus ?? this.liveStatus),
    );
  }
}

class StreamStatus {
  final String streamId;
  final String title;
  final String gameName;
  final int viewerCount;
  final DateTime startedAt;
  final String thumbnailUrl;

  const StreamStatus({
    required this.streamId,
    required this.title,
    required this.gameName,
    required this.viewerCount,
    required this.startedAt,
    required this.thumbnailUrl,
  });

  // Crea un StreamStatus desde la respuesta de /helix/streams
  factory StreamStatus.fromTwitchStream(Map<String, dynamic> json) {
    // La URL viene con {width}x{height} — la reemplazamos por 320x180
    final rawThumb = json['thumbnail_url'] as String;
    final thumb = rawThumb
        .replaceAll('{width}', '320')
        .replaceAll('{height}', '180');

    return StreamStatus(
      streamId:    json['id'],
      title:       json['title'],
      gameName:    json['game_name'],
      viewerCount: json['viewer_count'],
      startedAt:   DateTime.parse(json['started_at']),
      thumbnailUrl: thumb,
    );
  }

  // Tiempo transcurrido desde que empezó el stream
  Duration get uptime => DateTime.now().toUtc().difference(startedAt);

  String get uptimeFormatted {
    final h = uptime.inHours;
    final m = uptime.inMinutes.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h}h ${m}m' : '${uptime.inMinutes}m';
  }
}