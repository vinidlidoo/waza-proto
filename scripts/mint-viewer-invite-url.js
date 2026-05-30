#!/usr/bin/env node
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');
const envPath = resolve(repoRoot, '.env');

function parseEnv(text) {
  const env = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;
    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    env[match[1]] = value;
  }
  return env;
}

function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');
}

const env = { ...parseEnv(readFileSync(envPath, 'utf8')), ...process.env };
const secret = env.INVITE_SIGNING_SECRET;
if (!secret) {
  console.error('error: INVITE_SIGNING_SECRET missing from .env');
  process.exit(1);
}

// Invites are per-session now (plan 23): the room is a signed claim the viewer
// endpoint trusts for the room name. Pass the live `waza-proto-<nonce>` room.
const room = process.argv[2] || env.INVITE_ROOM;
if (!room) {
  console.error('usage: mint-viewer-invite-url.js <room>   (or set INVITE_ROOM)');
  console.error('  room = the live per-session room, e.g. waza-proto-<nonce>');
  process.exit(1);
}

const now = Math.floor(Date.now() / 1000);
const ttlSeconds = Number(env.INVITE_TTL_SECONDS || 3 * 60 * 60);
const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
const payload = base64url(JSON.stringify({ room, iat: now, exp: now + ttlSeconds }));
const signingInput = `${header}.${payload}`;
const signature = createHmac('sha256', secret).update(signingInput).digest('base64url');
const invite = `${signingInput}.${signature}`;
const baseURL = env.VIEWER_BASE_URL || 'http://localhost:4173';
const url = new URL(baseURL);

url.searchParams.set('invite', invite);
url.searchParams.set('debugStats', '1');
console.log(url.toString());
