import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../widgets/category_picker.dart';
import '../../widgets/ui.dart';

/// Create, rename, regroup and delete categories and category groups (stored in Actual).
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(categoriesProvider);
    return PageScaffold(
      title: 'Categories',
      maxWidth: 800,
      onRefresh: () => ref.refresh(categoriesProvider.future),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newGroup(context, ref),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('New group'),
      ),
      body: AsyncBody(data, builder: (groups) {
        // Expense groups first, income last (like Actual).
        final sorted = [...groups.where((g) => g['income'] != true), ...groups.where((g) => g['income'] == true)];
        return cardStack([
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Note('Groups collect related categories (e.g. "Housing" → Rent, Utilities, Internet). '
                  'Reports, cash flow and the budget roll spending up by group.'),
            ),
          ),
          for (final g in sorted) _GroupCard(g, groups: groups),
        ]);
      }),
    );
  }
}

Future<void> _call(BuildContext context, WidgetRef ref, Future<Response> Function(Dio dio) fn) async {
  try {
    await fn(ref.read(dioProvider));
    ref.invalidate(categoriesProvider);
    refreshAll(ref);
  } on DioException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errText(e))));
  }
}

Future<void> _newGroup(BuildContext context, WidgetRef ref) async {
  final name = await promptText(context, title: 'New group', label: 'Group name');
  if (name != null && context.mounted) await _call(context, ref, (dio) => dio.post('/category-groups', data: {'name': name}));
}

class _GroupCard extends ConsumerWidget {
  const _GroupCard(this.g, {required this.groups});
  final Map<String, dynamic> g;
  final List<Map<String, dynamic>> groups;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cats = (g['categories'] as List).cast<Map>();
    final income = g['income'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Row(children: [
                Flexible(
                  child: Text(g['name'], style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
                // Badge only when the name doesn't already say it.
                if (income && !g['name'].toString().toLowerCase().contains('income')) ...[
                  const SizedBox(width: 8),
                  Chip(label: const Text('Income'), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                ],
              ]),
            ),
            if (!income)
              IconButton(
                tooltip: 'Add category',
                icon: const Icon(Icons.add),
                onPressed: () => createCategoryFlow(context, ref, groupId: g['id']),
              ),
            PopupMenuButton<String>(
              tooltip: 'Group options',
              onSelected: (v) async {
                if (v == 'rename') {
                  final name = await promptText(context, title: 'Rename group', initial: g['name']);
                  if (name != null && context.mounted) {
                    await _call(context, ref, (dio) => dio.patch('/category-groups/${g['id']}', data: {'name': name}));
                  }
                } else if (v == 'delete') {
                  await _call(context, ref, (dio) => dio.delete('/category-groups/${g['id']}'));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename group')),
                PopupMenuItem(
                  value: 'delete',
                  enabled: cats.isEmpty && !income,
                  child: Text(cats.isEmpty ? 'Delete group' : 'Delete group (empty it first)'),
                ),
              ],
            ),
          ]),
          if (cats.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('No categories yet', style: TextStyle(color: theme.hintColor)),
            ),
          for (final c in cats) _CategoryRow(c, group: g, groups: groups),
        ]),
      ),
    );
  }
}

class _CategoryRow extends ConsumerWidget {
  const _CategoryRow(this.c, {required this.group, required this.groups});
  final Map c;
  final Map<String, dynamic> group;
  final List<Map<String, dynamic>> groups;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = (c['count'] as num?)?.toInt() ?? 0;
    final income = group['income'] == true;
    // Protected: Actual relies on this one for opening balances.
    final locked = c['name'] == 'Starting Balances';
    return Row(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(count == 0 ? 'Not used yet' : '$count transaction${count == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 12.5, color: theme.hintColor)),
          ]),
        ),
      ),
      if (!locked)
        PopupMenuButton<String>(
          tooltip: 'Category options',
          onSelected: (v) async {
            switch (v) {
              case 'rename':
                final name = await promptText(context, title: 'Rename category', initial: c['name']);
                if (name != null && context.mounted) {
                  await _call(context, ref, (dio) => dio.patch('/categories/${c['id']}', data: {'name': name}));
                }
              case 'move':
                final target = await showDialog<String>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: Text('Move "${c['name']}" to'),
                    children: [
                      for (final g in groups.where((g) => g['id'] != group['id'] && (g['income'] == true) == income))
                        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, g['id'] as String), child: Text(g['name'])),
                    ],
                  ),
                );
                if (target != null && context.mounted) {
                  await _call(context, ref, (dio) => dio.patch('/categories/${c['id']}', data: {'groupId': target}));
                }
              case 'delete':
                await _delete(context, ref, count, income);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'move', child: Text('Move to group…')),
            PopupMenuItem(value: 'delete', child: Text('Delete…')),
          ],
        ),
    ]);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, int count, bool income) async {
    // Only same-kind categories are valid targets (Actual won't move expense ↔ income).
    final targets = [
      for (final g in groups.where((g) => (g['income'] == true) == income))
        for (final x in (g['categories'] as List).cast<Map>().where((x) => x['id'] != c['id'] && x['name'] != 'Starting Balances'))
          (x['id'] as String, '${g['name']} › ${x['name']}'),
    ];
    String? transferTo;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Delete "${c['name']}"?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(count == 0
                ? 'No transactions use this category.'
                : '$count transaction${count == 1 ? ' uses' : 's use'} this category. Move them to:'),
            if (count > 0) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: transferTo,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('Leave uncategorized')),
                  for (final t in targets) DropdownMenuItem(value: t.$1, child: Text(t.$2, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => transferTo = v),
              ),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) {
      await _call(context, ref, (dio) => dio.delete('/categories/${c['id']}',
          queryParameters: {'transferTo': ?transferTo}));
    }
  }
}
