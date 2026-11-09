// Settings page: preferences, payee classification, connections, data export, backups, maintenance.
import { redownload, withBudget } from './actual.js';
import { backupBeforeWrite, listBackups } from './backup.js';
import { loadLedger, payeeOf } from './finance.js';
import {
  DEFAULT_CLASSIFICATION, DEFAULT_PREFERENCES, classification, hiddenAccounts, pairSettings, preferences, updateSection,
} from './settings.js';

/** The self-balancing category's id and name, or null until one is chosen or first used. */
async function selfBalancingInfo(api) {
  const { selfBalancing } = pairSettings();
  if (!selfBalancing) return null;
  const c = (await api.getCategories()).find((x) => x.id === selfBalancing);
  return c ? { id: c.id, name: c.name } : null;
}

const PREF_KEYS = Object.keys(DEFAULT_PREFERENCES);
const csvCell = (v) => {
  const s = v == null ? '' : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

export function registerSettings(app) {
  app.get('/api/settings', () =>
    withBudget(async (api) => {
      const { q, aqlQuery } = api;
      const accounts = (await aqlQuery(q('accounts').filter({ closed: false }).select(['id', 'name', 'account_sync_source', 'last_sync']))).data;
      const hidden = hiddenAccounts();
      let serverVersion = null;
      try { serverVersion = (await api.getServerVersion())?.version ?? null; } catch { /* offline */ }
      const backups = listBackups();
      return {
        preferences: preferences(),
        classification: classification(),
        defaults: { classification: DEFAULT_CLASSIFICATION },
        connections: accounts.filter((a) => !hidden.has(a.id)).map((a) => ({
          id: a.id, name: a.name, source: a.account_sync_source || null,
          lastSync: a.last_sync ? new Date(Number(a.last_sync)).toISOString() : null,
        })),
        backups: { count: backups.length, latest: backups[0] || null },
        selfBalancing: await selfBalancingInfo(api),
        about: { serverVersion, bridgeVersion: process.env.npm_package_version || null },
      };
    }));

  app.put('/api/settings/preferences', (req) => {
    const patch = Object.fromEntries(Object.entries(req.body || {}).filter(([k]) => PREF_KEYS.includes(k)));
    updateSection('preferences', patch);
    return preferences();
  });

  // Lists of payee patterns; pass null for a list to go back to the default.
  app.put('/api/settings/classification', (req) => {
    const patch = {};
    for (const k of Object.keys(DEFAULT_CLASSIFICATION)) {
      if (!(k in (req.body || {}))) continue;
      const v = req.body[k];
      if (v !== null && !(Array.isArray(v) && v.every((x) => typeof x === 'string'))) throw new Error(`${k} must be a list of text`);
      for (const p of v || []) {
        try { new RegExp(p); } catch { throw new Error(`"${p}" isn't a valid pattern`); }
      }
      patch[k] = v === null ? undefined : v.map((x) => x.trim()).filter(Boolean);
    }
    updateSection('classification', patch);
    return classification();
  });

  app.post('/api/backup', () => {
    backupBeforeWrite(true);
    const b = listBackups();
    return { count: b.length, latest: b[0] || null };
  });

  app.post('/api/maintenance/redownload', async () => {
    await redownload();
    return { ok: true };
  });

  // All visible-account transactions as CSV. Optional from/to (YYYY-MM-DD).
  app.get('/api/export.csv', (req, reply) =>
    withBudget(async (api) => {
      const { txs, accts } = await loadLedger(api);
      const { from, to } = req.query;
      const names = new Map(accts.map((a) => [a.id, a.name]));
      const rows = txs
        .filter((t) => names.has(t.account) && (!from || t.date >= from) && (!to || t.date <= to))
        .sort((a, b) => b.date.localeCompare(a.date));
      const lines = [['Date', 'Account', 'Payee', 'Category group', 'Category', 'Amount', 'Transfer'].join(',')];
      for (const t of rows) {
        lines.push([
          t.date, names.get(t.account), payeeOf(t), t['category.group.name'], t['category.name'],
          (t.amount / 100).toFixed(2), t.transfer_id ? 'yes' : '',
        ].map(csvCell).join(','));
      }
      reply.header('content-type', 'text/csv; charset=utf-8');
      reply.header('content-disposition', `attachment; filename="transactions${from ? `-${from}` : ''}${to ? `-to-${to}` : ''}.csv"`);
      return lines.join('\n');
    }));
}
