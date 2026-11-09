import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../main.dart' show themeModeProvider;
import '../../widgets/category_picker.dart';
import '../../widgets/trend_chart.dart';
import '../../widgets/ui.dart';
import '../shell.dart' show Pg, tabProvider;

const _simplefinUrl = 'https://bridge.simplefin.org/my-account';

String _ago(String? iso) {
  if (iso == null) return 'never';
  final d = DateTime.now().difference(DateTime.parse(iso));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
}

/// Backup folder names look like 2026-09-27T04-13-02-922Z.
String _backupLabel(String? name) {
  if (name == null) return 'none yet';
  final m = RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})').firstMatch(name);
  if (m == null) return name;
  final t = DateTime.parse('${m[1]}T${m[2]}:${m[3]}:00Z').toLocal();
  return '${dayLabel(t.toIso8601String().substring(0, 10))} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Actual's own web app: same host on the default port (tailnet), or :5006 when running locally.
Uri _actualUrl() {
  final b = Uri.base;
  final local = b.host == 'localhost' || b.host == '127.0.0.1';
  return Uri(scheme: local ? 'http' : b.scheme, host: b.host, port: local ? 5006 : null, path: '/');
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageScaffold(
      title: 'Settings',
      maxWidth: 820,
      onRefresh: () => ref.refresh(settingsProvider.future),
      body: AsyncBody(ref.watch(settingsProvider), builder: (d) {
        return cardStack([
          const _Appearance(),
          const _Privacy(),
          _Connections(d),
          _MoneyRules(d),
          const _Manage(),
          _Data(d),
          const _Advanced(),
          _About(d),
        ]);
      }),
    );
  }
}

// ---- shared bits ----------------------------------------------------------------

Future<bool> _run(BuildContext context, WidgetRef ref, Future<void> Function(Dio dio) fn, {String? done}) async {
  try {
    await fn(ref.read(dioProvider));
    ref.invalidate(settingsProvider);
    if (done != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    return true;
  } on DioException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
    return false;
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, this.subtitle, required this.trailing});
  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
                ),
            ]),
          ),
          const SizedBox(width: 12),
          trailing,
        ]),
      );
}

// ---- appearance -----------------------------------------------------------------

class _Appearance extends ConsumerWidget {
  const _Appearance();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final hidden = ((prefs['hiddenPages'] as List?) ?? const []).cast<String>().toSet();
    return SectionCard(
      title: 'Appearance',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Row(
          title: 'Theme',
          trailing: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined, size: 18)),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined, size: 18)),
            ],
            selected: {ref.watch(themeModeProvider)},
            onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
          ),
        ),
        _Row(
          title: 'Default chart range',
          subtitle: 'What net worth and balance charts show when they open',
          trailing: DropdownButton<String>(
            value: prefs['defaultRange'],
            underline: const SizedBox.shrink(),
            items: [for (final r in TrendRange.values) DropdownMenuItem(value: r.name, child: Text(r.caption))],
            onChanged: (v) => savePreferences(ref, {'defaultRange': v}),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Pages in the menu', style: TextStyle(fontWeight: FontWeight.w600)),
        Text('Hide pages you don\'t use. You can turn them back on here any time.',
            style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in Pg.values.where((p) => !p.alwaysShown))
            FilterChip(
              avatar: Icon(p.icon, size: 18),
              label: Text(p.label),
              selected: !hidden.contains(p.name),
              onSelected: (on) => savePreferences(ref, {
                'hiddenPages': on ? (hidden.toList()..remove(p.name)) : [...hidden, p.name],
              }),
            ),
        ]),
      ]),
    );
  }
}

// ---- privacy --------------------------------------------------------------------

class _Privacy extends ConsumerWidget {
  const _Privacy();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(prefsProvider)['hideAmounts'] == true;
    return SectionCard(
      title: 'Privacy',
      child: _Row(
        title: 'Hide amounts',
        subtitle: 'Show \$•••• instead of dollar amounts everywhere, e.g. when sharing your screen. Charts keep their shape.',
        trailing: Switch(value: on, onChanged: (v) => savePreferences(ref, {'hideAmounts': v})),
      ),
    );
  }
}

// ---- bank connections -------------------------------------------------------------

class _Connections extends ConsumerStatefulWidget {
  const _Connections(this.d);
  final Map<String, dynamic> d;
  @override
  ConsumerState<_Connections> createState() => _ConnectionsState();
}

class _ConnectionsState extends ConsumerState<_Connections> {
  bool _syncing = false;

