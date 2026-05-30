import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { SignJWT } from 'jose';

const { deleteRoom } = vi.hoisted(() => ({ deleteRoom: vi.fn() }));

// Regular function expression, not an arrow — the handler uses `new`.
vi.mock('livekit-server-sdk', () => ({
  RoomServiceClient: vi.fn(function () { return { deleteRoom }; }),
}));

import handler from './close-room.js';

const TEST_PUBLISHER_SECRET = 'test-publisher-secret-do-not-use-in-prod';
const TEST_ROOM = 'waza-proto-abc123def456';

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

const post = ({ auth, room } = {}) => ({
  method: 'POST',
  body: auth === undefined ? {} : { auth },
  query: room === undefined ? {} : { room },
});

describe('viewer/api/close-room handler', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = {
      ...originalEnv,
      PUBLISHER_SIGNING_SECRET: TEST_PUBLISHER_SECRET,
      LIVEKIT_API_KEY: 'APItest1234567890',
      LIVEKIT_API_SECRET: 'test-livekit-api-secret-must-be-at-least-32-chars-long',
      LIVEKIT_URL: 'wss://test.livekit.cloud',
    };
    deleteRoom.mockReset();
    deleteRoom.mockResolvedValue(undefined);
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
    await handler(post({ room: TEST_ROOM }), res);
    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('missing_auth');
  });

  it('wrong sub → 401 invalid_auth', async () => {
    const auth = await mintAuth({ sub: 'someone-else' });
    const res = mockResponse();
    await handler(post({ auth, room: TEST_ROOM }), res);
    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('invalid_auth');
  });

  it('valid → deleteRoom(room) and 200', async () => {
    const auth = await mintAuth();
    const res = mockResponse();
    await handler(post({ auth, room: TEST_ROOM }), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toMatchObject({ ok: true, room: TEST_ROOM });
    expect(deleteRoom).toHaveBeenCalledTimes(1);
    expect(deleteRoom).toHaveBeenCalledWith(TEST_ROOM);
  });

  it('missing room → 400 missing_room', async () => {
    const auth = await mintAuth();
    const res = mockResponse();
    await handler(post({ auth }), res);
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toBe('missing_room');
    expect(deleteRoom).not.toHaveBeenCalled();
  });

  it('deleteRoom failure → 502 livekit_error', async () => {
    deleteRoom.mockRejectedValue(new Error('boom'));
    const auth = await mintAuth();
    const res = mockResponse();
    await handler(post({ auth, room: TEST_ROOM }), res);
    expect(res.statusCode).toBe(502);
    expect(res.body.error).toBe('livekit_error');
  });

  it('missing env → 500 missing_env', async () => {
    delete process.env.LIVEKIT_API_SECRET;
    const res = mockResponse();
    await handler(post({ auth: 'unused', room: TEST_ROOM }), res);
    expect(res.statusCode).toBe(500);
    expect(res.body.error).toBe('missing_env');
  });
});
