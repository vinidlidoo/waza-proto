import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { SignJWT, decodeJwt } from 'jose';

// Mock only RoomServiceClient (network); keep the real AccessToken so we can
// decode the minted token and assert its grants.
const { createRoom } = vi.hoisted(() => ({ createRoom: vi.fn() }));
vi.mock('livekit-server-sdk', async (importOriginal) => {
  const actual = await importOriginal();
  return {
    ...actual,
    RoomServiceClient: vi.fn(function () { return { createRoom }; }),
  };
});

import handler from './publisher-token.js';

const TEST_PUBLISHER_SECRET = 'test-publisher-secret-do-not-use-in-prod';
const TEST_LIVEKIT_KEY = 'APItest1234567890';
const TEST_LIVEKIT_SECRET = 'test-livekit-api-secret-must-be-at-least-32-chars-long';
const TEST_LIVEKIT_URL = 'wss://test.livekit.cloud';
const TEST_ROOM = 'waza-proto-abc123def456';

async function mintAuth({
  secret = TEST_PUBLISHER_SECRET,
  sub = 'ios-publisher',
  expiresIn = '2m',
} = {}) {
  const key = new TextEncoder().encode(secret);
  return await new SignJWT({ sub })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime(expiresIn)
    .sign(key);
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

describe('viewer/api/publisher-token handler', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = {
      ...originalEnv,
      PUBLISHER_SIGNING_SECRET: TEST_PUBLISHER_SECRET,
      LIVEKIT_API_KEY: TEST_LIVEKIT_KEY,
      LIVEKIT_API_SECRET: TEST_LIVEKIT_SECRET,
      LIVEKIT_URL: TEST_LIVEKIT_URL,
    };
    createRoom.mockReset();
    createRoom.mockResolvedValue({ sid: 'RM_test', name: TEST_ROOM });
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it('missing auth param → 401 missing_auth', async () => {
    const res = mockResponse();
    await handler({ query: { room: TEST_ROOM } }, res);

    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('missing_auth');
  });

  it('valid auth + room → creates the room and mints a publisher token scoped to it', async () => {
    const auth = await mintAuth();
    const res = mockResponse();
    await handler({ query: { auth, room: TEST_ROOM } }, res);

    expect(res.statusCode).toBe(200);
    expect(res.body.url).toBe(TEST_LIVEKIT_URL);
    expect(res.headers['Cache-Control']).toBe('no-store');

    expect(createRoom).toHaveBeenCalledTimes(1);
    expect(createRoom).toHaveBeenCalledWith(
      expect.objectContaining({ name: TEST_ROOM }),
    );
    expect(typeof createRoom.mock.calls[0][0].emptyTimeout).toBe('number');

    const claims = decodeJwt(res.body.token);
    expect(claims.sub).toBe('ios-publisher');
    expect(claims.exp - claims.nbf).toBe(2 * 60 * 60);
    expect(claims.video?.room).toBe(TEST_ROOM);
    expect(claims.video?.roomJoin).toBe(true);
    expect(claims.video?.canPublish).toBe(true);
    // Publisher subscribes to the coach agent's audio (plan 19).
    expect(claims.video?.canSubscribe).toBe(true);
  });

  it('missing room param → 400 missing_room (no room created)', async () => {
    const auth = await mintAuth();
    const res = mockResponse();
    await handler({ query: { auth } }, res);

    expect(res.statusCode).toBe(400);
    expect(res.body.error).toBe('missing_room');
    expect(createRoom).not.toHaveBeenCalled();
  });

  it('malformed room name → 400 invalid_room', async () => {
    const auth = await mintAuth();
    const res = mockResponse();
    await handler({ query: { auth, room: 'attacker-room' } }, res);

    expect(res.statusCode).toBe(400);
    expect(res.body.error).toBe('invalid_room');
    expect(createRoom).not.toHaveBeenCalled();
  });

  it('createRoom failure → 502 livekit_error', async () => {
    createRoom.mockRejectedValue(new Error('boom'));
    const auth = await mintAuth();
    const res = mockResponse();
    await handler({ query: { auth, room: TEST_ROOM } }, res);

    expect(res.statusCode).toBe(502);
    expect(res.body.error).toBe('livekit_error');
  });

  it('tampered auth → 401 invalid_auth', async () => {
    const auth = await mintAuth();
    const tampered = auth.slice(0, -4) + 'AAAA';
    const res = mockResponse();
    await handler({ query: { auth: tampered, room: TEST_ROOM } }, res);

    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('invalid_auth');
  });

  it('expired auth → 401 auth_expired', async () => {
    const key = new TextEncoder().encode(TEST_PUBLISHER_SECRET);
    const now = Math.floor(Date.now() / 1000);
    const auth = await new SignJWT({ sub: 'ios-publisher' })
      .setProtectedHeader({ alg: 'HS256' })
      .setIssuedAt(now - 600)
      .setExpirationTime(now - 60)
      .sign(key);
    const res = mockResponse();
    await handler({ query: { auth, room: TEST_ROOM } }, res);

    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('auth_expired');
  });

  it('wrong sub claim → 401 invalid_auth', async () => {
    const auth = await mintAuth({ sub: 'someone-else' });
    const res = mockResponse();
    await handler({ query: { auth, room: TEST_ROOM } }, res);

    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('invalid_auth');
  });

  it('missing env vars → 500 listing the missing keys', async () => {
    delete process.env.PUBLISHER_SIGNING_SECRET;
    delete process.env.LIVEKIT_API_SECRET;
    const res = mockResponse();
    await handler({ query: {} }, res);

    expect(res.statusCode).toBe(500);
    expect(res.body.error).toBe('missing_env');
    expect(res.body.missing).toEqual(
      expect.arrayContaining(['PUBLISHER_SIGNING_SECRET', 'LIVEKIT_API_SECRET']),
    );
  });
});
