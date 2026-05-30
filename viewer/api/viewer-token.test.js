import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { SignJWT, decodeJwt } from 'jose';

// Mock only RoomServiceClient (network); keep the real AccessToken so we can
// decode the minted token and assert its grants.
const { listRooms } = vi.hoisted(() => ({ listRooms: vi.fn() }));
vi.mock('livekit-server-sdk', async (importOriginal) => {
  const actual = await importOriginal();
  return {
    ...actual,
    RoomServiceClient: vi.fn(function () { return { listRooms }; }),
  };
});

import handler from './viewer-token.js';

const TEST_INVITE_SECRET = 'test-invite-secret-do-not-use-in-prod';
const TEST_LIVEKIT_KEY = 'APItest1234567890';
const TEST_LIVEKIT_SECRET = 'test-livekit-api-secret-must-be-at-least-32-chars-long';
const TEST_LIVEKIT_URL = 'wss://test.livekit.cloud';
const TEST_ROOM = 'waza-proto-abc123def456';

// `room: null` mints a roomless invite (pre-feature shape). A default param of
// TEST_ROOM would be re-applied to an explicit `undefined`, so the opt-out is null.
async function mintInvite({
  secret = TEST_INVITE_SECRET,
  room = TEST_ROOM,
  expiresIn = '3h',
} = {}) {
  const key = new TextEncoder().encode(secret);
  const payload = room === null ? {} : { room };
  return await new SignJWT(payload)
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

describe('viewer/api/viewer-token handler', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = {
      ...originalEnv,
      INVITE_SIGNING_SECRET: TEST_INVITE_SECRET,
      LIVEKIT_API_KEY: TEST_LIVEKIT_KEY,
      LIVEKIT_API_SECRET: TEST_LIVEKIT_SECRET,
      LIVEKIT_URL: TEST_LIVEKIT_URL,
    };
    listRooms.mockReset();
    listRooms.mockResolvedValue([{ name: TEST_ROOM }]);
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it('missing invite param → 401 missing_invite', async () => {
    const res = mockResponse();
    await handler({ query: {} }, res);

    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('missing_invite');
  });

  it('valid invite + live room → mints a subscribe-only token scoped to the room', async () => {
    const invite = await mintInvite();
    const res = mockResponse();
    await handler({ query: { invite } }, res);

    expect(res.statusCode).toBe(200);
    expect(res.body.url).toBe(TEST_LIVEKIT_URL);
    expect(res.headers['Cache-Control']).toBe('no-store');

    expect(listRooms).toHaveBeenCalledWith([TEST_ROOM]);

    const claims = decodeJwt(res.body.token);
    expect(claims.video?.room).toBe(TEST_ROOM);
    expect(claims.video?.canSubscribe).toBe(true);
    expect(claims.video?.canPublish).toBe(false);
    expect(claims.exp - claims.nbf).toBe(10 * 60);
  });

  it('closed session (room gone) → 403 session_ended', async () => {
    listRooms.mockResolvedValue([]);
    const invite = await mintInvite();
    const res = mockResponse();
    await handler({ query: { invite } }, res);

    expect(res.statusCode).toBe(403);
    expect(res.body.error).toBe('session_ended');
  });

  it('invite without room claim → 400 missing_room', async () => {
    const invite = await mintInvite({ room: null });
    const res = mockResponse();
    await handler({ query: { invite } }, res);

    expect(res.statusCode).toBe(400);
    expect(res.body.error).toBe('missing_room');
    expect(listRooms).not.toHaveBeenCalled();
  });

  it('tampered invite → 401 invalid_invite', async () => {
    const invite = await mintInvite();
    const tampered = invite.slice(0, -4) + 'AAAA';
    const res = mockResponse();
    await handler({ query: { invite: tampered } }, res);

    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('invalid_invite');
  });

  it('expired invite → 401 invite_expired', async () => {
    const key = new TextEncoder().encode(TEST_INVITE_SECRET);
    const now = Math.floor(Date.now() / 1000);
    const invite = await new SignJWT({ room: TEST_ROOM })
      .setProtectedHeader({ alg: 'HS256' })
      .setIssuedAt(now - 600)
      .setExpirationTime(now - 60)
      .sign(key);
    const res = mockResponse();
    await handler({ query: { invite } }, res);

    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('invite_expired');
  });

  it('listRooms failure → 502 livekit_error', async () => {
    listRooms.mockRejectedValue(new Error('boom'));
    const invite = await mintInvite();
    const res = mockResponse();
    await handler({ query: { invite } }, res);

    expect(res.statusCode).toBe(502);
    expect(res.body.error).toBe('livekit_error');
  });

  it('missing env → 500 missing_env', async () => {
    delete process.env.LIVEKIT_API_SECRET;
    const res = mockResponse();
    await handler({ query: {} }, res);

    expect(res.statusCode).toBe(500);
    expect(res.body.error).toBe('missing_env');
  });
});
