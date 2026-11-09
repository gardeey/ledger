import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api.dart';

/// After a transaction is categorized, confirm it and offer to remember the choice for the payee.
/// Nothing becomes a rule unless "Always" is tapped.
void offerPayeeRule(BuildContext context, WidgetRef ref,
    {required String txId, required String payee, required String catName, int similar = 0}) {
  final messenger = ScaffoldMessenger.of(context);
  final canRemember = payee.isNotEmpty;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text('${payee.isEmpty ? 'Transaction' : payee} → $catName'),
    duration: const Duration(seconds: 6),
    persist: false,
    action: !canRemember
        ? null
        : SnackBarAction(
            label: similar > 0 ? 'Always (+$similar)' : 'Always',
            onPressed: () async {
              try {
                final res = await ref.read(dioProvider).post('/transactions/$txId/remember');
                final applied = (res.data['applied'] as num?)?.toInt() ?? 0;
                refreshAll(ref);
                messenger.showSnackBar(SnackBar(
                  content: Text('${res.data['updated'] == true ? 'Rule updated' : 'Rule saved'}: '
                      '$payee → $catName${applied > 0 ? ' · $applied similar updated' : ''}'),
                ));
              } on DioException catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
              }
            },
          ),
  ));
}
