// Endpoints behind the Monarch-style pages: accounts, cash flow, reports, budget, recurring, goals.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { withBudget } from './actual.js';
import {
  ADJUSTMENT_PAYEE, LIABILITY_TYPES, TYPE_LABELS, payeePatterns, addMonths, breakdown, isoDay, loadLedger, monthKey, payeeOf, sankey, summarize, usd,
} from './finance.js';
import { write } from './routes.js';
import { hiddenAccounts, pairSettings, setAccountHidden, setAccountType } from './settings.js';

const DAY = 86400000;
const dayNum = (ymd) => Math.round(Date.parse(`${ymd}T00:00:00Z`) / DAY);
const fromDayNum = (n) => new Date(n * DAY).toISOString().slice(0, 10);
const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length % 2 ? s[(s.length - 1) >> 1] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};

// ---- recurring detection ------------------------------------------------------
const FREQS = [
  { id: 'weekly', days: 7, min: 3 },
  { id: 'biweekly', days: 14, min: 3 },
  { id: 'monthly', days: 30.4, min: 2 },
  { id: 'quarterly', days: 91, min: 2 },
  { id: 'yearly', days: 365, min: 2 },
];
const PER_MONTH = { weekly: 52 / 12, biweekly: 26 / 12, monthly: 1, quarterly: 1 / 3, yearly: 1 / 12 };

