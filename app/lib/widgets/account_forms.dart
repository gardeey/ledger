import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api.dart';
import '../core/format.dart';
import 'category_picker.dart';
import 'ui.dart';

double? _parseMoney(String s) => double.tryParse(s.replaceAll(RegExp(r'[,$\s]'), ''));
String _ymd(DateTime d) => d.toIso8601String().substring(0, 10);
final _moneyInput = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$]'))];

/// POST and refresh everything; shows a snackbar on failure. Returns whether it worked.
Future<bool> _post(BuildContext context, WidgetRef ref, String path, Map<String, dynamic> body) async {
  try {
    await ref.read(dioProvider).post(path, data: body);
    refreshAll(ref);
    return true;
  } on DioException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
    return false;
  }
}

Future<T?> _sheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(child: child),
      ),
    );

Widget _title(BuildContext context, String t, [String? sub]) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      if (sub != null) ...[
        const SizedBox(height: 4),
        Text(sub, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
      ],
      const SizedBox(height: 16),
    ]);

// ---- add account ------------------------------------------------------------------

Future<void> showAddAccount(BuildContext context) => _sheet(context, const _AddAccount());

class _AddAccount extends ConsumerStatefulWidget {
  const _AddAccount();
  @override
  ConsumerState<_AddAccount> createState() => _AddAccountState();
}

class _AddAccountState extends ConsumerState<_AddAccount> {
  final _name = TextEditingController();
  final _balance = TextEditingController();
  String _type = 'property';
  bool _onBudget = false;
  bool _busy = false;

  static const _hints = {
    'cash': 'e.g. Wallet',
    'investment': 'e.g. Workplace pension',
    'property': 'e.g. Home – 123 Main St',
    'vehicle': 'e.g. 2021 Civic',
    'other': 'e.g. Collectibles',
    'credit': 'e.g. Store card',
    'loan': 'e.g. Mortgage, Student loan',
  };

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final ok = await _post(context, ref, '/accounts', {
      'name': _name.text.trim(),
      'type': _type,
      'balance': _parseMoney(_balance.text) ?? 0,
      'onBudget': _onBudget,
    });
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final debt = kLiabilityTypes.contains(_type);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(context, 'Add account', 'For things your bank doesn\'t sync: a home, car, loan, pension or cash.'),
      DropdownButtonFormField<String>(
        initialValue: _type,
        decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
        items: [for (final e in kAccountTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1))],
        onChanged: (v) => setState(() {
          _type = v!;
          _onBudget = v == 'cash';
        }),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _name,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: 'Name', hintText: _hints[_type], border: const OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _balance,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: _moneyInput,
        decoration: InputDecoration(
          labelText: debt ? 'Amount owed' : 'Current value',
          prefixText: r'$ ',
          border: const OutlineInputBorder(),
        ),
      ),
      if (_type == 'cash')
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _onBudget,
          onChanged: (v) => setState(() => _onBudget = v),
          title: const Text('Include in budget'),
          subtitle: const Text('Spending from this account counts against your budget categories'),
        ),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Adding…' : 'Add account')),
      ),
    ]);
  }
}

// ---- update balance ---------------------------------------------------------------

Future<void> showUpdateBalance(BuildContext context, Map account) => _sheet(context, _UpdateBalance(account));

class _UpdateBalance extends ConsumerStatefulWidget {
  const _UpdateBalance(this.a);
  final Map a;
  @override
  ConsumerState<_UpdateBalance> createState() => _UpdateBalanceState();
}

class _UpdateBalanceState extends ConsumerState<_UpdateBalance> {
  late final bool _debt = kLiabilityTypes.contains(widget.a['type']);
  late final _value = TextEditingController(text: ((widget.a['balance'] as num).abs()).toStringAsFixed(2));
  final _note = TextEditingController();
  DateTime _date = DateTime.now();
  bool _busy = false;

  Future<void> _save() async {
    final v = _parseMoney(_value.text);
    if (v == null) return;
    setState(() => _busy = true);
    final ok = await _post(context, ref, '/accounts/${widget.a['id']}/balance', {
      'balance': _debt ? -v : v,
      'date': _ymd(_date),
      'note': _note.text.trim(),
    });
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = (widget.a['balance'] as num).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(context, 'Update balance',
          'Currently ${money(current.abs())}${_debt ? ' owed' : ''}. The difference is recorded as a balance adjustment, '
          'which changes net worth but isn\'t counted as income or spending.'),
      TextField(
        controller: _value,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: _moneyInput,
        decoration: InputDecoration(
          labelText: _debt ? 'Amount owed now' : 'Value now',
          prefixText: r'$ ',
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      _DateField(value: _date, onChanged: (d) => setState(() => _date = d)),
      const SizedBox(height: 12),
      TextField(
        controller: _note,
        decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. 2026 appraisal', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Update')),
      ),
    ]);
  }
}

