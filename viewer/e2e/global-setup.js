// Loads .env into process.env, creates a per-run session room (plan 23), mints
// a test invite (with the signed room claim) via the same signing key the
// deployed token endpoint uses, and spawns `lk room join --publish` against that
// room with a test pattern. The publisher PID and room name are passed to
// global-teardown via small files so the test runner can clean both up.

import { config as loadEnv } from 'dotenv';
import { SignJWT } from 'jose';
import { RoomServiceClient } from 'livekit-server-sdk';
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

    // Per-session room (plan 23): rooms are waza-proto-{nonce} and, with project
    // auto-create OFF, must exist before anyone joins. Create a unique per-run
    // room here; global-teardown deletes it via the .e2e-room marker file.
    const room = `waza-proto-e2e${Date.now()}`;
    const host = process.env.LIVEKIT_URL.replace(/^ws/, 'http');
    const svc = new RoomServiceClient(host, process.env.LIVEKIT_API_KEY, process.env.LIVEKIT_API_SECRET);
    await svc.createRoom({ name: room, emptyTimeout: 300 });
    await writeFile(resolve(__dirname, '.e2e-room'), room);

    // Mint a 3h invite carrying the signed room claim the token endpoint needs.
    // Identity prefix matches the production mint flow ("e2e-") so the
    // viewer-filter test won't count it.
    const secret = new TextEncoder().encode(process.env.INVITE_SIGNING_SECRET);
    const invite = await new SignJWT({ room })
        .setProtectedHeader({ alg: 'HS256' })
        .setIssuedAt()
        .setExpirationTime('3h')
        .sign(secret);
    process.env.E2E_INVITE = invite;

    // Spawn the publisher in the background. `lk` reads URL/key/secret from
    // env (we already loaded .env), so we don't pass them on the CLI.
    const publisher = spawn('lk', [
        'room', 'join',
        '--room', room,
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
