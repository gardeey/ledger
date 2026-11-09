import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api.dart';
import '../core/theme.dart';
import 'accounts/accounts_screen.dart';
import 'budget/budget_screen.dart';
import 'categories/categories_screen.dart';
import 'cashflow/cashflow_screen.dart';
import 'goals/goals_screen.dart';
import 'home/home_screen.dart';
import 'inbox/inbox_screen.dart';
import 'investments/investments_screen.dart';
import 'recurring/recurring_screen.dart';
import 'reports/reports_screen.dart';
import 'rules/rules_screen.dart';
import 'settings/settings_screen.dart';
import 'transactions/transactions_screen.dart';

/// App pages, in sidebar order. `review` pages sit in the second ("Manage") sidebar section.
enum Pg {
  dashboard('Dashboard', Icons.dashboard_outlined, Icons.dashboard),
  accounts('Accounts', Icons.account_balance_outlined, Icons.account_balance),
  transactions('Transactions', Icons.receipt_long_outlined, Icons.receipt_long),
  cashflow('Cash flow', Icons.bar_chart_outlined, Icons.bar_chart),
  reports('Reports', Icons.pie_chart_outline, Icons.pie_chart),
  budget('Budget', Icons.savings_outlined, Icons.savings),
  recurring('Recurring', Icons.event_repeat_outlined, Icons.event_repeat),
  goals('Goals', Icons.flag_outlined, Icons.flag),
  investments('Investments', Icons.show_chart_outlined, Icons.show_chart),
  inbox('Inbox', Icons.inbox_outlined, Icons.inbox, review: true),
  categories('Categories', Icons.category_outlined, Icons.category, review: true),
  rules('Rules', Icons.tune_outlined, Icons.tune, review: true),
  settings('Settings', Icons.settings_outlined, Icons.settings, review: true);

  /// Pages that can't be hidden from the menu (Settings > Appearance).
  bool get alwaysShown => this == Pg.dashboard || this == Pg.settings;

  const Pg(this.label, this.icon, this.selectedIcon, {this.review = false});
  final String label;
  final IconData icon, selectedIcon;
  final bool review;

  Widget build() => switch (this) {
        Pg.dashboard => const HomeScreen(),
        Pg.accounts => const AccountsScreen(),
        Pg.transactions => const TransactionsScreen(),
        Pg.cashflow => const CashFlowScreen(),
        Pg.reports => const ReportsScreen(),
        Pg.budget => const BudgetScreen(),
        Pg.recurring => const RecurringScreen(),
        Pg.goals => const GoalsScreen(),
        Pg.investments => const InvestmentsScreen(),
        Pg.inbox => const InboxScreen(),
        Pg.categories => const CategoriesScreen(),
        Pg.rules => const RulesScreen(),
        Pg.settings => const SettingsScreen(),
      };
}

/// Pages on the phone bottom bar; the rest live under "More".
const _bottom = [Pg.dashboard, Pg.accounts, Pg.transactions, Pg.budget];

/// Pages shown in navigation, honouring Settings > Appearance > hidden pages.
List<Pg> visiblePages(WidgetRef ref) {
  final hidden = ((ref.watch(prefsProvider)['hiddenPages'] as List?) ?? const []).toSet();
  return [for (final p in Pg.values) if (p.alwaysShown || !hidden.contains(p.name)) p];
}

class TabNotifier extends Notifier<Pg> {
  @override
  Pg build() => Pg.dashboard;
  void go(Pg p) => state = p;
}

final tabProvider = NotifierProvider<TabNotifier, Pg>(TabNotifier.new);

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  // Build pages on first visit (then keep them alive) so startup doesn't fetch every page.
  final _visited = <Pg>{Pg.dashboard};

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(tabProvider);
    _visited.add(tab);
    // Each suggested pair counts once, not once per uncategorized half.
    final pairs = ((ref.watch(pairsProvider).value?['pairs'] as List?) ?? const []).cast<Map>();
    final paired = {for (final p in pairs) ...[(p['out'] as Map)['id'], (p['in'] as Map)['id']]};
    final count = (ref.watch(inboxProvider).value?.where((t) => !paired.contains(t['id'])).length ?? 0) + pairs.length;
    final wide = MediaQuery.of(context).size.width >= 800;
    final body = IndexedStack(
      index: tab.index,
      children: [for (final p in Pg.values) _visited.contains(p) ? p.build() : const SizedBox.shrink()],
    );
    final go = ref.read(tabProvider.notifier).go;
    final pages = visiblePages(ref);
    if (wide) {
      return Scaffold(
        body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Sidebar(tab: tab, pages: pages, inboxCount: count, onSelect: go),
          Expanded(child: body),
        ]),
      );
    }
    final bottom = _bottom.where(pages.contains).toList();
    final bottomIndex = bottom.indexOf(tab);
    Widget badge(Widget icon) => Badge(isLabelVisible: count > 0, label: Text('$count'), child: icon);
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: bottomIndex < 0 ? bottom.length : bottomIndex,
        onDestinationSelected: (i) => i < bottom.length ? go(bottom[i]) : _showMore(context, tab, count, pages, bottom),
        destinations: [
          for (final p in bottom)
            NavigationDestination(icon: Icon(p.icon), selectedIcon: Icon(p.selectedIcon), label: p.label),
          NavigationDestination(
            icon: badge(const Icon(Icons.menu)),
            selectedIcon: badge(const Icon(Icons.menu_open)),
            label: bottomIndex < 0 ? tab.label : 'More',
          ),
        ],
      ),
    );
  }

  void _showMore(BuildContext context, Pg tab, int inboxCount, List<Pg> pages, List<Pg> bottom) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final p in pages.where((p) => !bottom.contains(p)))
              ListTile(
                leading: Icon(p == tab ? p.selectedIcon : p.icon),
                title: Text(p.label, style: TextStyle(fontWeight: p == tab ? FontWeight.w700 : FontWeight.w500)),
                selected: p == tab,
                trailing: p == Pg.inbox && inboxCount > 0 ? _CountPill(inboxCount) : null,
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(tabProvider.notifier).go(p);
                },
              ),
          ]),
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: kLoss, borderRadius: BorderRadius.circular(10)),
        child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );
}

/// Desktop navigation: a labelled sidebar in the style of Monarch / Sure.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.tab, required this.pages, required this.inboxCount, required this.onSelect});
  final Pg tab;
  final List<Pg> pages;
  final int inboxCount;
  final ValueChanged<Pg> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget item(Pg p) {
      final sel = p == tab;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        child: Material(
          color: sel ? cs.surfaceContainerHighest : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSelect(p),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(sel ? p.selectedIcon : p.icon, size: 20, color: sel ? cs.onSurface : theme.hintColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(p.label,
                      style: TextStyle(
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? cs.onSurface : theme.hintColor,
                      )),
                ),
                if (p == Pg.inbox && inboxCount > 0) _CountPill(inboxCount),
              ]),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        border: Border(right: BorderSide(color: theme.dividerColor.withValues(alpha: .4))),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
              child: Row(children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: kGain, borderRadius: BorderRadius.circular(9)),
                  child: const Icon(Icons.show_chart, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                Text('Ledger', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              ]),
            ),
            for (final p in pages.where((p) => !p.review)) item(p),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 6),
              child: Text('MANAGE',
                  style: TextStyle(fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w700, color: theme.hintColor)),
            ),
            for (final p in pages.where((p) => p.review)) item(p),
            const SizedBox(height: 16),
          ]),
        ),
      ),
    );
  }
}
