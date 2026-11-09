import * as api from '@actual-app/api';
import fs from 'node:fs';

let ready = null;

export function init() {
  if (!ready) {
    ready = (async () => {
      const dataDir = process.env.ACTUAL_DATA_DIR || '/cache';
      fs.mkdirSync(dataDir, { recursive: true });
      await api.init({
        dataDir,
        serverURL: process.env.ACTUAL_SERVER_URL,
        password: process.env.ACTUAL_PASSWORD,
      });
      await api.downloadBudget(process.env.ACTUAL_SYNC_ID, {
        password: process.env.ACTUAL_BUDGET_PASSWORD || undefined,
      });
    })().catch((e) => { ready = null; throw e; });
  }
  return ready;
}

/** Drop the loaded budget and download it fresh from the server (recovers from sync state drift). */
export async function reload() {
  try { await api.shutdown(); } catch { /* already closed */ }
  ready = null;
  await init();
}

/**
 * Move the local budget copy aside (to /backups/stale-cache) and download it fresh from the server.
 * Fixes a cache that has drifted out of sync; the server copy is the source of truth.
 */
export async function redownload() {
  const dataDir = process.env.ACTUAL_DATA_DIR || '/cache';
  try { await api.shutdown(); } catch { /* already closed */ }
  ready = null;
  const dest = '/backups/stale-cache';
  fs.mkdirSync(dest, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  for (const d of fs.readdirSync(dataDir, { withFileTypes: true })) {
    // Budget folders hold a metadata.json; our own JSON settings files stay put.
    if (d.isDirectory() && fs.existsSync(`${dataDir}/${d.name}/metadata.json`)) {
      // Different Docker volumes, so copy then remove (rename can't cross devices).
      fs.cpSync(`${dataDir}/${d.name}`, `${dest}/${d.name}-${stamp}`, { recursive: true });
      fs.rmSync(`${dataDir}/${d.name}`, { recursive: true, force: true });
    }
  }
  await init();
}

export async function withBudget(fn) {
  await init();
  return fn(api);
}
