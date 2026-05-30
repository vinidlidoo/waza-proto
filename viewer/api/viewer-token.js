import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';
import { jwtVerify, errors as joseErrors } from 'jose';
import { randomUUID } from 'node:crypto';

const REQUIRED_ENV = ['INVITE_SIGNING_SECRET', 'LIVEKIT_API_KEY', 'LIVEKIT_API_SECRET', 'LIVEKIT_URL'];

function httpUrlFromLivekitUrl(wsUrl) {
  return wsUrl.replace(/^wss:\/\//, 'https://').replace(/^ws:\/\//, 'http://');
}

export default async function handler(req, res) {
  const missing = REQUIRED_ENV.filter((k) => !process.env[k]);
  if (missing.length > 0) {
    res.status(500).json({ error: 'missing_env', missing });
    return;
  }

  const invite = req.query.invite;
  if (!invite) {
    res.status(401).json({ error: 'missing_invite' });
    return;
  }

  const inviteKey = new TextEncoder().encode(process.env.INVITE_SIGNING_SECRET);
  let claims;
  try {
    ({ payload: claims } = await jwtVerify(invite, inviteKey, { algorithms: ['HS256'] }));
  } catch (err) {
    const code = err instanceof joseErrors.JWTExpired ? 'invite_expired' : 'invalid_invite';
    res.status(401).json({ error: code });
    return;
  }

  // The room is a SIGNED claim in the invite — a viewer can't pick an arbitrary
  // room. Invites minted before this feature carry no room and are rejected.
  const room = claims.room;
  if (!room) {
    res.status(400).json({ error: 'missing_room' });
    return;
  }

  // Re-entry gate: once the publisher closes the session the room is deleted, so
  // listRooms returns nothing and a stale invite resolves to 403 session_ended.
  try {
    const svc = new RoomServiceClient(
      httpUrlFromLivekitUrl(process.env.LIVEKIT_URL),
      process.env.LIVEKIT_API_KEY,
      process.env.LIVEKIT_API_SECRET,
    );
    const existing = await svc.listRooms([room]);
    if (!existing || existing.length === 0) {
      res.status(403).json({ error: 'session_ended' });
      return;
    }
  } catch (err) {
    res.status(502).json({ error: 'livekit_error', detail: String(err?.message ?? err) });
    return;
  }

  const at = new AccessToken(
    process.env.LIVEKIT_API_KEY,
    process.env.LIVEKIT_API_SECRET,
    {
      identity: `viewer-${randomUUID().slice(0, 8)}`,
      ttl: '10m',
    }
  );
  at.addGrant({
    roomJoin: true,
    room,
    canPublish: false,
    canSubscribe: true,
  });

  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({
    token: await at.toJwt(),
    url: process.env.LIVEKIT_URL,
  });
}
