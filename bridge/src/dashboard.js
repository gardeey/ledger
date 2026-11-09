// Dashboard aggregation. Amounts from Actual are integer cents; we return dollars.
import { addMonths, loadLedger, monthEnd, monthKey, sankey, summarize, usd } from './finance.js';
import { hiddenAccounts } from './settings.js';

export async function buildDashboard(api, { month } = {}) {
  const { now, accts, real, history, investedWhere } = await loadLedger(api);
  const { q, aqlQuery } = api;
  const thisMonth = monthKey(now);
  const target = month || addMonths(thisMonth, -1); // last full month
  const first = addMonths(thisMonth, -12);

  // ---- net worth (all history: the chart offers 5Y / All ranges) --------------
  const netWorth = history.map(({ date, balances }) => {
    let assets = 0, liabilities = 0;
    for (const a of accts) {
      const b = balances.get(a.id);
      if (a.liability || b < 0) liabilities += b; else assets += b;
    }
    return { date, assets: usd(assets), liabilities: usd(liabilities), net: usd(assets + liabilities) };
  });

  // ---- income vs expenses, last 13 months --------------------------------------
  const months = Array.from({ length: 13 }, (_, i) => addMonths(first, i)); // first..thisMonth
  const flow = months.map((m) => {
    let income = 0, expenses = 0;
    for (const t of real) {
      if (t.date.slice(0, 7) !== m) continue;
      if (t.amount > 0) income += t.amount; else expenses += -t.amount;
    }
    return {
      month: m, income: usd(income), expenses: usd(expenses),
      invested: usd(investedWhere((t) => t.date.slice(0, 7) === m)),
      savingsRate: income > 0 ? Math.round(((income - expenses) / income) * 1000) / 10 : null, // incl. investing
    };
  });

  // ---- cumulative spending: this month vs last month ------------------------
  // cumulative[d-1] = expenses from the 1st through day d (dollars).
  const cumulative = (m, days) => {
    const perDay = new Array(days).fill(0);
    for (const t of real) {
      if (t.amount < 0 && t.date.slice(0, 7) === m) perDay[Number(t.date.slice(8, 10)) - 1] += -t.amount;
    }
    let run = 0;
    return perDay.map((c) => usd((run += c)));
  };
  const lastMonth = addMonths(thisMonth, -1);
  const spending = {
    month: thisMonth,
    thisMonth: cumulative(thisMonth, now.getDate()),
    lastMonth: cumulative(lastMonth, Number(monthEnd(lastMonth).slice(8))),
  };

  // ---- sankey for target month ---------------------------------------------
  const inTarget = (t) => t.date.slice(0, 7) === target;
  const flows = sankey(summarize(real, inTarget), investedWhere(inTarget));

  // ---- budget vs actual for target month -----------------------------------
  let budget = [];
  try {
    const bm = await api.getBudgetMonth(target);
    budget = bm.categoryGroups
      .filter((g) => !g.is_income)
      .map((g) => ({
        group: g.name,
        budgeted: usd(g.budgeted), spent: usd(-g.spent),
        categories: g.categories.map((c) => ({
          name: c.name, budgeted: usd(c.budgeted), spent: usd(-c.spent),
        })),
      }));
  } catch { /* budget may not be configured */ }

  const hidden = hiddenAccounts();
  const uncategorized = (await aqlQuery(
    q('transactions').filter({ category: null, transfer_id: null, 'account.offbudget': false }).select(['account']),
  )).data.filter((t) => !hidden.has(t.account)).length;

  return {
    month: target,
    netWorth: {
      current: usd(accts.reduce((s, a) => s + a.balance, 0)),
      series: netWorth,
    },
    flow,
    spending,
    sankey: flows,
    budget,
    uncategorizedCount: uncategorized,
    accounts: accts.map((a) => ({
      id: a.id, name: a.name, offbudget: a.offbudget, liability: a.liability, balance: usd(a.balance), type: a.type,
    })),
  };
}
