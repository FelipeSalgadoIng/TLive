/**
 * TwitchLive Vigilante - Cloudflare Worker
 * 
 * Variables de entorno (Environment Variables) necesarias:
 * - TWITCH_CLIENT_ID
 * - TWITCH_CLIENT_SECRET
 * - FIREBASE_PROJECT_ID
 * - FIREBASE_CLIENT_EMAIL
 * - FIREBASE_PRIVATE_KEY
 * 
 * KV Namespace Bindings necesarias:
 * - Variable Name: STREAMERS_KV
 */

export default {
  async fetch(request, env, ctx) {
    // Endpoint para que la app registre un streamer
    if (request.method === 'POST' && new URL(request.url).pathname === '/watch') {
      try {
        const body = await request.json();
        const streamer = body.streamer?.toLowerCase();
        
        if (!streamer) {
          return new Response('Falta el campo streamer', { status: 400 });
        }

        // Obtener la lista actual
        let currentList = await env.STREAMERS_KV.get('watch_list', { type: 'json' }) || [];
        
        if (!currentList.includes(streamer)) {
          currentList.push(streamer);
          await env.STREAMERS_KV.put('watch_list', JSON.stringify(currentList));
          return new Response(JSON.stringify({ success: true, added: streamer, list: currentList }), { status: 200 });
        }
        
        return new Response(JSON.stringify({ success: true, message: 'Ya estaba vigilado' }), { status: 200 });
      } catch (e) {
        return new Response('Error parsing JSON', { status: 400 });
      }
    }

    // Respuesta genérica para otras rutas
    return new Response('TwitchLive Vigilante Worker Activo', { status: 200 });
  },

  async scheduled(event, env, ctx) {
    // Se ejecuta cada minuto vía Cron Trigger (* * * * *)
    ctx.waitUntil(this.pollTwitch(env));
  },

  async pollTwitch(env) {
    const list = await env.STREAMERS_KV.get('watch_list', { type: 'json' }) || [];
    if (list.length === 0) return;

    // Obtener token de Twitch
    const twitchTokenRes = await fetch(`https://id.twitch.tv/oauth2/token?client_id=${env.TWITCH_CLIENT_ID}&client_secret=${env.TWITCH_CLIENT_SECRET}&grant_type=client_credentials`, { method: 'POST' });
    const twitchTokenData = await twitchTokenRes.json();
    const twitchToken = twitchTokenData.access_token;

    // --- NUEVO: Procesar en lotes de 100 (Límite de la API de Twitch) ---
    const currentlyLive = [];
    for (let i = 0; i < list.length; i += 100) {
      const chunk = list.slice(i, i + 100);
      const query = chunk.map(login => `user_login=${login.toLowerCase()}`).join('&');
      
      const streamsRes = await fetch(`https://api.twitch.tv/helix/streams?${query}`, {
        headers: {
          'Client-ID': env.TWITCH_CLIENT_ID,
          'Authorization': `Bearer ${twitchToken}`
        }
      });
      
      const streamsData = await streamsRes.json();
      if (streamsData.data) {
        currentlyLive.push(...streamsData.data);
      }
    }

    const liveLogins = currentlyLive.map(s => s.user_login.toLowerCase());

    // Obtener quiénes estaban en vivo el minuto anterior
    const previouslyLive = await env.STREAMERS_KV.get('live_state', { type: 'json' }) || [];

    // Ver quiénes acaban de conectarse (están en currentlyLive pero NO en previouslyLive)
    const justWentLive = currentlyLive.filter(s => !previouslyLive.includes(s.user_login.toLowerCase()));

    // Si hay nuevos, enviar push
    if (justWentLive.length > 0) {
      const fcmToken = await this.getFirebaseAccessToken(env.FIREBASE_CLIENT_EMAIL, env.FIREBASE_PRIVATE_KEY);
      
      for (const stream of justWentLive) {
          await this.sendFcmPush(
            env.FIREBASE_PROJECT_ID, 
            fcmToken, 
            stream, 
            twitchToken, 
            env.TWITCH_CLIENT_ID
          );
      }
    }

    // --- OPTIMIZACIÓN DE KV ---
    // Solo guardamos el nuevo estado si hubo algún cambio (alguien entró o salió de live)
    // Ordenamos las listas para comparar contenido sin importar el orden de la API
    const liveLoginsSorted = [...liveLogins].sort();
    const previouslyLiveSorted = [...previouslyLive].sort();

    if (JSON.stringify(liveLoginsSorted) !== JSON.stringify(previouslyLiveSorted)) {
      await env.STREAMERS_KV.put('live_state', JSON.stringify(liveLogins));
      console.log('Estado de streams actualizado en KV');
    } else {
      console.log('Sin cambios en el estado, se omite escritura en KV para ahorrar cuota');
    }
  },

  async sendFcmPush(projectId, accessToken, stream, twitchToken, twitchClientId) {
    // Obtener la imagen de perfil del streamer (Avatar)
    let avatarUrl = '';
    try {
      const userRes = await fetch(`https://api.twitch.tv/helix/users?login=${stream.user_login}`, {
        headers: {
          'Client-ID': twitchClientId,
          'Authorization': `Bearer ${twitchToken}`
        }
      });
      const userData = await userRes.json();
      if (userData.data && userData.data.length > 0) {
        avatarUrl = userData.data[0].profile_image_url;
      }
    } catch (e) {
      console.error("Error obteniendo avatar:", e);
    }

    const payload = {
      message: {
        topic: `streamer_${stream.user_login.toLowerCase()}`,
        // Eliminamos el bloque 'notification' para evitar el duplicado automático de Android
        data: {
          title: `${stream.user_name} está en vivo!`,
          body: stream.title || `Transmitiendo ${stream.game_name}`,
          login: stream.user_login.toLowerCase(),
          game: stream.game_name,
          avatar_url: avatarUrl
        }
      }
    };

    await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });
  },

  // ---- Utilidades para generar Token OAuth de Firebase (FCM v1) en Cloudflare Workers ----
  async getFirebaseAccessToken(clientEmail, privateKey) {
    const header = { alg: 'RS256', typ: 'JWT' };
    const iat = Math.floor(Date.now() / 1000);
    const exp = iat + 3600;
    const payload = {
      iss: clientEmail,
      sub: clientEmail,
      aud: 'https://oauth2.googleapis.com/token',
      iat: iat,
      exp: exp,
      scope: 'https://www.googleapis.com/auth/firebase.messaging'
    };

    const encodedHeader = this.base64url(JSON.stringify(header));
    const encodedPayload = this.base64url(JSON.stringify(payload));
    const unsignedJwt = `${encodedHeader}.${encodedPayload}`;

    const signature = await this.signJwt(unsignedJwt, privateKey);
    const jwt = `${unsignedJwt}.${signature}`;

    const response = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: jwt
      })
    });
    
    const data = await response.json();
    return data.access_token;
  },

  async signJwt(unsignedJwt, privateKeyPem) {
    const pemHeader = "-----BEGIN PRIVATE KEY-----";
    const pemFooter = "-----END PRIVATE KEY-----";
    let pemContents = privateKeyPem
      .replace(/\\n/g, '')
      .replace(/\n/g, '')
      .replace(pemHeader, '')
      .replace(pemFooter, '');
    
    const binaryDerString = atob(pemContents);
    const binaryDer = new Uint8Array(binaryDerString.length);
    for (let i = 0; i < binaryDerString.length; i++) {
      binaryDer[i] = binaryDerString.charCodeAt(i);
    }

    const key = await crypto.subtle.importKey(
      "pkcs8",
      binaryDer.buffer,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"]
    );

    const encoder = new TextEncoder();
    const data = encoder.encode(unsignedJwt);
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, data);
    return this.base64url(signature);
  },

  base64url(source) {
    let encoded = typeof source === 'string' ? btoa(source) : btoa(String.fromCharCode(...new Uint8Array(source)));
    return encoded.replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  }
};
