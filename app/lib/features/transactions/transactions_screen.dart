import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/account_forms.dart';
import '../../widgets/category_picker.dart';
import '../../widgets/payee_rule.dart';
import '../../widgets/ui.dart' show splitAccountName;

class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});
  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

enum _DateFilter {
  all('All dates'),
  thisMonth('This month'),
  lastMonth('Last month'),
  last30('Last 30 days'),
  last90('Last 3 months'),
  thisYear('This year'),
  custom('Custom range…');

  const _DateFilter(this.label);
  final String label;
}

const _kinds = {
  null: 'All types',
  'expense': 'Expenses',
  'income': 'Income',
  'transfer': 'Transfers',
  'uncategorized': 'Uncategorized',
};

String _ymd(DateTime d) => d.toIso8601String().substring(0, 10);

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  String _search = '';
  String? _kind;
  _DateFilter _date = _DateFilter.all;
  DateTimeRange? _custom;
  ({String id, String name})? _category, _account;
  int _limit = 60;
  Timer? _deb;
  final _searchCtl = TextEditingController();

  @override
  void dispose() {
    _deb?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  (String?, String?) get _range {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_date) {
      _DateFilter.all => (null, null),
      _DateFilter.thisMonth => (_ymd(DateTime(now.year, now.month, 1)), _ymd(today)),
      _DateFilter.lastMonth => (_ymd(DateTime(now.year, now.month - 1, 1)), _ymd(DateTime(now.year, now.month, 0))),
      _DateFilter.last30 => (_ymd(today.subtract(const Duration(days: 29))), _ymd(today)),
      _DateFilter.last90 => (_ymd(today.subtract(const Duration(days: 89))), _ymd(today)),
      _DateFilter.thisYear => (_ymd(DateTime(now.year, 1, 1)), _ymd(today)),
      _DateFilter.custom => _custom == null ? (null, null) : (_ymd(_custom!.start), _ymd(_custom!.end)),
    };
  }

  bool get _filtered => _kind != null || _date != _DateFilter.all || _category != null || _account != null || _search.isNotEmpty;

  void _update(VoidCallback f) => setState(() {
        f();
        _limit = 60;
      });

  Future<void> _pickDate(_DateFilter f) async {
    if (f != _DateFilter.custom) return _update(() => _date = f);
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _custom,
    );
    if (r != null) _update(() { _date = f; _custom = r; });
  }

  @override
  Widget build(BuildContext context) {
    final (from, to) = _range;
    final q = txQuery(
      search: _search, limit: _limit, kind: _kind, from: from, to: to,
      category: _category?.id, account: _account?.id,
    );
    final txs = ref.watch(transactionsProvider(q));
    final summary = ref.watch(txSummaryProvider(txQuery(
      search: _search, limit: 0, kind: _kind, from: from, to: to, category: _category?.id, account: _account?.id,
    )));
    final accounts = ref.watch(accountsProvider).value;
    final theme = Theme.of(context);
    final dateLabel = _date == _DateFilter.custom && _custom != null
        ? '${dayShort(_ymd(_custom!.start))} – ${dayShort(_ymd(_custom!.end))}'
        : _date.label;
    return Scaffold(
      appBar: AppBar(title: const Text('Transactions', style: TextStyle(fontWeight: FontWeight.w800))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAddTransaction(context),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchCtl,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search payee or notes',
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
                onChanged: (v) {
                  _deb?.cancel();
                  _deb = Timer(const Duration(milliseconds: 350), () => _update(() => _search = v.trim()));
                },
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _MenuChip<_DateFilter>(
                    icon: Icons.calendar_today_outlined,
                    label: dateLabel,
                    active: _date != _DateFilter.all,
                    options: {for (final f in _DateFilter.values) f: f.label},
                    onSelected: _pickDate,
                  ),
                  _MenuChip<String?>(
                    icon: Icons.swap_vert,
                    label: _kinds[_kind]!,
                    active: _kind != null,
                    options: _kinds,
                    onSelected: (k) => _update(() => _kind = k),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      avatar: const Icon(Icons.category_outlined, size: 18),
                      label: Text(_category?.name ?? 'Category'),
                      selected: _category != null,
                      showCheckmark: false,
                      onPressed: () async {
                        final c = await pickCategory(context);
                        if (c != null) _update(() => _category = (id: c['id']!, name: c['name']!));
                      },
                      onDeleted: _category == null ? null : () => _update(() => _category = null),
                    ),
                  ),
                  if (accounts != null)
                    _MenuChip<({String id, String name})?>(
                      icon: Icons.account_balance_outlined,
                      label: _account?.name ?? 'All accounts',
                      active: _account != null,
                      options: {
                        null: 'All accounts',
                        for (final g in (accounts['groups'] as List).cast<Map>())
                          for (final a in (g['accounts'] as List).cast<Map>())
                            (id: a['id'] as String, name: splitAccountName(a['name']).$1): splitAccountName(a['name']).$1,
                      },
                      onSelected: (a) => _update(() => _account = a),
                    ),
                  if (_filtered)
                    TextButton(
                      onPressed: () => _update(() {
                        _kind = null;
                        _date = _DateFilter.all;
                        _custom = null;
                        _category = null;
                        _account = null;
                        _search = '';
                        _searchCtl.clear();
                      }),
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  summary.value == null
                      ? ' '
                      : '${summary.value!['count']} transactions  ·  '
                          '${money(summary.value!['inflow'] as num, whole: true)} in  ·  '
                          '${money(summary.value!['outflow'] as num, whole: true)} out',
                  style: TextStyle(fontSize: 12.5, color: theme.hintColor, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            Expanded(
              child: txs.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text(errText(e))),
                data: (list) {
                  if (list.isEmpty) {
                    return Center(
                      child: Text(_filtered ? 'No transactions match these filters' : 'No transactions',
                          style: TextStyle(color: theme.hintColor)),
                    );
                  }
                  final rows = <Widget>[];
                  String? day;
                  for (final t in list) {
                    if (t['date'] != day) {
                      day = t['date'];
                      rows.add(Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                        child: Text(dayLabel(day!), style: theme.textTheme.labelLarge?.copyWith(color: theme.hintColor)),
                      ));
                    }
                    rows.add(_TxTile(t, onEdit: () => _edit(t)));
                  }
                  if (list.length >= _limit) {
                    rows.add(Padding(
                      padding: const EdgeInsets.all(16),
                      child: OutlinedButton(onPressed: () => setState(() => _limit += 60), child: const Text('Load more')),
                    ));
                  }
                  return RefreshIndicator(
                    onRefresh: () async => ref.refresh(transactionsProvider(q).future),
                    child: ListView(padding: const EdgeInsets.only(bottom: 88), children: rows),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _edit(Map<String, dynamic> t) async {
    final saved = await showModalBottomSheet<({String? cat, String? catName})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => _EditSheet(t),
    );
    if (saved == null) return;
    refreshAll(ref);
    if (mounted && saved.cat != null && saved.cat != t['category'] && !(t['transfer'] as bool)) {
      offerPayeeRule(context, ref, txId: t['id'], payee: t['payee'], catName: saved.catName ?? '');
    }
  }
}

class _TxTile extends StatelessWidget {
  const _TxTile(this.t, {required this.onEdit});
  final Map<String, dynamic> t;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) {
    final amt = (t['amount'] as num).toDouble();
    final theme = Theme.of(context);
    final cat = t['categoryName'] as String?;
    return ListTile(
      onTap: onEdit,
      title: Text(t['payee'].toString().isEmpty ? '—' : t['payee'], maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${t['accountName'].toString().split(' (').first}  ·  ${t['transfer'] ? 'Transfer' : (cat ?? 'Uncategorized')}',
        style: TextStyle(color: cat == null && !t['transfer'] ? kLoss : theme.hintColor, fontSize: 12.5),
      ),
      trailing: Text(money(amt), style: TextStyle(fontWeight: FontWeight.w700, color: amt > 0 ? kGain : null)),
    );
  }
}

class _EditSheet extends ConsumerStatefulWidget {
  const _EditSheet(this.t);
  final Map<String, dynamic> t;
  @override
  ConsumerState<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends ConsumerState<_EditSheet> {
  late final _notes = TextEditingController(text: widget.t['notes']);
  String? _cat, _catName;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _cat = widget.t['category'];
    _catName = widget.t['categoryName'];
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(dioProvider).patch('/transactions/${widget.t['id']}',
          data: {'category': _cat, 'notes': _notes.text});
      if (mounted) Navigator.pop(context, (cat: _cat, catName: _catName));
    } on DioException catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t['payee'], style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        Text('${money((t['amount'] as num).toDouble())} · ${dayLabel(t['date'])} · ${t['accountName']}',
            style: TextStyle(color: Theme.of(context).hintColor)),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: const Icon(Icons.category_outlined),
          label: Text(_catName ?? 'Choose category'),
          onPressed: () async {
            final c = await pickCategory(context);
            if (c != null) setState(() { _cat = c['id']; _catName = c['name']; });
          },
        ),
        const SizedBox(height: 12),
        TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder())),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        ),
      ]),
    );
  }
}

/// Filter chip that opens a menu of options.
class _MenuChip<T> extends StatelessWidget {
  const _MenuChip({required this.icon, required this.label, required this.active, required this.options, required this.onSelected});
  final IconData icon;
  final String label;
  final bool active;
  final Map<T, String> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: MenuAnchor(
          menuChildren: [
            for (final e in options.entries)
              MenuItemButton(onPressed: () => onSelected(e.key), child: Text(e.value)),
          ],
          builder: (context, ctl, _) => FilterChip(
            avatar: Icon(icon, size: 18),
            label: Row(mainAxisSize: MainAxisSize.min, children: [Text(label), const Icon(Icons.arrow_drop_down, size: 18)]),
            selected: active,
            showCheckmark: false,
            onSelected: (_) => ctl.isOpen ? ctl.close() : ctl.open(),
          ),
        ),
      );
}
