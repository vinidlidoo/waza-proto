import { AccessToken } from 'livekit-server-sdk';
import { jwtVerify, errors as joseErrors } from 'jose';

const REQUIRED_ENV = ['PUBLISHER_SIGNING_SECRET', 'LIVEKIT_API_KEY', 'LIVEKIT_API_SECRET', 'LIVEKIT_URL'];

export default async function handler(req, res) {
  const missing = REQUIRED_ENV.filter((k) => !process.env[k]);
  if (missing.length > 0) {
    res.status(500).json({ error: 'missing_env', missing });
    return;
  }

  const auth = req.query.auth;
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

  const at = new AccessToken(
    process.env.LIVEKIT_API_KEY,
    process.env.LIVEKIT_API_SECRET,
    {
      identity: 'ios-publisher',
      ttl: '2h',
    }
  );
  at.addGrant({
    roomJoin: true,
    room: 'waza-proto',
    canPublish: true,
    canSubscribe: false,
  });

  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({
    token: await at.toJwt(),
    url: process.env.LIVEKIT_URL,
  });
}
