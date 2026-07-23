# TLive

A lightweight, cross-platform Twitch stream tracker. Get notified the moment your favorite streamers go live — without opening Twitch.

![Flutter](https://img.shields.io/badge/Flutter-3.x-blue?logo=flutter)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Android-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)

## 🚀 Descargas (Downloads)

Puedes descargar la versión lista para usar desde la sección de **[Releases](https://github.com/FelipeSalgadoIng/TLive/releases/latest)**:

- 💻 **[TLive para Windows (v1.0.0)](https://github.com/FelipeSalgadoIng/TLive/releases/download/v1.0.0/TLive-Setup-v1.0.0.exe)** (`TLive-Setup-v1.0.0.exe` — Instalador automático de Windows)
- 📱 **[TLive para Android (v1.0.0)](https://github.com/FelipeSalgadoIng/TLive/releases/download/v1.0.0/TLive-v1.0.0.apk)** (`TLive-v1.0.0.apk` — Aplicación instalable para Android)

---

## Features

- 🔴 **Live status** — see which streamers are online right now
- 🔔 **Push notifications** — get notified the instant a stream starts (Android)
- 🖥️ **Desktop notifications** — rich Windows toast notifications with avatar
- 🔑 **Twitch login** — optionally import your followed channels automatically
- ➕ **Manual tracking** — add any streamer by name, no login required
- 📦 **System tray** — minimize to tray on Windows, stays out of your way
- 📋 **Collapsible sections** — compact or expand live/offline lists

---

## Platforms

| Platform | Status |
|---|---|
| Windows | ✅ Supported |
| Android | ✅ Supported |
| Linux | 🔜 Planned |
| macOS / iOS | 🔜 Planned |

---

## Architecture

```
TLive/
├── worker.js              ← Cloudflare Worker (push notification backend)
└── app/                   ← Flutter application
    └── lib/
        ├── main.dart
        ├── app_config.dart         ← your credentials (not in repo, see setup)
        ├── app_config.example.dart ← template
        ├── models/
        │   └── streamer.dart
        ├── services/
        │   ├── twitch_service.dart
        │   ├── auth_service.dart
        │   └── notification_service.dart
        ├── storage/
        │   └── local_storage.dart
        └── screens/
            ├── home_screen.dart
            └── add_streamer_screen.dart
```

### Backend

Push notifications on Android are powered by a **Cloudflare Worker** that polls the Twitch API every minute and sends notifications via **Firebase Cloud Messaging (FCM)**. This means zero battery drain on the device — no background polling.

---

## Setup

### 1. Prerequisites

- [Flutter SDK 3.x](https://flutter.dev/docs/get-started/install)
- A [Twitch Developer Application](https://dev.twitch.tv/console/apps) (Client ID + Secret)
- (Optional) Firebase project for Android push notifications

### 2. Clone & configure credentials

```bash
git clone https://github.com/FelipeSalgadoIng/TLive.git
cd TLive/app
```

Copy the example config file and fill in your credentials:

```bash
cp lib/app_config.example.dart lib/app_config.dart
```

Edit `lib/app_config.dart`:

```dart
class AppConfig {
  static const String twitchClientId     = 'YOUR_TWITCH_CLIENT_ID';
  static const String twitchClientSecret = 'YOUR_TWITCH_CLIENT_SECRET';
}
```

> ⚠️ `app_config.dart` is excluded from Git via `.gitignore`. Never commit this file.

### 3. Register your redirect URI in Twitch

In your Twitch app settings at [dev.twitch.tv](https://dev.twitch.tv/console/apps), add:
- `http://localhost:3000` (for desktop OAuth)
- `twitchlive://auth/callback` (for Android OAuth)

### 4. Run

```bash
# Windows
flutter run -d windows

# Android
flutter run -d <your-device-id>
```

---

## Push Notifications (Android)

Push notifications require the Cloudflare Worker backend. To deploy your own:

1. Create a [Cloudflare Workers](https://workers.cloudflare.com/) account
2. Create a KV namespace called `STREAMERS_KV`
3. Set the following environment variables in your Worker:
   - `TWITCH_CLIENT_ID`
   - `TWITCH_CLIENT_SECRET`
   - `FIREBASE_PROJECT_ID`
   - `FIREBASE_CLIENT_EMAIL`
   - `FIREBASE_PRIVATE_KEY`
4. Deploy `worker.js`:
   ```bash
   wrangler deploy worker.js
   ```

---

## Tech Stack

| Component | Technology |
|---|---|
| App | Flutter / Dart |
| Desktop notifications | `flutter_local_notifications` |
| System tray | `system_tray` |
| Auth | Twitch OAuth2 (via `shelf` on desktop, `app_links` on Android) |
| Push backend | Cloudflare Workers + Firebase FCM |
| Local storage | `shared_preferences` |

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you'd like to change.
