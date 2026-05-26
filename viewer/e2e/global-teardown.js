// Reads the publisher PID written by global-setup and SIGTERMs it. lk
// disconnects cleanly on SIGTERM; the room participant is gone within ~1s.

import { readFile, unlink } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLISHER_PID_FILE = resolve(__dirname, '.publisher.pid');

export default async function globalTeardown() {
    let pid;
    try {
        pid = Number(await readFile(PUBLISHER_PID_FILE, 'utf8'));
    } catch {
        return; // nothing to clean up
    }

    // Confirm the PID is actually our `lk` publisher before SIGTERM — if the
    // setup crashed mid-write or this PID got recycled, we'd kill an unrelated
    // process. `ps -o comm=` prints just the executable name.
    let comm = '';
    try {
        comm = execFileSync('ps', ['-p', String(pid), '-o', 'comm='], { encoding: 'utf8' }).trim();
    } catch {
        // PID gone already — nothing to clean, just drop the stale file below.
    }
    if (comm.endsWith('/lk') || comm === 'lk') {
        try {
            process.kill(pid, 'SIGTERM');
        } catch (err) {
            if (err.code !== 'ESRCH') console.error('failed to kill publisher:', err);
        }
    } else if (comm) {
        console.error(`[teardown] PID ${pid} is "${comm}", not lk — skipping kill`);
    }
    try { await unlink(PUBLISHER_PID_FILE); } catch {}
}
