import 'package:flutter/material.dart';

import '../../core/api/api_exceptions.dart';
import '../../core/api/nightshift_client.dart';
import '../../core/config/settings_store.dart';
import '../../core/config/token_store.dart';
import '../../core/db/uploads_dao.dart';
import '../../models/local_upload.dart';
import '../../theme/app_theme.dart';
import '../../theme/state_style.dart';
import '../../widgets/filename_text.dart';

/// Pull-to-refresh view onto GET /status (aggregate counts/budget/ledger)
/// plus every local upload row, each showing both its own phone-side state
/// and the last-known Pi-side server_state.
///
/// Laid out as an instrument readout, most-important-first: the queue drain
/// estimate is the largest thing on the screen, because with a ~100 GB queue
/// and a 10 GB nightly budget, "when is this done" is the only question the
/// aggregate numbers are really being asked.
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
    final status = _status;
    final prefixes =
        FilenameText.sharedPrefixes(_localRows.map((r) => r.filename));

    return Scaffold(
      appBar: AppBar(
        title: const Text('STATUS'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, size: 20, color: context.ns.faint),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading && status == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: EdgeInsets.zero,
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_error != null) _ErrorBanner(message: _error!),
                  if (status != null) ...[
                    _DrainEstimate(status: status),
                    _Gauges(status: status),
                    _Ledger(status: status),
                  ],
                  if (_localRows.isNotEmpty) ...[
                    _SectionLabel(
                      text: 'FROM THIS PHONE · ${_localRows.length}',
                    ),
                    for (final row in _localRows.reversed)
                      _FileLine(
                        row: row,
                        sharedPrefix: prefixes[row.filename] ?? '',
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

/// The one figure the aggregate numbers exist to answer.
class _DrainEstimate extends StatelessWidget {
  final Map<String, dynamic> status;
  const _DrainEstimate({required this.status});

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final days = status['estimated_days_to_drain'] as num?;
    final budget = status['daily_byte_budget'] as num?;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 16),
      decoration: BoxDecoration(
        color: ns.surface,
        border: Border(bottom: BorderSide(color: ns.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('QUEUE DRAINS IN', style: NsType.label(context)),
          const SizedBox(height: 6),
          Text(
            days == null ? '—' : days.toStringAsFixed(1),
            style: TextStyle(
              fontFamily: NsType.mono,
              fontSize: 56,
              fontWeight: FontWeight.w600,
              height: 0.95,
              letterSpacing: -2,
              color: ns.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            budget == null
                ? 'DAYS — NO BYTE BUDGET SET'
                : 'DAYS AT ${_gb(budget)} GB / NIGHT',
            style: NsType.label(context, color: ns.soft),
          ),
        ],
      ),
    );
  }

  // One decimal, matching the DATA gauge below it -- the same budget
  // rendered as "11 GB" here and "10.7 GB" there reads as two numbers.
  static String _gb(num bytes) => (bytes / 1e9).toStringAsFixed(1);
}

class _Gauges extends StatelessWidget {
  final Map<String, dynamic> status;
  const _Gauges({required this.status});

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final uploadsUsed = (status['uploads_used'] as num?) ?? 0;
    final uploadBudget = (status['daily_upload_budget'] as num?) ?? 100;
    final bytesUsed = (status['bytes_used'] as num?) ?? 0;
    final byteBudget = status['daily_byte_budget'] as num?;
    final day = status['pacific_day'] ?? '—';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ns.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('QUOTA DAY (PT)', style: NsType.label(context)),
              Text('$day', style: NsType.data(context, color: ns.ink)),
            ],
          ),
          const SizedBox(height: 12),
          _Gauge(
            label: 'UPLOADS',
            value: '${uploadsUsed.toInt()} / ${uploadBudget.toInt()}',
            fraction: uploadBudget == 0 ? 0 : uploadsUsed / uploadBudget,
          ),
          const SizedBox(height: 10),
          _Gauge(
            label: 'DATA',
            value: byteBudget == null
                ? '${(bytesUsed / 1e9).toStringAsFixed(2)} GB'
                : '${(bytesUsed / 1e9).toStringAsFixed(2)} / '
                    '${(byteBudget / 1e9).toStringAsFixed(1)} GB',
            fraction:
                byteBudget == null || byteBudget == 0 ? 0 : bytesUsed / byteBudget,
          ),
        ],
      ),
    );
  }
}

