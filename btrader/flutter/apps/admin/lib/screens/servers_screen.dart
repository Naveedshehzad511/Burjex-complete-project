import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:btrader_core/btrader_core.dart';

import '../admin_providers.dart';
import '../shell.dart';

const _readinessValues = ['NOT_READY', 'ONBOARDING', 'READY', 'ACTIVE', 'STANDBY', 'MAINTENANCE', 'ERROR'];

String _shortError(Object error) {
  final value = error.toString();
  return value.length > 180 ? '${value.substring(0, 180)}…' : value;
}

Color _healthColor(BuildContext context, String status) => switch (status) {
      'HEALTHY' => const Color(0xFF1B9C62),
      'WARNING' => const Color(0xFFD98A00),
      'DEGRADED' => const Color(0xFFD65F00),
      'CRITICAL' || 'OFFLINE' => Theme.of(context).colorScheme.error,
      'MAINTENANCE' => Theme.of(context).colorScheme.primary,
      _ => Theme.of(context).disabledColor,
    };

Widget _statusPill(BuildContext context, String status) {
  final color = _healthColor(context, status);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(5)),
    child: Text(status, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
  );
}

class ServersScreen extends ConsumerWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authControllerProvider).role;
    if (role != 'SUPER_ADMIN' && role != 'TENANT_ADMIN') {
      return const AdminPage(title: 'Trading Engine → Servers', child: Center(child: Text('Administrator only.')));
    }
    final data = ref.watch(monitoringServersProvider);
    return AdminPage(
      title: 'Trading Engine → Servers',
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: () => ref.invalidate(monitoringServersProvider),
          icon: const Icon(Icons.refresh),
        ),
        OutlinedButton.icon(
          onPressed: () => _showThresholds(context, ref, data.valueOrNull?['settings']),
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Health thresholds'),
        ),
        FilledButton.icon(
          onPressed: () => _showServerEditor(context, ref),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add server'),
        ),
      ],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Unable to load servers: ${_shortError(error)}')),
        data: (payload) {
          final servers = List<dynamic>.from(payload['servers'] as List? ?? const []);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(monitoringServersProvider),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _ServerSummary(servers: servers),
                const SizedBox(height: 14),
                Text(
                  'Registry rows are not active trading servers. Monitoring uses agent heartbeats and existing health endpoints; '
                  'automatic failover and remote restarts are intentionally disabled.',
                  style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
                ),
                const SizedBox(height: 14),
                if (servers.isEmpty)
                  const _EmptyServers()
                else
                  ...servers.map((raw) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ServerCard(server: Map<String, dynamic>.from(raw as Map)),
                      )),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ServerSummary extends StatelessWidget {
  const _ServerSummary({required this.servers});
  final List<dynamic> servers;

  @override
  Widget build(BuildContext context) {
    int count(bool Function(Map<String, dynamic>) test) =>
        servers.where((server) => test(Map<String, dynamic>.from(server as Map))).length;
    final chips = <(String, int, Color)>[
      ('Total', servers.length, Theme.of(context).colorScheme.primary),
      ('Healthy', count((s) => s['health']?['status'] == 'HEALTHY'), _healthColor(context, 'HEALTHY')),
      ('Warning', count((s) => s['health']?['status'] == 'WARNING' || s['health']?['status'] == 'DEGRADED'), _healthColor(context, 'WARNING')),
      ('Critical', count((s) => s['health']?['status'] == 'CRITICAL'), _healthColor(context, 'CRITICAL')),
      ('Offline', count((s) => s['health']?['status'] == 'OFFLINE'), _healthColor(context, 'OFFLINE')),
      ('Primary', count((s) => s['role'] == 'PRIMARY'), Theme.of(context).colorScheme.primary),
      ('Standby', count((s) => s['role'] == 'STANDBY'), Theme.of(context).colorScheme.secondary),
      ('Maintenance', count((s) => s['health']?['status'] == 'MAINTENANCE'), _healthColor(context, 'MAINTENANCE')),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final chip in chips)
          Chip(
            avatar: CircleAvatar(backgroundColor: chip.$3, radius: 5),
            label: Text('${chip.$1}: ${chip.$2}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }
}

class _EmptyServers extends StatelessWidget {
  const _EmptyServers();
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No monitored servers registered.\nAdd a registry entry first; it remains NOT READY until a monitoring agent reports a heartbeat.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      );
}

class _ServerCard extends ConsumerWidget {
  const _ServerCard({required this.server});
  final Map<String, dynamic> server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = Map<String, dynamic>.from(server['health'] as Map? ?? const {});
    final latest = server['latestHeartbeat'] as Map?;
    final status = health['status']?.toString() ?? 'OFFLINE';
    final services = latest?['services'] as Map?;
    final details = <String>[
      if (latest?['cpuPercent'] != null) 'CPU ${latest!['cpuPercent']}%',
      if (latest?['ramPercent'] != null) 'RAM ${latest!['ramPercent']}%',
      if (latest?['diskPercent'] != null) 'Disk ${latest!['diskPercent']}%',
      if (health['heartbeatAgeSeconds'] != null) 'Heartbeat ${health['heartbeatAgeSeconds']}s ago',
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go('/servers/${server['id']}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(server['name']?.toString() ?? 'Unnamed server',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              _statusPill(context, status),
              const SizedBox(width: 8),
              _rolePill(context, server['role']?.toString() ?? 'STANDBY'),
            ]),
            const SizedBox(height: 5),
            Text(
              '${server['host']}:${server['sshPort']}  ·  ${server['region'] ?? 'No region'}  ·  ${server['environment']}  ·  ${server['readiness']}',
              style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 7, children: [
              for (final detail in details) Text(detail, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              if (server['appVersion'] != null) Text('Version ${server['appVersion']}', style: const TextStyle(fontSize: 12)),
              if (services != null)
                ...services.entries.map((entry) => _servicePill(context, entry.key.toString(), entry.value.toString())),
            ]),
            if ((health['problems'] as List? ?? const []).isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                (health['problems'] as List).map((problem) => problem.toString()).join('  •  '),
                style: TextStyle(fontSize: 12, color: _healthColor(context, status)),
              ),
            ],
            const SizedBox(height: 8),
            Row(children: [
              TextButton(onPressed: () => context.go('/servers/${server['id']}'), child: const Text('Details')),
              const Spacer(),
              if (server['role'] != 'PRIMARY')
                TextButton(
                  onPressed: () => _showActionConfirmation(context, ref, server, 'SET_PRIMARY'),
                  child: const Text('Set Primary'),
                ),
              TextButton(
                onPressed: () => _showActionConfirmation(context, ref, server, 'RESTART'),
                child: const Text('Restart…'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

Widget _rolePill(BuildContext context, String role) {
  final color = role == 'PRIMARY' ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.secondary;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(5)),
    child: Text(role, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
  );
}

Widget _servicePill(BuildContext context, String name, String value) {
  final up = value == 'true' || value == 'UP';
  return Text('$name: ${up ? 'UP' : value}', style: TextStyle(fontSize: 11, color: up ? _healthColor(context, 'HEALTHY') : _healthColor(context, 'CRITICAL')));
}

class ServerDetailScreen extends ConsumerWidget {
  const ServerDetailScreen({super.key, required this.serverId});
  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authControllerProvider).role;
    if (role != 'SUPER_ADMIN' && role != 'TENANT_ADMIN') {
      return const AdminPage(title: 'Server details', child: Center(child: Text('Administrator only.')));
    }
    final data = ref.watch(monitoringServerDetailProvider(serverId));
    return AdminPage(
      title: 'Server details',
      actions: [
        TextButton.icon(onPressed: () => context.go('/servers'), icon: const Icon(Icons.arrow_back, size: 18), label: const Text('Servers')),
        IconButton(onPressed: () => ref.invalidate(monitoringServerDetailProvider(serverId)), tooltip: 'Refresh', icon: const Icon(Icons.refresh)),
      ],
      child: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Unable to load server: ${_shortError(error)}')),
        data: (server) => _ServerDetailBody(server: server),
      ),
    );
  }
}

class _ServerDetailBody extends ConsumerWidget {
  const _ServerDetailBody({required this.server});
  final Map<String, dynamic> server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = Map<String, dynamic>.from(server['health'] as Map? ?? const {});
    final latest = Map<String, dynamic>.from(server['latestHeartbeat'] as Map? ?? const {});
    final status = health['status']?.toString() ?? 'OFFLINE';
    final events = List<dynamic>.from(server['events'] as List? ?? const []);
    final services = Map<String, dynamic>.from(latest['services'] as Map? ?? const {});
    return ListView(children: [
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 8, children: [
        Text(server['name']?.toString() ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        _statusPill(context, status),
        _rolePill(context, server['role']?.toString() ?? 'STANDBY'),
        OutlinedButton.icon(
          onPressed: () => _showServerEditor(context, ref, existing: server),
          icon: const Icon(Icons.edit_outlined, size: 17),
          label: const Text('Edit'),
        ),
        if (server['role'] != 'PRIMARY')
          OutlinedButton(onPressed: () => _showActionConfirmation(context, ref, server, 'SET_PRIMARY'), child: const Text('Set Primary')),
        OutlinedButton(onPressed: () => _showActionConfirmation(context, ref, server, 'MAINTENANCE'), child: const Text('Maintenance')),
        OutlinedButton(onPressed: () => _showActionConfirmation(context, ref, server, 'RESTART'), child: const Text('Restart…')),
      ]),
      const SizedBox(height: 14),
      _Section(
        title: 'Overview',
        child: Wrap(spacing: 24, runSpacing: 12, children: [
          _field('Host', '${server['host']}:${server['sshPort']}'),
          _field('Region', server['region']?.toString() ?? '—'),
          _field('Environment', server['environment']?.toString() ?? '—'),
          _field('Readiness', server['readiness']?.toString() ?? '—'),
          _field('Online', health['online'] == true ? 'Yes' : 'No'),
          _field('Last heartbeat', health['heartbeatAgeSeconds'] == null ? 'Never' : '${health['heartbeatAgeSeconds']} seconds ago'),
          _field('App version', server['appVersion']?.toString() ?? '—'),
        ]),
      ),
      const SizedBox(height: 12),
      _Section(
        title: 'Resources',
        child: Wrap(spacing: 24, runSpacing: 12, children: [
          _field('CPU', _pct(latest['cpuPercent'])),
          _field('RAM', _pct(latest['ramPercent'])),
          _field('Disk', _pct(latest['diskPercent'])),
          _field('Network RTT', latest['network']?['rttMs'] == null ? '—' : '${latest['network']['rttMs']} ms'),
          _field('Uptime', latest['uptimeSeconds'] == null ? '—' : _uptime(latest['uptimeSeconds'] as num)),
        ]),
      ),
      const SizedBox(height: 12),
      _Section(
        title: 'Service health',
        child: services.isEmpty
            ? Text('No agent service checks reported yet.', style: TextStyle(color: Theme.of(context).hintColor))
            : Wrap(spacing: 16, runSpacing: 10, children: services.entries.map((entry) => _servicePill(context, entry.key, entry.value.toString())).toList()),
      ),
      const SizedBox(height: 12),
      _Section(
        title: 'Problems',
        child: (health['problems'] as List? ?? const []).isEmpty
            ? const Text('No current problems.')
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final problem in health['problems'] as List)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text('• ${problem.toString()}', style: TextStyle(color: _healthColor(context, status))),
                  ),
              ]),
      ),
      const SizedBox(height: 12),
      _Section(
        title: 'Recent events',
        child: events.isEmpty
            ? Text('No events recorded.', style: TextStyle(color: Theme.of(context).hintColor))
            : Column(children: [
                for (final event in events.take(20))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.history, size: 18, color: _healthColor(context, event['severity'] == 'WARNING' ? 'WARNING' : 'HEALTHY')),
                    title: Text(event['message']?.toString() ?? ''),
                    subtitle: Text('${event['kind'] ?? 'EVENT'} · ${event['createdAt'] ?? ''}'),
                  ),
              ]),
      ),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

