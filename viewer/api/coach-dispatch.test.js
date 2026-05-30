import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { SignJWT } from 'jose';

const { createDispatch, listParticipants, removeParticipant } = vi.hoisted(() => ({
  createDispatch: vi.fn(),
  listParticipants: vi.fn(),
  removeParticipant: vi.fn(),
}));

// Regular function expressions, not arrows — the handler uses `new` on these.
vi.mock('livekit-server-sdk', () => ({
  AgentDispatchClient: vi.fn(function () { return { createDispatch }; }),
  RoomServiceClient: vi.fn(function () { return { listParticipants, removeParticipant }; }),
}));

import handler from './coach-dispatch.js';

const TEST_PUBLISHER_SECRET = 'test-publisher-secret-do-not-use-in-prod';

async function mintAuth({ secret = TEST_PUBLISHER_SECRET, sub = 'ios-publisher', expiresIn = '2m' } = {}) {
  return await new SignJWT({ sub })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime(expiresIn)
    .sign(new TextEncoder().encode(secret));
}

function mockResponse() {
  return {
    statusCode: null,
    body: null,
    headers: {},
    status(c) { this.statusCode = c; return this; },
    json(p) { this.body = p; return this; },
    setHeader(n, v) { this.headers[n] = v; return this; },
  };
}

const post = (body) => ({ method: 'POST', body });

const TEST_ROOM = 'waza-proto-abc123def456';

describe('viewer/api/coach-dispatch handler', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = {
      ...originalEnv,
      PUBLISHER_SIGNING_SECRET: TEST_PUBLISHER_SECRET,
      LIVEKIT_API_KEY: 'APItest1234567890',
      LIVEKIT_API_SECRET: 'test-livekit-api-secret-must-be-at-least-32-chars-long',
      LIVEKIT_URL: 'wss://test.livekit.cloud',
    };
    createDispatch.mockReset();
    listParticipants.mockReset();
    removeParticipant.mockReset();
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it('non-POST → 405', async () => {
    const res = mockResponse();
    await handler({ method: 'GET', query: {} }, res);
    expect(res.statusCode).toBe(405);
  });

  it('missing auth → 401 missing_auth', async () => {
    const res = mockResponse();
    await handler(post({ action: 'summon' }), res);
    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('missing_auth');
  });

  it('invalid action → 400 invalid_action', async () => {
    const auth = await mintAuth();
    const res = mockResponse();
    await handler(post({ auth, action: 'nope' }), res);
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toBe('invalid_action');
  });

  it('wrong sub → 401 invalid_auth', async () => {
    const auth = await mintAuth({ sub: 'someone-else' });
    const res = mockResponse();
    await handler(post({ auth, action: 'summon', room: TEST_ROOM }), res);
    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('invalid_auth');
  });

  it('missing room → 400 missing_room', async () => {
    const auth = await mintAuth();
    const res = mockResponse();
    await handler(post({ auth, action: 'summon' }), res);
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toBe('missing_room');
    expect(createDispatch).not.toHaveBeenCalled();
  });

  it('summon → creates a dispatch for waza-coach in the session room', async () => {
    createDispatch.mockResolvedValue({ id: 'AD_abc123' });
    const auth = await mintAuth();
    const res = mockResponse();
    await handler(post({ auth, action: 'summon', room: TEST_ROOM }), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toMatchObject({ ok: true, action: 'summon', dispatchId: 'AD_abc123' });
    expect(createDispatch).toHaveBeenCalledWith(TEST_ROOM, 'waza-coach');
  });

  it('dismiss → removes only the agent participant(s) from the session room', async () => {
    listParticipants.mockResolvedValue([
      { identity: 'ios-publisher' },
      { identity: 'agent-AJ_xyz' },
      { identity: 'viewer-9f3a2b1c' },
    ]);
    removeParticipant.mockResolvedValue(undefined);
    const auth = await mintAuth();
    const res = mockResponse();
    await handler(post({ auth, action: 'dismiss', room: TEST_ROOM }), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toMatchObject({ ok: true, action: 'dismiss', removed: 1 });
    expect(removeParticipant).toHaveBeenCalledTimes(1);
    expect(removeParticipant).toHaveBeenCalledWith(TEST_ROOM, 'agent-AJ_xyz');
  });

  it('missing env → 500 missing_env', async () => {
    delete process.env.LIVEKIT_API_SECRET;
    const res = mockResponse();
    await handler(post({ action: 'summon', room: TEST_ROOM }), res);
    expect(res.statusCode).toBe(500);
    expect(res.body.error).toBe('missing_env');
  });
});
