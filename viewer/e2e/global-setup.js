// Loads .env into process.env, mints a test invite via the same signing key
// the deployed token endpoint uses, and spawns `lk room join --publish`
// against the waza-proto room with a test pattern. The publisher PID is
// passed to global-teardown via a small file so the test runner can kill it
// cleanly.

import { config as loadEnv } from 'dotenv';
import { SignJWT } from 'jose';
import { spawn } from 'node:child_process';
import { writeFile, unlink } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..', '..');
const ASSET = resolve(REPO_ROOT, 'assets', 'testsrc.h264');
const PUBLISHER_PID_FILE = resolve(__dirname, '.publisher.pid');

export default async function globalSetup() {
    loadEnv({ path: resolve(REPO_ROOT, '.env') });

    // Clear any stale PID file from a crashed prior run — otherwise teardown
    // could SIGTERM a recycled PID belonging to an unrelated process.
    try { await unlink(PUBLISHER_PID_FILE); } catch {}

    for (const key of ['INVITE_SIGNING_SECRET', 'LIVEKIT_API_KEY', 'LIVEKIT_API_SECRET', 'LIVEKIT_URL']) {
        if (!process.env[key]) throw new Error(`missing env var ${key}; check repo-root .env`);
    }

    // Mint a 3h invite — same envelope shape scripts/mint-token.sh produces
    // but inline so the test is self-contained. Identity prefix matches the
    // production mint flow ("e2e-") so the viewer-filter test won't count it.
    const secret = new TextEncoder().encode(process.env.INVITE_SIGNING_SECRET);
    const invite = await new SignJWT({})
        .setProtectedHeader({ alg: 'HS256' })
        .setIssuedAt()
        .setExpirationTime('3h')
        .sign(secret);
    process.env.E2E_INVITE = invite;

    // Spawn the publisher in the background. `lk` reads URL/key/secret from
    // env (we already loaded .env), so we don't pass them on the CLI.
    const publisher = spawn('lk', [
        'room', 'join',
        '--room', 'waza-proto',
        '--identity', 'e2e-publisher',
        '--publish', ASSET,
        '--fps', '30',
    ], {
        env: process.env,
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: true,
    });

    publisher.stdout.on('data', (chunk) => {
        process.stdout.write(`[lk publisher] ${chunk}`);
    });
    publisher.stderr.on('data', (chunk) => {
        process.stderr.write(`[lk publisher err] ${chunk}`);
    });
    publisher.on('exit', (code, signal) => {
        if (code !== 0 && signal !== 'SIGTERM') {
            console.error(`[lk publisher] exited unexpectedly with code=${code} signal=${signal}`);
        }
    });

    await writeFile(PUBLISHER_PID_FILE, String(publisher.pid));

    // Give the publisher a moment to connect + start pushing frames before
    // the viewer test connects. Without this, the test often connects first
    // and races the publisher's TrackPublished event.
    await new Promise((r) => setTimeout(r, 3000));
}
