// Reads the publisher PID written by global-setup and SIGTERMs it. lk
// disconnects cleanly on SIGTERM; the room participant is gone within ~1s.

import { readFile, unlink } from 'node:fs/promises';
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
    try {
        process.kill(pid, 'SIGTERM');
    } catch (err) {
        if (err.code !== 'ESRCH') console.error('failed to kill publisher:', err);
    }
    try { await unlink(PUBLISHER_PID_FILE); } catch {}
}
