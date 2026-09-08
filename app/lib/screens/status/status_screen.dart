import 'package:flutter/material.dart';

import '../../core/api/api_exceptions.dart';
import '../../core/api/nightshift_client.dart';
import '../../core/config/settings_store.dart';
import '../../core/config/token_store.dart';
import '../../core/db/uploads_dao.dart';
import '../../models/local_upload.dart';

/// Pull-to-refresh view onto GET /status (aggregate counts/budget/ledger,
/// rendered close to the raw JSON) plus every local upload row, each
/// showing both its own phone-side state and the last-known Pi-side
/// server_state. The per-file merge is what M5 adds: GET /status alone
/// says nothing about individual files.
class StatusScreen extends StatefulWidget {
  final UploadsDao dao;
  final SettingsStore settingsStore;
  final TokenStore tokenStore;

  /// Test-only override -- when set, skips building a NightshiftClient
  /// from Settings so a widget test can hand in a fake without going near
  /// flutter_secure_storage's platform channel.
  final NightshiftClient? client;

  StatusScreen({
    super.key,
    UploadsDao? dao,
    SettingsStore? settingsStore,
    TokenStore? tokenStore,
    this.client,
  })  : dao = dao ?? UploadsDao(),
        settingsStore = settingsStore ?? SettingsStore(),
        tokenStore = tokenStore ?? TokenStore();

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  Map<String, dynamic>? _status;
  List<LocalUpload> _localRows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<NightshiftClient> _buildClient() async {
    if (widget.client != null) return widget.client!;
    final host = await widget.settingsStore.getHost();
    final port = await widget.settingsStore.getPort();
    final token = await widget.tokenStore.getToken();
    if (host == null || port == null || token == null) {
      throw StateError('Set up the server in Settings first.');
    }
    return NightshiftClient(host: host, port: port, token: token);
  }

  /// No by-hash or by-id lookup endpoint exists on the server (see the
  /// Phase 3 plan) -- /files only supports state/limit/offset. So this
  /// pages through the most recent files, newest id first, matching by
  /// sha256 against whatever this phone has actually uploaded, and stops
  /// once every locally-tracked hash has been accounted for. Anything this
  /// phone uploaded is necessarily recent (a high id), and a personal
  /// archive tops out around a few thousand rows, so this converges in a
  /// page or two in practice -- the page cap is just a safety valve, not a
  /// real limit on archive size.
  Future<Map<String, String>> _fetchServerStates(NightshiftClient client) async {
    final wanted = _localRows
        .where((r) => r.sha256 != null && r.serverFileId != null)
        .map((r) => r.sha256!)
        .toSet();
    final found = <String, String>{};
    if (wanted.isEmpty) return found;

    const pageSize = 200;
    const maxPages = 10;
    for (var page = 0; page < maxPages && found.length < wanted.length; page++) {
      final resp = await client.files(limit: pageSize, offset: page * pageSize);
      final rows = (resp['files'] as List).cast<Map<String, dynamic>>();
      if (rows.isEmpty) break;
      for (final r in rows) {
        final sha = r['sha256'] as String?;
        if (sha != null && wanted.contains(sha)) {
          found[sha] = r['state'] as String;
        }
      }
      final total = resp['total'] as int? ?? rows.length;
      if ((page + 1) * pageSize >= total) break;
    }
    return found;
  }

  Future<void> _refresh() async {
    setState(() => _loading = _status == null); // spinner only on first load
    _error = null;
    try {
      final client = await _buildClient();
      final status = await client.status();
      _localRows = await widget.dao.all();

      final serverStates = await _fetchServerStates(client);
      for (final row in _localRows) {
        final newState = row.sha256 != null ? serverStates[row.sha256] : null;
        if (newState != null && newState != row.serverState) {
          await widget.dao.setServerState(row.id!, newState);
        }
      }
      _localRows = await widget.dao.all(); // pick up the refreshed server_state

      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } on NightshiftApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.isUnauthorized
            ? 'Wrong token -- rejected by the server.'
            : e.isNetworkFailure
                ? "Couldn't reach the server -- check Settings."
                : 'Server error: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Status')),
      body: _loading && _status == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_error != null) _ErrorBanner(message: _error!),
                  if (_status != null) _SummaryCard(status: _status!),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text('Files', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  if (_localRows.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No files picked yet.'),
                    )
                  else
                    ..._localRows.reversed.map((row) => _FileRow(row: row)),
                ],
              ),
            ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final Map<String, dynamic> status;
  const _SummaryCard({required this.status});

  String _mb(num? bytes) => bytes == null ? '—' : '${(bytes / 1e6).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final counts = (status['counts'] as Map<String, dynamic>?) ?? {};
    final uploadsUsed = status['uploads_used'] ?? 0;
    final uploadBudget = status['daily_upload_budget'] ?? '—';
    final bytesUsed = status['bytes_used'] as num?;
    final byteBudget = status['daily_byte_budget'] as num?;
    final daysToDrain = status['estimated_days_to_drain'] as num?;
    final carryDebt = status['carry_debt'] as num?;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Today (${status['pacific_day'] ?? '—'})',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Uploads: $uploadsUsed / $uploadBudget'),
            Text('Data: ${_mb(bytesUsed)}${byteBudget != null ? ' / ${_mb(byteBudget)}' : ''}'),
            if (carryDebt != null && carryDebt > 0)
              Text('Carry debt: ${_mb(carryDebt)}'),
            if (daysToDrain != null)
              Text('Est. days to drain queue: ${daysToDrain.toStringAsFixed(1)}'),
            const SizedBox(height: 12),
            const Text('By state', style: TextStyle(fontWeight: FontWeight.w600)),
            for (final entry in counts.entries)
              Text('  ${entry.key}: ${entry.value['files']} file(s), '
                  '${_mb((entry.value['bytes'] as num?))}'),
          ],
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  final LocalUpload row;
  const _FileRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final sizeMb = (row.sizeBytes / 1e6).toStringAsFixed(1);
    return ListTile(
      title: Text(row.filename, overflow: TextOverflow.ellipsis),
      subtitle: Text('$sizeMb MB — ${_localLabel(row.state)}'
          '${row.serverState != null ? ' · Pi: ${row.serverState}' : ''}'),
      trailing: row.isConfirmed ? const Icon(Icons.check_circle, color: Colors.green) : null,
    );
  }

  String _localLabel(LocalUploadState s) => switch (s) {
        LocalUploadState.pending => 'Pending',
        LocalUploadState.hashing => 'Hashing…',
        LocalUploadState.ready => 'Ready',
        LocalUploadState.uploading => 'Uploading',
        LocalUploadState.verifying => 'Verifying',
        LocalUploadState.hashMismatch => 'Hash mismatch, retrying',
        LocalUploadState.confirmed => 'Confirmed',
        LocalUploadState.failed => 'Failed',
        LocalUploadState.deletedLocal => 'Deleted from phone',
      };
}
