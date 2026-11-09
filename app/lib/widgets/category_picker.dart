import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api.dart';

/// Bottom sheet with search; returns {'id','name'} or null.
Future<Map<String, String>?> pickCategory(BuildContext context) =>
    showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const _Picker(),
    );

/// Single text field dialog; returns the trimmed text, or null if cancelled / empty.
Future<String?> promptText(BuildContext context, {required String title, String initial = '', String label = 'Name'}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() => Navigator.pop(ctx, ctl.text.trim().isEmpty ? null : ctl.text.trim());
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: const Text('Save')),
        ],
      );
    },
  );
}

/// Ask for a name + group and create the category. Returns {'id','name'} of the new category.
Future<Map<String, String>?> createCategoryFlow(BuildContext context, WidgetRef ref, {String? groupId, String initial = ''}) async {
  final groups = (await ref.read(categoriesProvider.future)).where((g) => g['income'] != true).toList();
  if (!context.mounted) return null;
  final result = await showDialog<(String, String)>(
    context: context,
    builder: (_) => _NewCategoryDialog(groups: groups, groupId: groupId ?? groups.firstOrNull?['id'], initial: initial),
  );
  if (result == null || !context.mounted) return null;
  try {
    final res = await ref.read(dioProvider).post('/categories', data: {'name': result.$1, 'groupId': result.$2});
    ref.invalidate(categoriesProvider);
    return {'id': res.data['id'] as String, 'name': result.$1};
  } on DioException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
    return null;
  }
}

class _NewCategoryDialog extends StatefulWidget {
  const _NewCategoryDialog({required this.groups, required this.groupId, required this.initial});
  final List<Map<String, dynamic>> groups;
  final String? groupId;
  final String initial;

  @override
  State<_NewCategoryDialog> createState() => _NewCategoryDialogState();
}

class _NewCategoryDialogState extends State<_NewCategoryDialog> {
  late final _name = TextEditingController(text: widget.initial);
  late String? _group = widget.groupId;

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty || _group == null) return;
    Navigator.pop(context, (name, _group!));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New category'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Restaurants'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _group,
            decoration: const InputDecoration(labelText: 'Group'),
            items: [for (final g in widget.groups) DropdownMenuItem(value: g['id'] as String, child: Text(g['name']))],
            onChanged: (v) => setState(() => _group = v),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _submit, child: const Text('Create')),
        ],
      );
}

class _Picker extends ConsumerStatefulWidget {
  const _Picker();
  @override
  ConsumerState<_Picker> createState() => _PickerState();
}

class _PickerState extends ConsumerState<_Picker> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(categoriesProvider);
    return SizedBox(
      height: MediaQuery.of(context).size.height * .75,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: false,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search categories', border: OutlineInputBorder()),
            onChanged: (v) => setState(() => q = v.toLowerCase()),
          ),
        ),
        Expanded(
          child: cats.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text(errText(e))),
            data: (groups) => ListView(children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(q.isEmpty ? 'New category' : 'Create "${q.trim()}"'),
                onTap: () async {
                  final c = await createCategoryFlow(context, ref, initial: q.isEmpty ? '' : _titleCase(q.trim()));
                  if (c != null && context.mounted) Navigator.pop(context, c);
                },
              ),
              const Divider(height: 1),
              for (final g in groups)
                for (final c in (g['categories'] as List).cast<Map>().where((c) => q.isEmpty || c['name'].toString().toLowerCase().contains(q)))
                  ListTile(
                    title: Text(c['name']),
                    subtitle: Text(g['name']),
                    onTap: () => Navigator.pop(context, {'id': c['id'] as String, 'name': c['name'] as String}),
                  ),
            ]),
          ),
        ),
      ]),
    );
  }
}

String _titleCase(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
