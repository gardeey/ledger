// Shared ledger loading and classification for the dashboard and page endpoints.
// Amounts from Actual are integer cents; endpoints convert to dollars with usd().

export const LIABILITY_RE = /credit|visa|mastercard|amex|card|loan|mortgage|line of credit|loc\b/i;

// Payee patterns from Settings > Money rules (defaults in settings.js). Invalid patterns are skipped.
const toRegex = (patterns) => {
  const ok = patterns.map((p) => String(p).trim()).filter((p) => {
    if (!p) return false;
    try { new RegExp(p); return true; } catch { return false; }
  });
  return ok.length ? new RegExp(ok.join('|'), 'i') : /$^/;
};
/** Uncategorized payees that look like money moving between own accounts; payees that are investing. */
export const payeePatterns = () => {
  const c = classification();
  return { transferRe: toRegex(c.transferPayees), investRe: toRegex(c.investPayees) };
};
const INVEST_GROUP_RE = /invest/i;

// Account grouping (Actual has no account types, so go by name).
const LOAN_RE = /loan|mortgage|line of credit|loc\b/i;
const INVEST_ACCT_RE = /tfsa|rrsp|fhsa|resp|lira|rrif|portfolio|crypto|non_registered|brokerage|invest|401k|ira\b/i;
export const acctType = (name, liability) =>
  LOAN_RE.test(name) ? 'loan' : liability ? 'credit' : INVEST_ACCT_RE.test(name) ? 'investment' : 'cash';
// Display order. credit + loan are liabilities; the rest are assets.
export const TYPE_LABELS = {
  cash: 'Cash', investment: 'Investments', property: 'Real estate', vehicle: 'Vehicles', other: 'Other assets',
  credit: 'Credit cards', loan: 'Loans',
};
export const LIABILITY_TYPES = new Set(['credit', 'loan']);
/** Account type chosen in the app wins; otherwise guess from the name. */
export const isLiability = (a, accountTypes) =>
  (TYPE_LABELS[accountTypes[a.id]] ? LIABILITY_TYPES.has(accountTypes[a.id]) : LIABILITY_RE.test(a.name));

// Manual value changes (home revaluations, loan balance updates) aren't income or spending.
export const ADJUSTMENT_PAYEE = 'Balance adjustment';

