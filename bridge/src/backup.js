import fs from 'node:fs';
import path from 'node:path';

const SRC = '/actual-user-files';
const DEST = '/backups';
const KEEP = 30;
let last = 0;

/** Snapshot the server's budget files before a write session (at most once per 10 min unless forced). */
export function backupBeforeWrite(force = false) {
  if (!force && Date.now() - last < 10 * 60 * 1000) return;
  last = Date.now();
  try {
    const dir = path.join(DEST, new Date().toISOString().replace(/[:.]/g, '-'));
    fs.mkdirSync(dir, { recursive: true });
    for (const f of fs.readdirSync(SRC)) fs.copyFileSync(path.join(SRC, f), path.join(dir, f));
    const all = fs.readdirSync(DEST).sort();
    for (const old of all.slice(0, Math.max(0, all.length - KEEP))) {
      fs.rmSync(path.join(DEST, old), { recursive: true, force: true });
    }
  } catch (e) {
    last = 0; // retry next time; never let backup trouble silently hide behind a write
    throw new Error(`Backup failed, refusing to write: ${e.message}`);
  }
}

/** Timestamped snapshots, newest first. */
export function listBackups() {
  try {
    return fs.readdirSync(DEST).filter((d) => /^\d{4}-\d{2}-\d{2}T/.test(d)).sort().reverse();
  } catch { return []; }
}
