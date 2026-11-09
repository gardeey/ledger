import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In production the app is served same-origin (proxy -> bridge), so base is the relative 'api'.
/// For `flutter run`, pass --dart-define=API_BASE=http://localhost:8081/api
const _base = String.fromEnvironment('API_BASE', defaultValue: 'api');

final dioProvider = Provider<Dio>((ref) => Dio(BaseOptions(
      baseUrl: _base,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 90),
    )));

final dashboardProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(dioProvider).get('/dashboard');
  return Map<String, dynamic>.from(res.data as Map);
});

final categoriesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(dioProvider).get('/categories');
  return (res.data as List).cast<Map<String, dynamic>>();
});

final inboxProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(dioProvider).get('/inbox');
  return (res.data as List).cast<Map<String, dynamic>>();
});

/// {pairs: [{id, kind: transfer|reversal|reimbursement, days, out, in}], selfBalancing: {category, net}?}
final pairsProvider = FutureProvider.autoDispose((ref) => _getMap(ref, '/pairs'));

/// kind: expense | income | transfer | uncategorized. from/to: inclusive YYYY-MM-DD.
typedef TxQuery = ({
  String search,
  bool uncategorized,
  int limit,
  String? account,
  String? category,
  String? from,
  String? to,
  String? kind,
});

TxQuery txQuery({
  String search = '',
  bool uncategorized = false,
  int limit = 60,
  String? account,
  String? category,
  String? from,
  String? to,
  String? kind,
}) =>
    (search: search, uncategorized: uncategorized, limit: limit, account: account, category: category, from: from, to: to, kind: kind);

Map<String, dynamic> _txParams(TxQuery q) => {
      if (q.search.isNotEmpty) 'search': q.search,
      if (q.uncategorized) 'uncategorized': '1',
      'account': ?q.account,
      'category': ?q.category,
      'from': ?q.from,
      'to': ?q.to,
      'kind': ?q.kind,
    };

final transactionsProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, TxQuery>((ref, q) async {
  final res = await ref.watch(dioProvider).get('/transactions', queryParameters: {..._txParams(q), 'limit': q.limit});
  return (res.data as List).cast<Map<String, dynamic>>();
});

/// {count, inflow, outflow} for the same filters (limit ignored).
final txSummaryProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, TxQuery>((ref, q) async {
  final res = await ref.watch(dioProvider).get('/transactions/summary', queryParameters: _txParams(q));
  return Map<String, dynamic>.from(res.data as Map);
});

final rulesProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(dioProvider).get('/rules');
  return Map<String, dynamic>.from(res.data as Map);
});

Future<Map<String, dynamic>> _getMap(Ref ref, String path, [Map<String, dynamic>? query]) async {
  final res = await ref.watch(dioProvider).get(path, queryParameters: query);
  return Map<String, dynamic>.from(res.data as Map);
}

final accountsProvider = FutureProvider.autoDispose((ref) => _getMap(ref, '/accounts'));
final cashflowProvider = FutureProvider.autoDispose((ref) => _getMap(ref, '/cashflow', {'months': 12}));
final recurringProvider = FutureProvider.autoDispose((ref) => _getMap(ref, '/recurring'));
final goalsProvider = FutureProvider.autoDispose((ref) => _getMap(ref, '/goals'));

/// month: YYYY-MM
final budgetProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
    (ref, month) => _getMap(ref, '/budget', {'month': month}));

/// Inclusive YYYY-MM-DD range.
final reportsProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, ({String from, String to})>(
    (ref, r) => _getMap(ref, '/reports', {'from': r.from, 'to': r.to}));

/// Settings page data (preferences, payee rules, connections, backups, versions). Kept alive: the whole app reads prefs.
final settingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final res = await ref.watch(dioProvider).get('/settings');
  return Map<String, dynamic>.from(res.data as Map);
});

const kDefaultPrefs = <String, dynamic>{'theme': 'system', 'hideAmounts': false, 'defaultRange': 'm1', 'hiddenPages': <String>[]};

/// Current preferences (defaults until settings load).
final prefsProvider = Provider<Map<String, dynamic>>((ref) =>
    {...kDefaultPrefs, ...?(ref.watch(settingsProvider).value?['preferences'] as Map?)?.cast<String, dynamic>()});

Future<void> savePreferences(WidgetRef ref, Map<String, dynamic> patch) async {
  await ref.read(dioProvider).put('/settings/preferences', data: patch);
  ref.invalidate(settingsProvider);
}

/// Refresh everything derived from transactions after a write.
void refreshAll(WidgetRef ref) {
  ref.invalidate(categoriesProvider);
  ref.invalidate(dashboardProvider);
  ref.invalidate(accountsProvider);
  ref.invalidate(cashflowProvider);
  ref.invalidate(recurringProvider);
  ref.invalidate(budgetProvider);
  ref.invalidate(reportsProvider);
  ref.invalidate(goalsProvider);
  ref.invalidate(inboxProvider);
  ref.invalidate(pairsProvider);
  ref.invalidate(rulesProvider);
  ref.invalidate(transactionsProvider);
  ref.invalidate(txSummaryProvider);
}

String errText(Object e) {
  if (e is DioException) {
    final d = e.response?.data;
    if (d is Map && d['message'] != null) return d['message'].toString();
    return e.message ?? 'Network error';
  }
  return e.toString();
}
