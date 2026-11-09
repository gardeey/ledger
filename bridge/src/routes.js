import { reload, withBudget } from './actual.js';
import { backupBeforeWrite } from './backup.js';
import { hiddenAccounts } from './settings.js';

const usd = (c) => (c == null ? null : c / 100);
export const TX_FIELDS = [
  'id', 'date', 'amount', 'account', 'account.name', 'payee', 'payee.name',
  'imported_payee', 'category', 'category.name', 'notes', 'transfer_id', 'cleared',
];
export const shape = (t) => ({
  id: t.id, date: t.date, amount: usd(t.amount),
  account: t.account, accountName: t['account.name'],
  payee: t['payee.name'] || t.imported_payee || '', payeeId: t.payee,
  importedPayee: t.imported_payee || '',
  category: t.category, categoryName: t['category.name'] || null,
  notes: t.notes || '', transfer: !!t.transfer_id, cleared: !!t.cleared,
});

/** Run a write: back up first, mutate, then push to the sync server. */
export async function write(fn) {
  backupBeforeWrite();
  return withBudget(async (api) => {
    const out = await fn(api);
    try {
      await api.sync();
    } catch (e) {
      // "out-of-sync" means our local copy drifted from the server's, even though the change itself was
      // already sent. Reload the budget from the server and sync again; only fail if that fails too.
      if (!/out-of-sync|problem opening/i.test(`${e.code || ''} ${e.message}`)) throw e;
      await reload();
      await api.sync();
    }
    return out;
  });
}

// ---- rule preview: evaluate simple conditions locally --------------------------------
const fieldValue = (t, f, c) => ({
  payee: c?.type === 'id' ? t.payee : t['payee.name'] || t.imported_payee || '',
  imported_payee: t.imported_payee || '',
  notes: t.notes || '',
  amount: t.amount,
  account: t.account,
  category: t.category,
}[f]);
// Compare ids exactly; free text case-insensitively.

function matches(t, c) {
  const v = fieldValue(t, c.field, c);
  const s = (x) => String(x ?? '').toLowerCase();
  switch (c.op) {
    case 'is': return c.field === 'amount' ? v === c.value : s(v) === s(c.value);
    case 'isNot': return s(v) !== s(c.value);
    case 'contains': return s(v).includes(s(c.value));
    case 'doesNotContain': return !s(v).includes(s(c.value));
    case 'matches': try { return new RegExp(c.value, 'i').test(String(v ?? '')); } catch { return false; }
    case 'oneOf': return (c.value || []).map(s).includes(s(v));
    case 'gt': return v > c.value;
    case 'gte': return v >= c.value;
    case 'lt': return v < c.value;
    case 'lte': return v <= c.value;
    default: return false;
  }
}
const ruleMatches = (t, r) => {
  const res = (r.conditions || []).map((c) => matches(t, c));
  return r.conditionsOp === 'or' ? res.some(Boolean) : res.every(Boolean);
};

