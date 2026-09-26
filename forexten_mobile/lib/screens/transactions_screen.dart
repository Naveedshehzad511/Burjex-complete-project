import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/crm_api.dart';

class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final token = ref.watch(crmTokenProvider);
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: () => context.go('/home')), title: const Text('Transactions')),
      body: token.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(child: Text('$e')),
        data: (_) => FutureBuilder<Map<String, dynamic>>(
          future: ref.read(crmApiProvider).get('/transactions/', query: {'limit': 50}),
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('${snap.error}', textAlign: TextAlign.center));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
            final data = snap.data!;
            final list = data['_list'] ?? data['results'] ?? data['transactions'] ?? const [];
            final rows = list is List ? list : const [];
            if (rows.isEmpty) {
              return Center(child: Text('No transactions yet.', style: TextStyle(color: Theme.of(context).hintColor)));
            }
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final row = rows[i];
                if (row is! Map) return const SizedBox.shrink();
                final m = Map<String, dynamic>.from(row);
                return ListTile(
                  title: Text('${m['tx_type'] ?? m['type'] ?? 'TX'}  ${m['amount'] ?? ''}'),
                  subtitle: Text('${m['status'] ?? ''}  ${m['created_at'] ?? m['createdAt'] ?? ''}'),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
