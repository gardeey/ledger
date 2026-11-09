// App settings that Actual has no place for, stored beside the budget cache.
import fs from 'node:fs';
import path from 'node:path';

const FILE = path.join(process.env.ACTUAL_DATA_DIR || '/cache', 'ledger-settings.json');

export function readSettings() {
  const empty = { hiddenAccounts: [], accountTypes: {}, preferences: {}, classification: {} };
  try { return { ...empty, ...JSON.parse(fs.readFileSync(FILE, 'utf8')) }; } catch { return empty; }
}

export function saveSettings(settings) {
  fs.writeFileSync(`${FILE}.tmp`, JSON.stringify(settings, null, 2));
  fs.renameSync(`${FILE}.tmp`, FILE);
}

/** Accounts the user hid: excluded from every summary, chart and list. */
export const hiddenAccounts = () => new Set(readSettings().hiddenAccounts);

export function setAccountHidden(id, hidden) {
  const s = readSettings();
  const ids = new Set(s.hiddenAccounts);
  if (hidden) ids.add(id); else ids.delete(id);
  saveSettings({ ...s, hiddenAccounts: [...ids] });
}

/** Account type chosen by the user (overrides the guess from the account name). */
export function setAccountType(id, type) {
  const s = readSettings();
  saveSettings({ ...s, accountTypes: { ...s.accountTypes, [id]: type } });
}

export const DEFAULT_PREFERENCES = { theme: 'system', hideAmounts: false, defaultRange: 'm1', hiddenPages: [] };

// Each entry is a case-insensitive pattern matched against the payee name.
export const DEFAULT_CLASSIFICATION = {
  transferPayees: (process.env.TRANSFER_PAYEE_REGEX || 'bill payment|payment.*thank|transfer|^amex$|credit card pmt').split('|'),
  investPayees: (process.env.INVEST_PAYEE_REGEX || 'sun ?life|questrade|fidelity|wealthsimple').split('|'),
};

export const preferences = () => ({ ...DEFAULT_PREFERENCES, ...readSettings().preferences });
export const classification = () => ({ ...DEFAULT_CLASSIFICATION, ...readSettings().classification });

/** Self-balancing category id (money that leaves and comes back), and "out|in" pairs dismissed as not a pair. */
export const pairSettings = () => ({ selfBalancing: null, dismissed: [], ...readSettings().pairs });

export function updateSection(section, patch) {
  const s = readSettings();
  saveSettings({ ...s, [section]: { ...s[section], ...patch } });
}