// ---- change type ------------------------------------------------------------------

Future<void> showChangeType(BuildContext context, WidgetRef ref, Map account) async {
  final type = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Account type'),
      children: [
        for (final e in kAccountTypes.entries)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, e.key),
            child: Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: e.value.$2, shape: BoxShape.circle)),
              const SizedBox(width: 12),
              Expanded(child: Text(e.value.$1)),
              if (e.key == account['type']) const Icon(Icons.check, size: 18),
            ]),
          ),
      ],
    ),
  );
  if (type != null && type != account['type'] && context.mounted) {
    await _post(context, ref, '/accounts/${account['id']}/type', {'type': type});
  }
}

// ---- add transaction --------------------------------------------------------------

Future<void> showAddTransaction(BuildContext context, {String? accountId}) =>
    _sheet(context, _AddTransaction(accountId: accountId));

enum _Kind { expense, income, transfer }

class _AddTransaction extends ConsumerStatefulWidget {
  const _AddTransaction({this.accountId});
  final String? accountId;
  @override
  ConsumerState<_AddTransaction> createState() => _AddTransactionState();
}

class _AddTransactionState extends ConsumerState<_AddTransaction> {
  _Kind _kind = _Kind.expense;
  late String? _account = widget.accountId;
  String? _to;
  final _amount = TextEditingController();
  final _payee = TextEditingController();
  final _notes = TextEditingController();
  Map<String, String>? _category;
  DateTime _date = DateTime.now();
  bool _busy = false;

  Future<void> _save() async {
    final amt = _parseMoney(_amount.text);
    if (_account == null || amt == null || amt == 0) return;
    if (_kind == _Kind.transfer && (_to == null || _to == _account)) return;
    setState(() => _busy = true);
    final ok = await _post(context, ref, '/transactions', {
      'account': _account,
      'date': _ymd(_date),
      'amount': _kind == _Kind.income ? amt.abs() : -amt.abs(),
      'notes': _notes.text.trim(),
      if (_kind == _Kind.transfer) 'transferTo': _to,
      if (_kind != _Kind.transfer) 'payee': _payee.text.trim(),
      if (_kind != _Kind.transfer) 'category': _category?['id'],
    });
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(accountsProvider).value;
    final accounts = data == null ? <Map>[] : allAccounts(data);
    DropdownMenuItem<String> item(Map a) =>
        DropdownMenuItem(value: a['id'] as String, child: Text(splitAccountName(a['name']).$1, overflow: TextOverflow.ellipsis));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(context, 'Add transaction'),
      SegmentedButton<_Kind>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: _Kind.expense, label: Text('Expense')),
          ButtonSegment(value: _Kind.income, label: Text('Income')),
          ButtonSegment(value: _Kind.transfer, label: Text('Transfer')),
        ],
        selected: {_kind},
        onSelectionChanged: (s) => setState(() => _kind = s.first),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        initialValue: _account,
        isExpanded: true,
        decoration: InputDecoration(labelText: _kind == _Kind.transfer ? 'From account' : 'Account', border: const OutlineInputBorder()),
        items: [for (final a in accounts) item(a)],
        onChanged: (v) => setState(() => _account = v),
      ),
      if (_kind == _Kind.transfer) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _to,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'To account',
            helperText: 'e.g. a loan payment: from chequing to the loan',
            border: OutlineInputBorder(),
          ),
          items: [for (final a in accounts.where((a) => a['id'] != _account)) item(a)],
          onChanged: (v) => setState(() => _to = v),
        ),
      ],
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _moneyInput,
            decoration: const InputDecoration(labelText: 'Amount', prefixText: r'$ ', border: OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: _DateField(value: _date, onChanged: (d) => setState(() => _date = d))),
      ]),
      if (_kind != _Kind.transfer) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _payee,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: _kind == _Kind.income ? 'From' : 'Payee',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.category_outlined),
          label: Text(_category?['name'] ?? 'Choose category'),
          onPressed: () async {
            final c = await pickCategory(context);
            if (c != null) setState(() => _category = c);
          },
        ),
      ],
      const SizedBox(height: 12),
      TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes (optional)', border: OutlineInputBorder())),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Add')),
      ),
    ]);
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.value, required this.onChanged});
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          final d = await showDatePicker(context: context, initialDate: value, firstDate: DateTime(2000), lastDate: DateTime(2100));
          if (d != null) onChanged(d);
        },
        child: InputDecorator(
          decoration: const InputDecoration(labelText: 'Date', border: OutlineInputBorder(), suffixIcon: Icon(Icons.calendar_today_outlined, size: 18)),
          child: Text(dayLabel(_ymd(value))),
        ),
      );
}