class _Gauge extends StatelessWidget {
  final String label;
  final String value;
  final double fraction;
  const _Gauge({
    required this.label,
    required this.value,
    required this.fraction,
  });

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: NsType.label(context)),
            Text(value, style: NsType.data(context, color: ns.ink)),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 3,
            backgroundColor: ns.track,
            valueColor: AlwaysStoppedAnimation(ns.accent),
          ),
        ),
      ],
    );
  }
}

/// Counts by state, as a ledger rather than a paragraph -- right-aligned
/// tabular figures so the columns can be compared by eye.
class _Ledger extends StatelessWidget {
  final Map<String, dynamic> status;
  const _Ledger({required this.status});

  static const _order = [
    'QUEUED',
    'UPLOADING',
    'PROCESSING',
    'VERIFIED',
    'DELETED',
    'FAILED',
  ];

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final counts = (status['counts'] as Map<String, dynamic>?) ?? {};

    var totalFiles = 0;
    var totalBytes = 0.0;
    for (final entry in counts.entries) {
      totalFiles += ((entry.value['files'] as num?) ?? 0).toInt();
      totalBytes += ((entry.value['bytes'] as num?) ?? 0).toDouble();
    }

    final present = _order.where(counts.containsKey).toList();

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ns.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Text('ARCHIVE', style: NsType.label(context)),
          ),
          for (final state in present)
            _LedgerRow(
              dotColor: StateStyle.serverColor(context, state),
              label: state,
              files: ((counts[state]['files'] as num?) ?? 0).toInt(),
              bytes: ((counts[state]['bytes'] as num?) ?? 0).toDouble(),
            ),
          _LedgerRow(
            dotColor: null,
            label: 'TOTAL',
            files: totalFiles,
            bytes: totalBytes,
            emphasise: true,
          ),
        ],
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  final Color? dotColor;
  final String label;
  final int files;
  final double bytes;
  final bool emphasise;

  const _LedgerRow({
    required this.dotColor,
    required this.label,
    required this.files,
    required this.bytes,
    this.emphasise = false,
  });

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final style = NsType.data(
      context,
      size: 10.5,
      color: emphasise ? ns.ink : ns.soft,
    ).copyWith(fontWeight: emphasise ? FontWeight.w600 : FontWeight.w400);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 5, 14, 5),
      child: Row(
        children: [
          if (dotColor != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
          ] else
            const SizedBox(width: 14),
          Expanded(child: Text(label, style: style)),
          SizedBox(
            width: 52,
            child: Text('$files', textAlign: TextAlign.right, style: style),
          ),
          SizedBox(
            width: 78,
            child: Text(
              bytes == 0 ? '—' : '${(bytes / 1e9).toStringAsFixed(2)} GB',
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: ns.surface,
        border: Border(bottom: BorderSide(color: ns.rule)),
      ),
      child: Text(text, style: NsType.label(context)),
    );
  }
}

/// Compact per-file line: the phone's own state on the left, the Pi's on the
/// right. The gap between the two is the point of the screen.
class _FileLine extends StatelessWidget {
  final LocalUpload row;
  final String sharedPrefix;
  const _FileLine({required this.row, required this.sharedPrefix});

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final style = StateStyle.of(context, row);

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ns.rule)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: style.color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 9, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FilenameText(
                      filename: row.filename,
                      sharedPrefix: sharedPrefix,
                      fontSize: 11,
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Text(
                          style.label,
                          style: NsType.state(context, style.color),
                        ),
                        const Spacer(),
                        Text(
                          row.serverState == null
                              ? 'PI: —'
                              : 'PI: ${row.serverState}',
                          style: NsType.data(
                            context,
                            color:
                                StateStyle.serverColor(context, row.serverState),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
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
    final ns = context.ns;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      color: ns.stateBad.withValues(alpha: 0.13),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: ns.stateBad, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: ns.ink),
            ),
          ),
        ],
      ),
    );
  }
}
