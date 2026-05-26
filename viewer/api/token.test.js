import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { SignJWT, decodeJwt } from 'jose';
import handler from './token.js';

const TEST_INVITE_SECRET = 'test-invite-secret-do-not-use-in-prod';
const TEST_LIVEKIT_KEY = 'APItest1234567890';
const TEST_LIVEKIT_SECRET = 'test-livekit-api-secret-must-be-at-least-32-chars-long';
const TEST_LIVEKIT_URL = 'wss://test.livekit.cloud';

async function mintInvite({ secret = TEST_INVITE_SECRET, expiresIn = '1h' } = {}) {
  const key = new TextEncoder().encode(secret);
  return await new SignJWT({})
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

describe('viewer/api/token handler', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = {
      ...originalEnv,
      INVITE_SIGNING_SECRET: TEST_INVITE_SECRET,
      LIVEKIT_API_KEY: TEST_LIVEKIT_KEY,
      LIVEKIT_API_SECRET: TEST_LIVEKIT_SECRET,
      LIVEKIT_URL: TEST_LIVEKIT_URL,
    };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it('valid invite → mints a viewer- token with 10m TTL', async () => {
    const invite = await mintInvite();
    const res = mockResponse();
    await handler({ query: { invite } }, res);

    expect(res.statusCode).toBe(200);
    expect(res.body.url).toBe(TEST_LIVEKIT_URL);
    expect(res.headers['Cache-Control']).toBe('no-store');

    const claims = decodeJwt(res.body.token);
    expect(claims.sub).toMatch(/^viewer-[0-9a-f]{8}$/);
    expect(claims.exp - claims.nbf).toBe(600);
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
    const invite = await new SignJWT({})
      .setProtectedHeader({ alg: 'HS256' })
      .setIssuedAt(now - 3600)
      .setExpirationTime(now - 60)
      .sign(key);
    const res = mockResponse();
    await handler({ query: { invite } }, res);

    expect(res.statusCode).toBe(401);
    expect(res.body.error).toBe('invite_expired');
  });

  it('missing env vars → 500 with clear error listing the missing keys', async () => {
    delete process.env.INVITE_SIGNING_SECRET;
    delete process.env.LIVEKIT_API_SECRET;
    const res = mockResponse();
    await handler({ query: {} }, res);

    expect(res.statusCode).toBe(500);
    expect(res.body.error).toBe('missing_env');
    expect(res.body.missing).toEqual(
      expect.arrayContaining(['INVITE_SIGNING_SECRET', 'LIVEKIT_API_SECRET']),
    );
  });

  it('different invites → distinct viewer identities (no collisions)', async () => {
    const results = await Promise.all(
      Array.from({ length: 20 }, async () => {
        const invite = await mintInvite();
        const res = mockResponse();
        await handler({ query: { invite } }, res);
        return decodeJwt(res.body.token).sub;
      }),
    );
    expect(new Set(results).size).toBe(20);
  });
});
