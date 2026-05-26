import { AccessToken } from 'livekit-server-sdk';
import { jwtVerify, errors as joseErrors } from 'jose';
import { randomUUID } from 'node:crypto';

const inviteKey = new TextEncoder().encode(process.env.INVITE_SIGNING_SECRET);

export default async function handler(req, res) {
  const invite = req.query.invite;
  if (!invite) {
    res.status(401).json({ error: 'missing_invite' });
    return;
  }

  try {
    await jwtVerify(invite, inviteKey, { algorithms: ['HS256'] });
  } catch (err) {
    const code = err instanceof joseErrors.JWTExpired ? 'invite_expired' : 'invalid_invite';
    res.status(401).json({ error: code });
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
    room: 'waza-proto',
    canPublish: false,
    canSubscribe: true,
  });

  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({
    token: await at.toJwt(),
    url: process.env.LIVEKIT_URL,
  });
}
