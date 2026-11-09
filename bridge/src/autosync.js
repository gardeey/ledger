// Background bank sync: Actual only pulls from SimpleFIN when a client asks, so the bridge asks on a timer.
import { withBudget } from './actual.js';
import { write } from './routes.js';

const HOURS = Number(process.env.BANK_SYNC_HOURS ?? 4); // 0 disables
const CHECK_MS = 15 * 60 * 1000;
let running = false;
let lastAttempt = 0; // failures don't update last_sync, so also wait out the interval after any attempt

/** Oldest last_sync (ms) across open bank-linked accounts, or null when none are linked. */
async function oldestSync() {
  return withBudget(async ({ q, aqlQuery }) => {
    const rows = (await aqlQuery(q('accounts').filter({ closed: false }).select(['account_sync_source', 'last_sync']))).data
      .filter((a) => a.account_sync_source);
    if (!rows.length) return null;
    return Math.min(...rows.map((a) => Number(a.last_sync) || 0));
  });
}

// Keyed off each account's last_sync rather than a plain interval, so restarts don't burn SimpleFIN's daily quota.
async function tick(log) {
  if (running) return;
  running = true;
  try {
    const due = Date.now() - HOURS * 3600 * 1000;
    if (lastAttempt > due) return;
    const oldest = await oldestSync();
    if (oldest == null || oldest > due) return;
    lastAttempt = Date.now();
    log.info('auto bank sync starting');
    await write((api) => api.runBankSync());
    log.info('auto bank sync finished');
  } catch (e) {
    log.error({ err: e }, 'auto bank sync failed');
  } finally {
    running = false;
  }
}

export function startAutoSync(log) {
  if (!(HOURS > 0)) return;
  setTimeout(() => tick(log), 60 * 1000);
  setInterval(() => tick(log), CHECK_MS);
}