Widget _field(String label, String value) => SizedBox(
      width: 150,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(value),
      ]),
    );

String _pct(dynamic value) => value == null ? '—' : '${value}%';
String _uptime(num seconds) {
  final duration = Duration(seconds: seconds.toInt());
  return '${duration.inDays}d ${duration.inHours.remainder(24)}h ${duration.inMinutes.remainder(60)}m';
}

Future<void> _showServerEditor(BuildContext context, WidgetRef ref, {Map<String, dynamic>? existing}) async {
  final name = TextEditingController(text: existing?['name']?.toString() ?? '');
  final host = TextEditingController(text: existing?['host']?.toString() ?? '');
  final port = TextEditingController(text: '${existing?['sshPort'] ?? 22}');
  final region = TextEditingController(text: existing?['region']?.toString() ?? '');
  final environment = TextEditingController(text: existing?['environment']?.toString() ?? 'production');
  var enabled = existing?['enabled'] != false;
  var readiness = existing?['readiness']?.toString() ?? 'NOT_READY';
  var busy = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(existing == null ? 'Add monitored server' : 'Edit monitored server'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('This records a server registry entry only. SSH passwords, private keys, tokens, and remote control are not accepted.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 14),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: host, decoration: const InputDecoration(labelText: 'Host or IP', border: OutlineInputBorder()))),
                const SizedBox(width: 10),
                SizedBox(width: 110, child: TextField(controller: port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'SSH port', border: OutlineInputBorder()))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: region, decoration: const InputDecoration(labelText: 'Region', border: OutlineInputBorder()))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: environment, decoration: const InputDecoration(labelText: 'Environment', border: OutlineInputBorder()))),
              ]),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: readiness,
                decoration: const InputDecoration(labelText: 'Readiness', border: OutlineInputBorder()),
                items: _readinessValues.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
                onChanged: (value) => setState(() => readiness = value ?? 'NOT_READY'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Monitoring enabled'),
                value: enabled,
                onChanged: (value) => setState(() => enabled = value),
              ),
              if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      final body = {
                        'name': name.text.trim(),
                        'host': host.text.trim(),
                        'sshPort': int.tryParse(port.text) ?? 22,
                        'region': region.text.trim(),
                        'environment': environment.text.trim(),
                        'readiness': readiness,
                        'enabled': enabled,
                        if (existing == null) 'role': 'STANDBY',
                      };
                      final api = ref.read(apiClientProvider);
                      if (existing == null) {
                        await api.post('/admin/servers', body);
                      } else {
                        await api.patch('/admin/servers/${existing['id']}', body);
                      }
                      ref.invalidate(monitoringServersProvider);
                      if (existing != null) ref.invalidate(monitoringServerDetailProvider(existing['id'].toString()));
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    } catch (exception) {
                      setState(() {
                        busy = false;
                        error = _shortError(exception);
                      });
                    }
                  },
            child: Text(busy ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    ),
  );
  name.dispose();
  host.dispose();
  port.dispose();
  region.dispose();
  environment.dispose();
}