  Future<void> _sync() async {
    setState(() => _syncing = true);
    final ok = await _run(context, ref, (dio) => dio.post('/sync'), done: 'Bank sync finished');
    if (ok) refreshAll(ref);
    if (mounted) setState(() => _syncing = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = (widget.d['connections'] as List).cast<Map>();
    final linked = all.where((c) => c['source'] != null).toList();
    final manual = all.length - linked.length;
    return SectionCard(
      title: 'Bank connections',
      action: FilledButton.tonalIcon(
        onPressed: _syncing ? null : _sync,
        icon: _syncing
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.sync, size: 18),
        label: Text(_syncing ? 'Syncing…' : 'Sync now'),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final c in linked)
          Builder(builder: (context) {
            final last = c['lastSync'] as String?;
            final stale = last == null || DateTime.now().difference(DateTime.parse(last)).inHours > 48;
            return _Row(
              title: splitAccountName(c['name']).$1,
              subtitle: 'SimpleFIN',
              trailing: Text('Synced ${_ago(last)}',
                  style: TextStyle(fontSize: 12.5, color: stale ? kLoss : theme.hintColor, fontWeight: FontWeight.w600)),
            );
          }),
        if (manual > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('$manual manual account${manual == 1 ? '' : 's'} (updated by you, not synced)',
                style: TextStyle(fontSize: 12.5, color: theme.hintColor)),
          ),
        const SizedBox(height: 12),
        const Note('If a bank stops updating it usually needs you to log in again at SimpleFIN Bridge. '
            'Sync pulls the latest transactions for every connected account.'),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => launchUrl(Uri.parse(_simplefinUrl)),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Manage connections at SimpleFIN'),
        ),
      ]),
    );
  }
}

// ---- money rules ------------------------------------------------------------------

class _MoneyRules extends StatelessWidget {
  const _MoneyRules(this.d);
  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final c = (d['classification'] as Map).cast<String, dynamic>();
    final defaults = ((d['defaults'] as Map)['classification'] as Map).cast<String, dynamic>();
    return SectionCard(
      title: 'Money rules',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Note('These decide what counts as income and spending on the dashboard, cash flow and reports. '
            'Each entry matches payee names (not case-sensitive; patterns like "sun ?life" work too).'),
        const SizedBox(height: 12),
        _PatternList(
          field: 'investPayees',
          title: 'Investment payees',
          subtitle: 'Money sent to these is "invested", not spending (e.g. your brokerage).',
          values: (c['investPayees'] as List).cast<String>(),
          defaults: (defaults['investPayees'] as List).cast<String>(),
        ),
        const Divider(height: 28),
        _PatternList(
          field: 'transferPayees',
          title: 'Transfer payees',
          subtitle: 'Uncategorized transactions from these are moves between your own accounts (e.g. card payments).',
          values: (c['transferPayees'] as List).cast<String>(),
          defaults: (defaults['transferPayees'] as List).cast<String>(),
        ),
        const Divider(height: 28),
        _SelfBalancing((d['selfBalancing'] as Map?)?.cast<String, dynamic>()),
      ]),
    );
  }
}

/// The category for money that leaves and comes back (fee rebates, reversed charges).
class _SelfBalancing extends ConsumerWidget {
  const _SelfBalancing(this.current);
  final Map<String, dynamic>? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Row(
        title: 'Self-balancing category',
        subtitle: 'Transactions here are left out of income and spending. Its total should stay at \$0. '
            '${current == null ? 'Created as "Self-balancing" the first time you mark a pair.' : 'Now: ${current!['name']}'}',
        trailing: TextButton(
          onPressed: () async {
            final c = await pickCategory(context);
            if (c == null || !context.mounted) return;
            final ok = await _run(context, ref, (dio) => dio.put('/settings/self-balancing', data: {'category': c['id']}),
                done: 'Self-balancing category: ${c['name']}');
            if (ok) refreshAll(ref);
          },
          child: const Text('Change'),
        ),
      );
}

class _PatternList extends ConsumerStatefulWidget {
  const _PatternList({required this.field, required this.title, required this.subtitle, required this.values, required this.defaults});
  final String field, title, subtitle;
  final List<String> values, defaults;
  @override
  ConsumerState<_PatternList> createState() => _PatternListState();
}

class _PatternListState extends ConsumerState<_PatternList> {
  final _ctl = TextEditingController();