export function registerRoutes(app) {
  app.get('/api/categories', () =>
    withBudget(async (api) => {
      const { q, aqlQuery } = api;
      const [groups, used] = await Promise.all([
        api.getCategoryGroups(),
        aqlQuery(q('transactions').filter({ category: { $ne: null } }).select(['category'])),
      ]);
      const counts = new Map();
      for (const t of used.data) counts.set(t.category, (counts.get(t.category) || 0) + 1);
      return groups.filter((g) => !g.hidden).map((g) => ({
        id: g.id, name: g.name, income: !!g.is_income,
        categories: (g.categories || []).filter((c) => !c.hidden)
          .map((c) => ({ id: c.id, name: c.name, count: counts.get(c.id) || 0 })),
      }));
    }));

  // ---- category / group management ---------------------------------------------
  const requireName = (body) => {
    const name = String(body?.name || '').trim();
    if (!name) throw new Error('name required');
    return name;
  };

  app.post('/api/category-groups', (req) =>
    write(async (api) => ({ id: await api.createCategoryGroup({ name: requireName(req.body), is_income: !!req.body.income }) })));

  app.patch('/api/category-groups/:id', (req) =>
    write(async (api) => { await api.updateCategoryGroup(req.params.id, { name: requireName(req.body) }); return { ok: true }; }));

  // Only empty groups can be deleted, so no transactions lose their category by accident.
  app.delete('/api/category-groups/:id', (req) =>
    write(async (api) => {
      const g = (await api.getCategoryGroups()).find((x) => x.id === req.params.id);
      if (!g) throw new Error('group not found');
      if ((g.categories || []).some((c) => !c.hidden)) throw new Error('Move or delete the categories in this group first');
      await api.deleteCategoryGroup(req.params.id);
      return { ok: true };
    }));

  app.post('/api/categories', (req) =>
    write(async (api) => {
      if (!req.body?.groupId) throw new Error('groupId required');
      return { id: await api.createCategory({ name: requireName(req.body), group_id: req.body.groupId }) };
    }));

  app.patch('/api/categories/:id', (req) =>
    write(async (api) => {
      const fields = {};
      if (req.body?.name !== undefined) fields.name = requireName(req.body);
      if (req.body?.groupId) fields.group_id = req.body.groupId;
      await api.updateCategory(req.params.id, fields);
      return { ok: true };
    }));

  // transferTo: move this category's transactions (and budget) there; otherwise they become uncategorized.
  app.delete('/api/categories/:id', (req) =>
    write(async (api) => {
      await api.deleteCategory(req.params.id, req.query.transferTo || undefined);
      return { ok: true };
    }));

  // Filters shared by the list and its summary:
  //   search, account, category, uncategorized=1, from/to (YYYY-MM-DD, inclusive),
  //   kind = expense | income | transfer | uncategorized
  const txQuery = (q, query) => {
    const { search = '', account, category, uncategorized, from, to, kind } = query;
    const conds = [];
    if (account) conds.push({ account });
    // Hidden accounts only show up when asked for by id (their own account page).
    else for (const id of hiddenAccounts()) conds.push({ account: { $ne: id } });
    if (category) conds.push({ category });
    if (uncategorized === '1' || kind === 'uncategorized') conds.push({ category: null, transfer_id: null });
    if (from) conds.push({ date: { $gte: from } });
    if (to) conds.push({ date: { $lte: to } });
    if (kind === 'expense') conds.push({ amount: { $lt: 0 }, transfer_id: null });
    if (kind === 'income') conds.push({ amount: { $gt: 0 }, transfer_id: null });
    if (kind === 'transfer') conds.push({ transfer_id: { $ne: null } });
    if (search) {
      conds.push({
        $or: [
          { 'payee.name': { $like: `%${search}%` } },
          { imported_payee: { $like: `%${search}%` } },
          { notes: { $like: `%${search}%` } },
        ],
      });
    }
    return conds.length ? q('transactions').filter({ $and: conds }) : q('transactions');
  };

  app.get('/api/transactions', (req) =>
    withBudget(async (api) => {
      const { limit = 60, offset = 0 } = req.query;
      const res = await api.aqlQuery(
        txQuery(api.q, req.query).select(TX_FIELDS).orderBy([{ date: 'desc' }, { id: 'desc' }])
          .limit(Number(limit)).offset(Number(offset)),
      );
      return res.data.map(shape);
    }));

  // Count and in/out totals for the same filters (for the list header).
  app.get('/api/transactions/summary', (req) =>
    withBudget(async (api) => {
      const rows = (await api.aqlQuery(txQuery(api.q, req.query).select(['amount']))).data;
      let inflow = 0, outflow = 0;
      for (const t of rows) if (t.amount > 0) inflow += t.amount; else outflow -= t.amount;
      return { count: rows.length, inflow: usd(inflow), outflow: usd(outflow) };
    }));

  // Uncategorized queue with per-payee suggestions from categorized history.
  app.get('/api/inbox', () =>
    withBudget(async (api) => {
      const { q, aqlQuery } = api;
      const [unc, hist] = await Promise.all([
        aqlQuery(q('transactions').filter({ category: null, transfer_id: null })
          .select(TX_FIELDS).orderBy([{ date: 'desc' }, { id: 'desc' }]).limit(500)),
        aqlQuery(q('transactions').filter({ category: { $ne: null } })
          .select(['payee.name', 'imported_payee', 'category', 'category.name', 'category.group.name'])),
      ]);
      const hidden = hiddenAccounts();
      unc.data = unc.data.filter((t) => !hidden.has(t.account));
      const counts = new Map(); // payee -> Map(catId -> {name,n})
      for (const h of hist.data) {
        if (h['category.group.name'] === 'Starting Balances' || h['category.name'] === 'Starting Balances') continue;
        const key = (h['payee.name'] || h.imported_payee || '').toLowerCase();
        if (!key) continue;
        if (!counts.has(key)) counts.set(key, new Map());
        const m = counts.get(key);
        const e = m.get(h.category) || { id: h.category, name: h['category.name'], n: 0 };
        e.n++; m.set(h.category, e);
      }
      return unc.data.map((t) => {
        const key = (t['payee.name'] || t.imported_payee || '').toLowerCase();
        const sug = [...(counts.get(key)?.values() || [])].sort((a, b) => b.n - a.n).slice(0, 3);
        const sameCount = unc.data.filter((o) => (o['payee.name'] || o.imported_payee || '').toLowerCase() === key).length;
        return { ...shape(t), suggestions: sug, samePayeeCount: key ? sameCount : 1 };
      });
    }));

  app.patch('/api/transactions/:id', (req) =>
    write(async (api) => {
      const { category, notes } = req.body || {};
      const fields = {};
      if (category !== undefined) fields.category = category;
      if (notes !== undefined) fields.notes = notes;
      await api.updateTransaction(req.params.id, fields);
      return { ok: true };
    }));

  // Categorize one transaction. Making it a rule is a separate, explicit step (/remember).
  app.post('/api/transactions/:id/categorize', (req) =>
    write(async (api) => {
      const { category } = req.body || {};
      if (!category) throw new Error('category required');
      await api.updateTransaction(req.params.id, { category });
      return { ok: true };
    }));

  // "Always categorize this payee this way": use the transaction's current category, update the payee's
  // existing category rule (or create one), then apply it to that payee's other uncategorized transactions.
  app.post('/api/transactions/:id/remember', (req) =>
    write(async (api) => {
      const { q, aqlQuery } = api;
      const t = (await aqlQuery(q('transactions').filter({ id: req.params.id }).select(TX_FIELDS))).data[0];
      if (!t) throw new Error('transaction not found');
      if (!t.category) throw new Error('categorize the transaction first');
      if (!t.payee && !t.imported_payee) throw new Error('transaction has no payee');
      const field = t.payee ? 'payee' : 'imported_payee';
      const value = t.payee || t.imported_payee;
      const cond = { field, op: 'is', value, type: t.payee ? 'id' : 'string' };
      const setCat = { op: 'set', field: 'category', value: t.category, type: 'id' };

      const same = (c) => c.field === field && c.op === 'is'
        && (field === 'payee' ? c.value === value : String(c.value).toLowerCase() === value.toLowerCase());
      const existing = (await api.getRules()).find((r) =>
        r.conditions?.length === 1 && same(r.conditions[0]) && r.actions?.some((a) => a.field === 'category'));
      let ruleId, updated = false;
      if (existing) {
        const actions = existing.actions.map((a) => (a.field === 'category' ? { ...a, ...setCat } : a));
        await api.updateRule({ ...existing, actions });
        ruleId = existing.id; updated = true;
      } else {
        ruleId = (await api.createRule({ stage: null, conditionsOp: 'and', conditions: [cond], actions: [setCat] })).id;
      }

      const others = (await aqlQuery(
        q('transactions').filter({ category: null, transfer_id: null, [field]: value }).select(['id']),
      )).data;
      for (const o of others) await api.updateTransaction(o.id, { category: t.category });
      return { ok: true, ruleId, updated, applied: others.length };
    }));

  // ---- rules -----------------------------------------------------------------
  app.get('/api/rules', () =>
    withBudget(async (api) => {
      const [rules, payees, cats, accts] = await Promise.all([
        api.getRules(), api.getPayees(), api.getCategories(), api.getAccounts(),
      ]);
      const name = {
        payee: Object.fromEntries(payees.map((p) => [p.id, p.name])),
        category: Object.fromEntries(cats.map((c) => [c.id, c.name])),
        account: Object.fromEntries(accts.map((a) => [a.id, a.name])),
      };
      return { rules, names: name };
    }));

  app.post('/api/rules/preview', (req) =>
    withBudget(async (api) => {
      const { q, aqlQuery } = api;
      const rule = req.body;
      const txs = (await aqlQuery(q('transactions').select(TX_FIELDS)
        .orderBy({ date: 'desc' }).limit(3000))).data;
      const hits = txs.filter((t) => ruleMatches(t, rule));
      return { count: hits.length, sample: hits.slice(0, 8).map(shape) };
    }));

  app.post('/api/rules', (req) => write((api) => api.createRule(req.body)));
  app.put('/api/rules/:id', (req) => write((api) => api.updateRule({ ...req.body, id: req.params.id })));
  app.delete('/api/rules/:id', (req) => write(async (api) => { await api.deleteRule(req.params.id); return { ok: true }; }));

  app.get('/api/payees', () => withBudget(async (api) => (await api.getPayees()).filter((p) => !p.transfer_acct).map((p) => ({ id: p.id, name: p.name }))));

  // ---- bank sync (SimpleFIN via Actual) --------------------------------------------
  app.post('/api/sync', () =>
    write(async (api) => {
      await api.runBankSync();
      return { ok: true };
    }));
}