export const pad = (n) => String(n).padStart(2, '0');
export const monthKey = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}`;
export const isoDay = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
export const monthEnd = (key) => {
  const [y, m] = key.split('-').map(Number);
  return `${key}-${pad(new Date(y, m, 0).getDate())}`;
};
export const addMonths = (key, n) => {
  const [y, m] = key.split('-').map(Number);
  return monthKey(new Date(y, m - 1 + n, 1));
};
export const usd = (c) => Math.round(c) / 100;

const TX_SELECT = [
  'id', 'date', 'amount', 'transfer_id', 'account', 'account.offbudget',
  'category', 'category.name', 'category.is_income', 'category.group.name',
  'payee.name', 'imported_payee',
];

import { classification, hiddenAccounts, pairSettings, readSettings } from './settings.js';

export const payeeOf = (t) => t['payee.name'] || t.imported_payee || '';

/**
 * Load accounts (with type + current balance), all transactions, the "real" income/spending subset,
 * and a daily balance history per account (oldest first). Hidden accounts and their transactions are
 * left out of everything except `hiddenAccts`.
 */
export async function loadLedger(api) {
  const { q, aqlQuery } = api;
  const [accounts, txRes] = await Promise.all([
    api.getAccounts(),
    aqlQuery(q('transactions').select(TX_SELECT)),
  ]);
  const hidden = hiddenAccounts();
  const { accountTypes } = readSettings();
  // Accounts with a bank connection; the rest are manual.
  const linked = new Set((await aqlQuery(q('accounts').select(['id', 'account_sync_source']))).data
    .filter((a) => a.account_sync_source).map((a) => a.id));
  const txs = txRes.data.filter((t) => !hidden.has(t.account));
  const now = new Date();

  const accts = [];
  const hiddenAccts = [];
  for (const a of accounts.filter((x) => !x.closed)) {
    const chosen = TYPE_LABELS[accountTypes[a.id]] ? accountTypes[a.id] : null;
    const liability = isLiability(a, accountTypes);
    (hidden.has(a.id) ? hiddenAccts : accts).push({
      id: a.id, name: a.name, offbudget: a.offbudget, liability, linked: linked.has(a.id),
      type: chosen || acctType(a.name, liability),
      balance: await api.getAccountBalance(a.id),
    });
  }

  // Walk back from today's balances, undoing each day's transactions.
  const firstTx = txs.reduce((m, t) => (t.date < m ? t.date : m), isoDay(now));
  const byDayAcct = new Map(); // date -> Map(account -> cents)
  for (const t of txs) {
    if (!byDayAcct.has(t.date)) byDayAcct.set(t.date, new Map());
    const m = byDayAcct.get(t.date);
    m.set(t.account, (m.get(t.account) || 0) + t.amount);
  }
  const bal = new Map(accts.map((a) => [a.id, a.balance]));
  const history = []; // { date, balances: Map(account -> cents at end of day) }
  for (let day = new Date(now); isoDay(day) >= firstTx; day.setDate(day.getDate() - 1)) {
    const key = isoDay(day);
    history.push({ date: key, balances: new Map(bal) });
    for (const [acct, amt] of byDayAcct.get(key) || []) {
      if (bal.has(acct)) bal.set(acct, bal.get(acct) - amt);
    }
  }
  history.reverse();

  const { transferRe, investRe } = payeePatterns();
  const isTransferLike = (t) => !t['category.name'] && transferRe.test(payeeOf(t));
  // A category you chose beats a payee pattern (e.g. an insurer payee categorized as a health refund).
  const isInvest = (t) => (!t.category && investRe.test(payeeOf(t))) || INVEST_GROUP_RE.test(t['category.group.name'] || '');
  // Self-balancing: money that left and came back (fee rebates, reversed charges). Never income or spending.
  const selfBalancing = pairSettings().selfBalancing;
  // Opening balances aren't income or spending, even when left uncategorized.
  const isStarting = (t) =>
    t['category.name'] === 'Starting Balances' || /^(starting balance|balance adjustment)$/i.test(payeeOf(t));
  // Income and spending only: no transfers, opening balances, self-balancing pairs, or investment contributions.
  const real = txs.filter((t) =>
    !t.transfer_id && !isStarting(t) && !isTransferLike(t) && !isInvest(t) && !(selfBalancing && t.category === selfBalancing));
  // Net money put into investments (cents, positive = contributed) for transactions matching pred.
  const investedWhere = (pred) =>
    txs.reduce((s, t) => (!t.transfer_id && !isStarting(t) && isInvest(t) && pred(t) ? s - t.amount : s), 0);

  return { now, accts, hiddenAccts, txs, real, history, investedWhere };
}

/** Income by category and spending by group -> category (cents) for transactions matching pred. */
export function summarize(real, pred) {
  const incomeBy = new Map();
  const spendBy = new Map(); // group -> Map(category -> cents)
  let income = 0, spent = 0;
  for (const t of real) {
    if (!pred(t)) continue;
    if (t.amount > 0 && (t['category.is_income'] || !t['category.name'])) {
      const key = t['category.name'] || 'Uncategorized income';
      incomeBy.set(key, (incomeBy.get(key) || 0) + t.amount);
      income += t.amount;
    } else {
      // expense (or refund netted against its category)
      const group = t['category.group.name'] || 'Uncategorized';
      const cat = t['category.name'] || 'Uncategorized';
      if (!spendBy.has(group)) spendBy.set(group, new Map());
      const g = spendBy.get(group);
      g.set(cat, (g.get(cat) || 0) - t.amount);
      spent -= t.amount;
    }
  }
  return { incomeBy, spendBy, income, spent };
}

/** Summary as JSON-friendly lists in dollars, largest first. */
export function breakdown({ incomeBy, spendBy, income, spent }) {
  const byValue = (a, b) => b.amount - a.amount;
  return {
    income: usd(income),
    expenses: usd(spent),
    incomeSources: [...incomeBy].map(([name, v]) => ({ name, amount: usd(v) })).sort(byValue),
    groups: [...spendBy]
      .map(([group, cats]) => ({
        name: group,
        amount: usd([...cats.values()].reduce((s, v) => s + v, 0)),
        categories: [...cats].map(([name, v]) => ({ name, amount: usd(v) })).filter((c) => c.amount > 0).sort(byValue),
      }))
      .filter((g) => g.amount > 0)
      .sort(byValue),
  };
}

/** Sankey nodes/links: income sources -> total -> groups -> categories, plus invested / saved. */
export function sankey({ incomeBy, spendBy, income, spent }, investedCents) {
  const nodes = [];
  const links = [];
  const node = (id, label, kind) => { if (!nodes.find((n) => n.id === id)) nodes.push({ id, label, kind }); };
  node('income', 'Total in', 'total');
  for (const [name, v] of incomeBy) {
    node(`in:${name}`, name, 'income');
    links.push({ source: `in:${name}`, target: 'income', value: usd(v) });
  }
  for (const [group, cats] of spendBy) {
    const gTotal = [...cats.values()].reduce((s, v) => s + v, 0);
    if (gTotal <= 0) continue;
    node(`g:${group}`, group, 'group');
    links.push({ source: 'income', target: `g:${group}`, value: usd(gTotal) });
    // A group holding a single same-named category needs no second level.
    if (cats.size === 1 && cats.has(group)) continue;
    for (const [cat, v] of cats) {
      if (v <= 0) continue;
      node(`c:${group}:${cat}`, cat, 'category');
      links.push({ source: `g:${group}`, target: `c:${group}:${cat}`, value: usd(v) });
    }
  }
  if (investedCents > 0) {
    node('invested', 'Invested', 'invest');
    links.push({ source: 'income', target: 'invested', value: usd(investedCents) });
  }
  const net = income - spent - Math.max(investedCents, 0);
  if (net > 0) {
    node('saved', 'Cash saved', 'savings');
    links.push({ source: 'income', target: 'saved', value: usd(net) });
  } else if (net < 0) {
    // Spent more than earned: fund the gap from savings so flows balance. The middle
    // node is then more than income, so relabel it.
    nodes.find((n) => n.id === 'income').label = 'Total out';
    node('drawdown', 'From savings', 'deficit');
    links.push({ source: 'drawdown', target: 'income', value: usd(-net) });
  }
  return { nodes, links, income: usd(income), spent: usd(spent), invested: usd(Math.max(investedCents, 0)) };
}
