// Pass-through pairs: an amount that leaves and comes back within a few business days (card payments,
// fee rebates, reversed charges, reimbursements). Only ever suggested; the user picks what each pair is.
import { withBudget } from './actual.js';
import { isLiability, payeePatterns, usd } from './finance.js';
import { TX_FIELDS, shape, write } from './routes.js';
import { hiddenAccounts, pairSettings, readSettings, updateSection } from './settings.js';

const MAX_BUSINESS_DAYS = 3;
const SELF_BALANCING = { group: 'Pass-through', name: 'Self-balancing' };

const pairKey = (outId, inId) => `${outId}|${inId}`;

/** Weekdays from the earlier date to the later one (Fri -> Mon is 1). */
function businessDays(a, b) {
  let [from, to] = [new Date(`${a}T12:00:00Z`), new Date(`${b}T12:00:00Z`)];
  if (from > to) [from, to] = [to, from];
  let n = 0;
  for (const d = new Date(from); d < to; d.setUTCDate(d.getUTCDate() + 1)) {
    const next = (d.getUTCDay() + 1) % 7;
    if (next !== 0 && next !== 6) n++;
  }
  return n;
}

const words = (s) => new Set(String(s).toLowerCase().split(/[^a-z]+/).filter((w) => w.length > 2));
const sharedWords = (a, b) => { const wb = words(b); return [...words(a)].filter((w) => wb.has(w)).length; };

/** The self-balancing category, created on first use if it isn't set yet. */
async function selfBalancingCategory(api) {
  const groups = await api.getCategoryGroups();
  const all = groups.flatMap((g) => g.categories || []);
  const { selfBalancing } = pairSettings();
  const found = all.find((c) => c.id === selfBalancing && !c.hidden);
  if (found) return found;
  let group = groups.find((g) => g.name === SELF_BALANCING.group && !g.is_income);
  const byName = group && (group.categories || []).find((c) => c.name === SELF_BALANCING.name && !c.hidden);
  if (byName) { updateSection('pairs', { selfBalancing: byName.id }); return byName; }
  const groupId = group ? group.id : await api.createCategoryGroup({ name: SELF_BALANCING.group, is_income: false });
  const id = await api.createCategory({ name: SELF_BALANCING.name, group_id: groupId });
  updateSection('pairs', { selfBalancing: id });
  return { id, name: SELF_BALANCING.name };
}

async function findPairs(api) {
  const { q, aqlQuery } = api;
  const hidden = hiddenAccounts();
  const { selfBalancing, dismissed } = pairSettings();
  const skip = new Set(dismissed);
  const { accountTypes } = readSettings();
  const liability = new Map((await api.getAccounts()).map((a) => [a.id, isLiability(a, accountTypes)]));
  const { transferRe } = payeePatterns();

  const txs = (await aqlQuery(q('transactions').filter({ transfer_id: null }).select(TX_FIELDS))).data
    .filter((t) => t.amount !== 0 && !hidden.has(t.account) && !(selfBalancing && t.category === selfBalancing)
      && t['category.name'] !== 'Starting Balances');
  const outs = txs.filter((t) => t.amount < 0);
  const ins = txs.filter((t) => t.amount > 0);

  const candidates = [];
  for (const o of outs) {
    for (const i of ins) {
      if (i.amount !== -o.amount || skip.has(pairKey(o.id, i.id))) continue;
      // Already sorted out: both halves in the same category (e.g. a refund counted against its expense).
      if (o.category && o.category === i.category) continue;
      const days = businessDays(o.date, i.date);
      if (days > MAX_BUSINESS_DAYS) continue;
      candidates.push({ o, i, days, shared: sharedWords(shape(o).payee, shape(i).payee) });
    }
  }
  // Closest in time first, then most similar payee; each transaction joins at most one pair.
  candidates.sort((a, b) => a.days - b.days || b.shared - a.shared);
  const used = new Set();
  const pairs = [];
  for (const { o, i, days } of candidates) {
    if (used.has(o.id) || used.has(i.id)) continue;
    used.add(o.id); used.add(i.id);
    const out = shape(o), inn = shape(i);
    const kind = o.account === i.account ? 'reversal'
      : liability.get(i.account) || transferRe.test(out.payee) || transferRe.test(inn.payee) ? 'transfer'
        : 'reimbursement';
    pairs.push({ id: pairKey(o.id, i.id), kind, days, out, in: inn });
  }
  return pairs.sort((a, b) => (a.out.date < b.out.date ? 1 : -1));
}

