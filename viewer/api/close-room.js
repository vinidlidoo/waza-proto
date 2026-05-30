import { RoomServiceClient } from 'livekit-server-sdk';
import { jwtVerify, errors as joseErrors } from 'jose';

const REQUIRED_ENV = ['PUBLISHER_SIGNING_SECRET', 'LIVEKIT_API_KEY', 'LIVEKIT_API_SECRET', 'LIVEKIT_URL'];

function httpUrlFromLivekitUrl(wsUrl) {
  return wsUrl.replace(/^wss:\/\//, 'https://').replace(/^ws:\/\//, 'http://');
}

/**
 * POST /api/close-room?room={room}
 *
 * Ends a publish session: deletes the LiveKit room, which forcibly disconnects
 * every viewer (they receive Disconnected/ROOM_DELETED). With project-global
 * auto-create OFF the room then genuinely cannot be rejoined, and stale invites
 * fall through viewer-token's listRooms gate to 403 session_ended.
 *
 * Authenticated with the same HS256 publisher envelope as /api/publisher-token
 * (identity must be ios-publisher). The room travels as an unsigned query param:
 * the envelope already proves the caller is the app, so it may close its own rooms.
 */
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'method_not_allowed' });
    return;
  }

  const missing = REQUIRED_ENV.filter((k) => !process.env[k]);
  if (missing.length > 0) {
    res.status(500).json({ error: 'missing_env', missing });
    return;
  }

  const auth = req.body?.auth ?? req.query.auth;
  if (!auth) {
    res.status(401).json({ error: 'missing_auth' });
    return;
  }

  const authKey = new TextEncoder().encode(process.env.PUBLISHER_SIGNING_SECRET);
  let claims;
  try {
    ({ payload: claims } = await jwtVerify(auth, authKey, { algorithms: ['HS256'] }));
  } catch (err) {
    const code = err instanceof joseErrors.JWTExpired ? 'auth_expired' : 'invalid_auth';
    res.status(401).json({ error: code });
    return;
  }
  if (claims.sub !== 'ios-publisher') {
    res.status(401).json({ error: 'invalid_auth' });
    return;
  }

  const room = req.query.room;
  if (!room) {
    res.status(400).json({ error: 'missing_room' });
    return;
  }

  try {
    const svc = new RoomServiceClient(
      httpUrlFromLivekitUrl(process.env.LIVEKIT_URL),
      process.env.LIVEKIT_API_KEY,
      process.env.LIVEKIT_API_SECRET,
    );
    await svc.deleteRoom(room);
  } catch (err) {
    res.status(502).json({ error: 'livekit_error', detail: String(err?.message ?? err) });
    return;
  }

  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ ok: true, room });
}
