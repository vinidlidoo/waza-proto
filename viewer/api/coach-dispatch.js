import { AgentDispatchClient, RoomServiceClient } from 'livekit-server-sdk';
import { jwtVerify, errors as joseErrors } from 'jose';

const REQUIRED_ENV = ['PUBLISHER_SIGNING_SECRET', 'LIVEKIT_API_KEY', 'LIVEKIT_API_SECRET', 'LIVEKIT_URL'];
const ROOM = 'waza-proto';
// Keep in sync with COACH_AGENT_NAME in agent/coach_agent.py.
const COACH_AGENT_NAME = 'waza-coach';

// Summon or dismiss the AI coach. Same publish-only `ios-publisher` auth as the
// publisher-token endpoint — only the app can drive this.
//   summon  → AgentDispatchClient.createDispatch (the worker registers with
//             agent_name=waza-coach and is NOT auto-dispatched, so this is the
//             only way it joins).
//   dismiss → remove the agent participant(s), which ends the job and closes
//             the billed Gemini Live session.
export default async function handler(req, res) {
  const missing = REQUIRED_ENV.filter((k) => !process.env[k]);
  if (missing.length > 0) {
    res.status(500).json({ error: 'missing_env', missing });
    return;
  }

  if (req.method !== 'POST') {
    res.status(405).json({ error: 'method_not_allowed' });
    return;
  }

  const body = typeof req.body === 'string' ? safeParse(req.body) : (req.body ?? {});
  const { auth, action } = body;
  if (!auth) {
    res.status(401).json({ error: 'missing_auth' });
    return;
  }
  if (action !== 'summon' && action !== 'dismiss') {
    res.status(400).json({ error: 'invalid_action' });
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

  // Server SDK clients want an http(s) origin; LIVEKIT_URL is wss://.
  const host = process.env.LIVEKIT_URL.replace(/^ws/, 'http');
  const key = process.env.LIVEKIT_API_KEY;
  const secret = process.env.LIVEKIT_API_SECRET;

  res.setHeader('Cache-Control', 'no-store');
  try {
    if (action === 'summon') {
      const dispatch = new AgentDispatchClient(host, key, secret);
      const d = await dispatch.createDispatch(ROOM, COACH_AGENT_NAME);
      res.status(200).json({ ok: true, action, dispatchId: d.id ?? null });
    } else {
      const rooms = new RoomServiceClient(host, key, secret);
      const participants = await rooms.listParticipants(ROOM);
      // Agent participants get an `agent-` identity prefix (LiveKit Agents
      // convention); only our coach is ever dispatched here.
      const agents = participants.filter((p) => p.identity?.startsWith('agent-'));
      await Promise.all(agents.map((p) => rooms.removeParticipant(ROOM, p.identity)));
      res.status(200).json({ ok: true, action, removed: agents.length });
    }
  } catch (err) {
    res.status(502).json({ error: 'livekit_error', detail: String(err?.message ?? err) });
  }
}

function safeParse(s) {
  try {
    return JSON.parse(s);
  } catch {
    return {};
  }
}