// Merchants often append store / reference numbers; strip them so repeats group together.
const payeeKey = (s) => s.toLowerCase().replace(/[#*]?\s*\d[\d\s-]{2,}$/, '').replace(/\s+/g, ' ').trim();

function detectRecurring(txs, today) {
  const { transferRe } = payeePatterns();
  const { selfBalancing } = pairSettings();
  const groups = new Map();
  for (const t of txs) {
    const name = payeeOf(t);
    if (t.transfer_id || !name || t.amount === 0) continue;
    if (t['category.name'] === 'Starting Balances' || /^starting balance$/i.test(name)) continue;
    if (!t['category.name'] && transferRe.test(name)) continue;
    if (selfBalancing && t.category === selfBalancing) continue;
    const key = `${payeeKey(name)}|${t.amount > 0 ? 'in' : 'out'}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(t);
  }
  const out = [];
  for (const list of groups.values()) {
    // one entry per day (split / duplicate charges on the same day count once)
    const byDay = new Map();
    for (const t of list) byDay.set(t.date, (byDay.get(t.date) || 0) + t.amount);
    const days = [...byDay.keys()].sort();
    if (days.length < 2) continue;
    const gaps = days.slice(1).map((d, i) => dayNum(d) - dayNum(days[i]));
    const gap = median(gaps);
    const freq = FREQS.find((f) => Math.abs(gap - f.days) <= Math.max(3, f.days * 0.15));
    if (!freq || days.length < freq.min) continue;
    const tol = Math.max(3, freq.days * 0.2);
    if (gaps.filter((g) => Math.abs(g - freq.days) <= tol).length / gaps.length < 0.66) continue;
    const amounts = days.map((d) => Math.abs(byDay.get(d)));
    const typical = median(amounts.slice(-3));
    if (Math.max(...amounts.map((a) => Math.abs(a - typical) / typical)) > 0.5) continue;

    const last = days[days.length - 1];
    const latest = list.filter((t) => t.date === last)[0];
    const sign = latest.amount > 0 ? 1 : -1;
    let next;
    if (freq.id === 'monthly' || freq.id === 'quarterly' || freq.id === 'yearly') {
      const step = { monthly: 1, quarterly: 3, yearly: 12 }[freq.id];
      const [y, m, d] = last.split('-').map(Number);
      const target = new Date(y, m - 1 + step, 1);
      const lastDay = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate();
      next = isoDay(new Date(target.getFullYear(), target.getMonth(), Math.min(d, lastDay)));
    } else {
      next = fromDayNum(dayNum(last) + freq.days);
    }
    const overdueBy = dayNum(today) - dayNum(next);
    out.push({
      name: payeeOf(latest),
      amount: usd(sign * typical),
      frequency: freq.id,
      monthly: usd(sign * typical * PER_MONTH[freq.id]),
      lastDate: last,
      nextDate: next,
      count: days.length,
      category: latest['category.name'] || null,
      // Missed more than half a cycle past its due date: probably cancelled.
      active: overdueBy <= freq.days / 2,
      variable: Math.max(...amounts) - Math.min(...amounts) > Math.max(100, typical * 0.05), // > $1 or 5%
      history: days.slice(-6).map((d) => ({ date: d, amount: usd(byDay.get(d)) })),
    });
  }
  return out.sort((a, b) => a.nextDate.localeCompare(b.nextDate));
}

// ---- goals (stored beside the budget cache; Actual has no goals) --------------
const GOALS_FILE = path.join(process.env.ACTUAL_DATA_DIR || '/cache', 'ledger-goals.json');
const readGoals = () => {
  try { return JSON.parse(fs.readFileSync(GOALS_FILE, 'utf8')); } catch { return []; }
};
const saveGoals = (goals) => {
  fs.writeFileSync(`${GOALS_FILE}.tmp`, JSON.stringify(goals, null, 2));
  fs.renameSync(`${GOALS_FILE}.tmp`, GOALS_FILE);
};
const GOAL_FIELDS = ['name', 'emoji', 'target', 'monthly', 'saved', 'accountIds', 'targetDate', 'completed'];
const pickGoal = (body) => Object.fromEntries(GOAL_FIELDS.filter((k) => body?.[k] !== undefined).map((k) => [k, body[k]]));

export function registerPages(app) {
  // Accounts grouped by type, with a year of daily balances for sparklines / detail charts.
  app.get('/api/accounts', () =>
    withBudget(async (api) => {
      const { accts, hiddenAccts, history } = await loadLedger(api);
      const recent = history.slice(-366);
      const shaped = accts.map((a) => ({
        id: a.id, name: a.name, type: a.type, offbudget: a.offbudget, liability: a.liability, linked: a.linked,
        balance: usd(a.balance),
        series: recent.map((h) => ({ date: h.date, balance: usd(h.balances.get(a.id)) })),
      }));
      const groups = Object.keys(TYPE_LABELS)
        .map((type) => {
          const list = shaped.filter((a) => a.type === type).sort((a, b) => Math.abs(b.balance) - Math.abs(a.balance));
          return { type, label: TYPE_LABELS[type], total: usd(list.reduce((s, a) => s + a.balance * 100, 0)), accounts: list };
        })
        .filter((g) => g.accounts.length);
      const assets = shaped.filter((a) => !a.liability && a.balance > 0).reduce((s, a) => s + a.balance, 0);
      const liabilities = shaped.filter((a) => a.liability || a.balance < 0).reduce((s, a) => s + a.balance, 0);
      return {
        netWorth: usd((assets + liabilities) * 100), assets: usd(assets * 100), liabilities: usd(liabilities * 100), groups,
        hidden: hiddenAccts.map((a) => ({ id: a.id, name: a.name, type: a.type, balance: usd(a.balance) })),
      };
    }));

  // Manual account (home, car, loan, wallet...). balance: current value; loans are entered as amount owed.
  app.post('/api/accounts', (req) =>
    write(async (api) => {
      const { name, type = 'other', balance = 0, onBudget = false } = req.body || {};
      if (!String(name || '').trim()) throw new Error('name required');
      if (!TYPE_LABELS[type]) throw new Error('unknown type');
      const cents = Math.round(Math.abs(Number(balance) || 0) * 100) * (LIABILITY_TYPES.has(type) ? -1 : 1);
      const id = await api.createAccount({ name: String(name).trim(), offbudget: !onBudget }, cents);
      setAccountType(id, type);
      return { id };
    }));

  app.post('/api/accounts/:id/type', (req) => {
    if (!TYPE_LABELS[req.body?.type]) throw new Error('unknown type');
    setAccountType(req.params.id, req.body.type);
    return { ok: true };
  });

  // Set a manual account to a new value by recording the difference as a balance adjustment.
  app.post('/api/accounts/:id/balance', (req) =>
    write(async (api) => {
      const target = Math.round(Number(req.body?.balance) * 100);
      if (!Number.isFinite(target)) throw new Error('numeric balance required');
      const diff = target - (await api.getAccountBalance(req.params.id));
      if (diff !== 0) {
        await api.addTransactions(req.params.id, [{
          date: req.body.date || isoDay(new Date()), amount: diff, payee_name: ADJUSTMENT_PAYEE,
          notes: req.body.note || '', cleared: true,
        }]);
      }
      return { ok: true, adjustment: usd(diff) };
    }));

  // Add one transaction. transferTo: another account id -> a linked transfer pair (e.g. a loan payment).
  app.post('/api/transactions', (req) =>
    write(async (api) => {
      const { account, date, amount, payee = '', category = null, notes = '', transferTo } = req.body || {};
      if (!account || !/^\d{4}-\d{2}-\d{2}$/.test(date || '') || !Number(amount)) {
        throw new Error('account, date (YYYY-MM-DD) and a non-zero amount required');
      }
      const tx = { date, amount: Math.round(Number(amount) * 100), notes, cleared: true };
      if (transferTo) {
        const p = (await api.getPayees()).find((x) => x.transfer_acct === transferTo);
        if (!p) throw new Error('transfer account not found');
        tx.payee = p.id;
      } else {
        tx.payee_name = String(payee).trim() || 'Manual entry';
        tx.category = category;
      }
      await api.addTransactions(account, [tx], { runTransfers: true });
      return { ok: true };
    }));

  app.post('/api/accounts/:id/hidden', (req) => {
    setAccountHidden(req.params.id, req.body?.hidden !== false);
    return { ok: true };
  });

  // Month-by-month income / expenses / savings with category breakdowns.
  app.get('/api/cashflow', (req) =>
    withBudget(async (api) => {
      const { now, txs, real, investedWhere } = await loadLedger(api);
      const n = Math.min(Math.max(Number(req.query.months) || 12, 1), 60);
      const thisMonth = monthKey(now);
      const firstData = txs.reduce((m, t) => (t.date < m ? t.date : m), isoDay(now)).slice(0, 7);
      const months = [];
      for (let m = addMonths(thisMonth, -(n - 1)); m <= thisMonth; m = addMonths(m, 1)) if (m >= firstData) months.push(m);
      return {
        months: months.map((m) => {
          const inMonth = (t) => t.date.slice(0, 7) === m;
          const b = breakdown(summarize(real, inMonth));
          const savings = Math.round((b.income - b.expenses) * 100) / 100;
          return {
            month: m, ...b, savings,
            invested: usd(investedWhere(inMonth)),
            savingsRate: b.income > 0 ? Math.round((savings / b.income) * 1000) / 10 : null,
          };
        }),
      };
    }));

  // Spending / income analysis for an arbitrary date range.
  app.get('/api/reports', (req) =>
    withBudget(async (api) => {
      const { now, real, investedWhere } = await loadLedger(api);
      const to = req.query.to || isoDay(now);
      const from = req.query.from || `${to.slice(0, 7)}-01`;
      const inRange = (t) => t.date >= from && t.date <= to;
      const summary = summarize(real, inRange);
      const merchants = new Map();
      for (const t of real) {
        if (!inRange(t) || t.amount >= 0 || t['category.is_income']) continue;
        const name = payeeOf(t) || 'Unknown';
        const e = merchants.get(name) || { name, amount: 0, count: 0 };
        e.amount -= t.amount; e.count++;
        merchants.set(name, e);
      }
      const monthly = [];
      for (let m = from.slice(0, 7); m <= to.slice(0, 7); m = addMonths(m, 1)) {
        const b = breakdown(summarize(real, (t) => inRange(t) && t.date.slice(0, 7) === m));
        monthly.push({ month: m, income: b.income, expenses: b.expenses, groups: Object.fromEntries(b.groups.map((g) => [g.name, g.amount])) });
      }
      return {
        from, to,
        ...breakdown(summary),
        merchants: [...merchants.values()].sort((a, b) => b.amount - a.amount).slice(0, 15)
          .map((e) => ({ ...e, amount: usd(e.amount) })),
        monthly,
        sankey: sankey(summary, investedWhere(inRange)),
      };
    }));

  // Actual's envelope budget for a month.
  app.get('/api/budget', (req) =>
    withBudget(async (api) => {
      const month = req.query.month || monthKey(new Date());
      const bm = await api.getBudgetMonth(month);
      const { selfBalancing } = pairSettings();
      const cat = (c) => ({
        id: c.id, name: c.name, budgeted: usd(c.budgeted), spent: usd(-c.spent), balance: usd(c.balance), rollover: !!c.carryover,
      });
      return {
        month,
        toBudget: usd(bm.toBudget),
        totalBudgeted: usd(-bm.totalBudgeted),
        totalSpent: usd(-bm.totalSpent),
        totalIncome: usd(bm.totalIncome),
        // Self-balancing isn't something you budget for; drop it (and a group left holding only it).
        groups: bm.categoryGroups.filter((g) => !g.is_income && !g.hidden)
          .filter((g) => !(g.categories.some((c) => c.id === selfBalancing)
            && g.categories.every((c) => c.hidden || c.id === selfBalancing)))
          .map((g) => ({
            id: g.id, name: g.name, budgeted: usd(g.budgeted), spent: usd(-g.spent), balance: usd(g.balance),
            categories: g.categories.filter((c) => !c.hidden && c.id !== selfBalancing).map(cat),
          })),
        income: bm.categoryGroups.filter((g) => g.is_income).flatMap((g) =>
          g.categories.filter((c) => !c.hidden && c.name !== 'Starting Balances')
            .map((c) => ({ id: c.id, name: c.name, received: usd(c.received ?? 0) }))),
      };
    }));

  app.post('/api/budget', (req) =>
    write(async (api) => {
      const { month, category, amount } = req.body || {};
      if (!/^\d{4}-\d{2}$/.test(month || '') || !category || typeof amount !== 'number') {
        throw new Error('month (YYYY-MM), category and numeric amount required');
      }
      await api.setBudgetAmount(month, category, Math.round(amount * 100));
      return { ok: true };
    }));

  app.get('/api/recurring', () =>
    withBudget(async (api) => {
      const { now, txs } = await loadLedger(api);
      const items = detectRecurring(txs, isoDay(now));
      const active = items.filter((i) => i.active);
      const sum = (pred) => usd(active.filter(pred).reduce((s, i) => s + i.monthly * 100, 0));
      return {
        items,
        monthlyExpenses: -sum((i) => i.amount < 0),
        monthlyIncome: sum((i) => i.amount > 0),
      };
    }));

  // ---- goals ----------------------------------------------------------------------
  app.get('/api/goals', () =>
    withBudget(async (api) => {
      const hidden = hiddenAccounts();
      const accounts = (await api.getAccounts()).filter((a) => !hidden.has(a.id));
      const balances = new Map();
      for (const a of accounts.filter((x) => !x.closed)) balances.set(a.id, await api.getAccountBalance(a.id));
      return {
        accounts: accounts.filter((a) => !a.closed).map((a) => ({ id: a.id, name: a.name, balance: usd(balances.get(a.id)) })),
        goals: readGoals().map((g) => ({
          ...g,
          current: g.accountIds?.length
            ? usd(g.accountIds.reduce((s, id) => s + (balances.get(id) || 0), 0))
            : Number(g.saved || 0),
        })),
      };
    }));

  app.post('/api/goals', (req) => {
    const goal = { id: crypto.randomUUID(), createdAt: isoDay(new Date()), accountIds: [], ...pickGoal(req.body) };
    if (!goal.name || !(Number(goal.target) > 0)) throw new Error('name and a positive target required');
    saveGoals([...readGoals(), goal]);
    return goal;
  });

  app.put('/api/goals/:id', (req) => {
    const goals = readGoals();
    const i = goals.findIndex((g) => g.id === req.params.id);
    if (i < 0) throw new Error('goal not found');
    goals[i] = { ...goals[i], ...pickGoal(req.body) };
    saveGoals(goals);
    return goals[i];
  });

  app.delete('/api/goals/:id', (req) => {
    saveGoals(readGoals().filter((g) => g.id !== req.params.id));
    return { ok: true };
  });
}