  Future<void> _save(List<String>? list) async {
    final ok = await _run(context, ref, (dio) => dio.put('/settings/classification', data: {widget.field: list}));
    if (ok) {
      _ctl.clear();
      refreshAll(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = widget.values.join('|') == widget.defaults.join('|');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w600))),
        if (!isDefault) TextButton(onPressed: () => _save(null), child: const Text('Reset to defaults')),
      ]),
      Text(widget.subtitle, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final v in widget.values)
          InputChip(label: Text(v), onDeleted: () => _save([...widget.values]..remove(v))),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        width: 320,
        child: TextField(
          controller: _ctl,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Add a payee…',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _ctl.text.trim().isEmpty ? null : _save([...widget.values, _ctl.text.trim()]),
            ),
          ),
          onSubmitted: (v) => v.trim().isEmpty ? null : _save([...widget.values, v.trim()]),
        ),
      ),
    ]);
  }
}

// ---- manage -----------------------------------------------------------------------

class _Manage extends ConsumerWidget {
  const _Manage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget tile(Pg p, String sub) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(p.icon),
          title: Text(p.label),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => ref.read(tabProvider.notifier).go(p),
        );
    return SectionCard(
      title: 'Accounts & categories',
      child: Column(children: [
        tile(Pg.accounts, 'Add manual accounts, change types, hide or unhide accounts'),
        tile(Pg.categories, 'Create, rename and group categories'),
        tile(Pg.rules, 'Auto-categorize transactions by payee'),
      ]),
    );
  }
}

// ---- data -------------------------------------------------------------------------

class _Data extends ConsumerStatefulWidget {
  const _Data(this.d);
  final Map<String, dynamic> d;
  @override
  ConsumerState<_Data> createState() => _DataState();
}

class _DataState extends ConsumerState<_Data> {
  String _range = 'all';
  bool _busy = false;

  Uri _exportUrl() {
    final now = DateTime.now();
    String ymd(DateTime d) => d.toIso8601String().substring(0, 10);
    final from = switch (_range) {
      'year' => ymd(DateTime(now.year, 1, 1)),
      '12m' => ymd(DateTime(now.year - 1, now.month, now.day)),
      _ => null,
    };
    return Uri.base.resolve('api/export.csv').replace(queryParameters: {'from': ?from});
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.d['backups'] as Map;
    return SectionCard(
      title: 'Data',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Row(
          title: 'Export transactions',
          subtitle: 'CSV for spreadsheets or your accountant (hidden accounts left out)',
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            DropdownButton<String>(
              value: _range,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All time')),
                DropdownMenuItem(value: 'year', child: Text('This year')),
                DropdownMenuItem(value: '12m', child: Text('Last 12 months')),
              ],
              onChanged: (v) => setState(() => _range = v!),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => launchUrl(_exportUrl()),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('CSV'),
            ),
          ]),
        ),
        _Row(
          title: 'Backups',
          subtitle: '${b['count']} snapshots · latest ${_backupLabel(b['latest'])}. '
              'Taken automatically before changes (at most every 10 minutes); the last 30 are kept.',
          trailing: OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    await _run(context, ref, (dio) => dio.post('/backup'), done: 'Backup saved');
                    if (mounted) setState(() => _busy = false);
                  },
            child: Text(_busy ? 'Saving…' : 'Back up now'),
          ),
        ),
      ]),
    );
  }
}

// ---- advanced ---------------------------------------------------------------------

class _Advanced extends ConsumerWidget {
  const _Advanced();

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
        title: 'Advanced',
        child: _Row(
          title: 'Re-download budget from Actual',
          subtitle: 'Fixes "out of sync" errors when saving. Nothing is lost: the server copy is used and the '
              'local copy is kept in backups.',
          trailing: OutlinedButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Re-download budget?'),
                  content: const Text('The app will reload all data from your Actual server. This takes a few seconds.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Re-download')),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                if (await _run(context, ref, (dio) => dio.post('/maintenance/redownload'), done: 'Budget re-downloaded')) {
                  refreshAll(ref);
                }
              }
            },
            child: const Text('Re-download'),
          ),
        ),
      );
}

// ---- about ------------------------------------------------------------------------

class _About extends StatelessWidget {
  const _About(this.d);
  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final about = d['about'] as Map;
    return SectionCard(
      title: 'About',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Row(title: 'Ledger', subtitle: 'Your app', trailing: const Text('1.0.0')),
        _Row(
          title: 'Actual Budget server',
          subtitle: 'Stores your data and runs bank sync',
          trailing: Text(about['serverVersion']?.toString() ?? 'unreachable'),
        ),
        TextButton.icon(
          onPressed: () => launchUrl(_actualUrl()),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Open Actual'),
        ),
      ]),
    );
  }
}