Future<void> _showActionConfirmation(BuildContext context, WidgetRef ref, Map<String, dynamic> server, String action) async {
  final confirmation = TextEditingController();
  final required = action == 'SET_PRIMARY' ? 'SET PRIMARY' : action;
  var busy = false;
  String? error;
  final explanation = switch (action) {
    'RESTART' => 'This records an audited restart request only. It cannot SSH, WinRM, restart Docker, restart BurjexMt5Bridge, or restart any live service.',
    'SET_PRIMARY' => 'This changes only the registry label. It does not start a matcher or perform failover; a second live matcher remains unsafe.',
    'MAINTENANCE' => 'This changes only the monitoring readiness label. It does not change any running service.',
    _ => '',
  };
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text('${action.replaceAll('_', ' ')} — confirmation required'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(explanation),
            const SizedBox(height: 12),
            Text('Type $required to continue.', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(controller: confirmation, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder())),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      final result = await ref.read(apiClientProvider).post('/admin/servers/${server['id']}/actions', {
                        'action': action,
                        'confirmation': confirmation.text.trim(),
                      });
                      ref.invalidate(monitoringServersProvider);
                      ref.invalidate(monitoringServerDetailProvider(server['id'].toString()));
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result['message']?.toString() ?? 'Action recorded')));
                      }
                    } catch (exception) {
                      setState(() {
                        busy = false;
                        error = _shortError(exception);
                      });
                    }
                  },
            child: Text(busy ? 'Recording…' : 'Confirm'),
          ),
        ],
      ),
    ),
  );
  confirmation.dispose();
}

