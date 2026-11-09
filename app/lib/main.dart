import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/api.dart';
import 'core/format.dart';
import 'core/theme.dart';
import 'features/shell.dart';
import 'widgets/trend_chart.dart';

void main() => runApp(const ProviderScope(child: LedgerApp()));

/// Theme follows the saved preference; changing it saves it.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.values.byName(
      ThemeMode.values.any((m) => m.name == ref.watch(prefsProvider)['theme']) ? ref.watch(prefsProvider)['theme'] : 'system');

  void set(ThemeMode m) {
    state = m;
    ref.read(dioProvider).put('/settings/preferences', data: {'theme': m.name}).then((_) => ref.invalidate(settingsProvider));
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class LedgerApp extends ConsumerWidget {
  const LedgerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    // Display prefs are read by plain formatting functions, so rebuild the whole tree when they change.
    maskAmounts = prefs['hideAmounts'] == true;
    defaultTrendRange = TrendRange.values.firstWhere((r) => r.name == prefs['defaultRange'], orElse: () => TrendRange.m1);
    return MaterialApp(
      title: 'Ledger',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      home: KeyedSubtree(key: ValueKey('$maskAmounts|${defaultTrendRange.name}'), child: const Shell()),
    );
  }
}