/** Link two existing transactions as an Actual transfer (Actual clears their categories). */
async function linkTransfer(api, o, i) {
  const payees = await api.getPayees();
  const payeeFor = (acct) => payees.find((p) => p.transfer_acct === acct)?.id;
  const [toIn, toOut] = [payeeFor(i.account), payeeFor(o.account)];
  if (!toIn || !toOut) throw new Error('transfer payee not found for one of the accounts');
  // Actual keeps one note for both halves of a transfer.
  const notes = o.notes || i.notes || null;
  await api.updateTransaction(o.id, { payee: toIn, transfer_id: i.id, notes });
  await api.updateTransaction(i.id, { payee: toOut, transfer_id: o.id, notes });
}

export function registerPairs(app) {
  app.get('/api/pairs', () =>
    withBudget(async (api) => {
      const pairs = await findPairs(api);
      const { selfBalancing } = pairSettings();
      let balance = null;
      if (selfBalancing) {
        const { q, aqlQuery } = api;
        const hidden = hiddenAccounts();
        const rows = (await aqlQuery(q('transactions').filter({ category: selfBalancing }).select(['account', 'amount']))).data;
        balance = { category: selfBalancing, net: usd(rows.filter((t) => !hidden.has(t.account)).reduce((s, t) => s + t.amount, 0)) };
      }
      return { pairs, selfBalancing: balance };
    }));

  // action: transfer | selfBalancing | category (with category id: count the money coming back against it)
  app.post('/api/pairs/resolve', (req) =>
    write(async (api) => {
      const { out: outId, in: inId, action, category } = req.body || {};
      const { q, aqlQuery } = api;
      const rows = (await aqlQuery(q('transactions').filter({ id: { $oneof: [outId, inId] } }).select(TX_FIELDS))).data;
      const o = rows.find((t) => t.id === outId), i = rows.find((t) => t.id === inId);
      if (!o || !i) throw new Error('transaction not found');
      if (o.amount !== -i.amount) throw new Error('amounts no longer match');
      if (o.transfer_id || i.transfer_id) throw new Error('already part of a transfer');

      if (action === 'transfer') {
        if (o.account === i.account) throw new Error('both halves are in the same account');
        await linkTransfer(api, o, i);
      } else if (action === 'selfBalancing') {
        const c = await selfBalancingCategory(api);
        for (const t of [o, i]) await api.updateTransaction(t.id, { category: c.id });
      } else if (action === 'category') {
        if (!category) throw new Error('category required');
        for (const t of [o, i]) await api.updateTransaction(t.id, { category });
      } else {
        throw new Error('unknown action');
      }
      return { ok: true };
    }));

  app.post('/api/pairs/dismiss', (req) => {
    const { out: outId, in: inId } = req.body || {};
    if (!outId || !inId) throw new Error('out and in required');
    const { dismissed } = pairSettings();
    updateSection('pairs', { dismissed: [...new Set([...dismissed, pairKey(outId, inId)])] });
    return { ok: true };
  });

  // Choose which category is self-balancing (null goes back to creating "Self-balancing" on first use).
  app.put('/api/settings/self-balancing', (req) => {
    const { category = null } = req.body || {};
    updateSection('pairs', { selfBalancing: category });
    return { ok: true, category };
  });
}