Future<void> _showThresholds(BuildContext context, WidgetRef ref, dynamic current) async {
  final values = Map<String, TextEditingController>.fromEntries([
    for (final key in [
      'cpuWarningPercent', 'cpuCriticalPercent', 'ramWarningPercent', 'ramCriticalPercent',
      'diskWarningPercent', 'diskCriticalPercent', 'heartbeatWarningSeconds',
      'heartbeatOfflineSeconds', 'maxHeartbeatsPerServer',
    ])
      MapEntry(key, TextEditingController(text: '${(current as Map?)?[key] ?? _thresholdDefault(key)}')),
  ]);
  var busy = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: const Text('Server health thresholds'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Warning must be lower than critical. Heartbeats progress from online to warning to offline; one missed beat never marks a server offline.',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 14),
              for (final resource in ['cpu', 'ram', 'disk'])
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(children: [
                    SizedBox(width: 95, child: Text(resource.toUpperCase())),
                    Expanded(child: TextField(controller: values['${resource}WarningPercent'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Warning %', border: OutlineInputBorder(), isDense: true))),
                    const SizedBox(width: 10),
                    Expanded(child: TextField(controller: values['${resource}CriticalPercent'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Critical %', border: OutlineInputBorder(), isDense: true))),
                  ]),
                ),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: TextField(controller: values['heartbeatWarningSeconds'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Heartbeat warning grace (seconds)', border: OutlineInputBorder(), isDense: true))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: values['heartbeatOfflineSeconds'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Heartbeat offline grace (seconds)', border: OutlineInputBorder(), isDense: true))),
              ]),
              const SizedBox(height: 10),
              TextField(controller: values['maxHeartbeatsPerServer'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Heartbeat storage cap per server', border: OutlineInputBorder(), isDense: true)),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      final body = <String, int>{
                        for (final entry in values.entries) entry.key: int.tryParse(entry.value.text) ?? 0,
                      };
                      await ref.read(apiClientProvider).patch('/admin/servers/settings', body);
                      ref.invalidate(monitoringServersProvider);
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    } catch (exception) {
                      setState(() {
                        busy = false;
                        error = _shortError(exception);
                      });
                    }
                  },
            child: Text(busy ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    ),
  );
  for (final controller in values.values) {
    controller.dispose();
  }
}

int _thresholdDefault(String key) => switch (key) {
      'cpuWarningPercent' || 'ramWarningPercent' || 'diskWarningPercent' => 70,
      'cpuCriticalPercent' || 'ramCriticalPercent' || 'diskCriticalPercent' => 85,
      'heartbeatWarningSeconds' => 90,
      'heartbeatOfflineSeconds' => 180,
      'maxHeartbeatsPerServer' => 1440,
      _ => 0,
    };
