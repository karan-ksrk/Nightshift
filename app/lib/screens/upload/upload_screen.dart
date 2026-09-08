import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/api/nightshift_client.dart';
import '../../core/config/settings_store.dart';
import '../../core/config/token_store.dart';
import '../../core/db/uploads_dao.dart';
import '../../core/upload/upload_engine.dart';
import '../../models/local_upload.dart';
import '../../widgets/progress_row.dart';
import '../settings/settings_screen.dart';

class UploadScreen extends StatefulWidget {
  // Injectable for tests -- defaults to the real, on-device implementations
  // in production. Without this, a widget test would hit sqflite's real
  // platform channel in initState (via UploadsDao()) before any test gets
  // a chance to mock it, the same class of hang the Settings screen's
  // tests had to work around for flutter_secure_storage.
  final UploadsDao dao;
  final SettingsStore settingsStore;
  final TokenStore tokenStore;

  UploadScreen({
    super.key,
    UploadsDao? dao,
    SettingsStore? settingsStore,
    TokenStore? tokenStore,
  })  : dao = dao ?? UploadsDao(),
        settingsStore = settingsStore ?? SettingsStore(),
        tokenStore = tokenStore ?? TokenStore();

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  UploadsDao get _dao => widget.dao;
  SettingsStore get _settingsStore => widget.settingsStore;
  TokenStore get _tokenStore => widget.tokenStore;

  // In-memory mirror of the DB, keyed by id, so the UI updates live without
  // re-querying on every progress tick. The DAO stays the source of truth
  // -- this is just what's currently rendered.
  final Map<int, LocalUpload> _rows = {};

  bool _picking = false;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final all = await _dao.all();
    if (!mounted) return;
    setState(() {
      for (final row in all) {
        if (row.id != null) _rows[row.id!] = row;
      }
    });
  }

  Future<NightshiftClient> _buildClient() async {
    final host = await _settingsStore.getHost();
    final port = await _settingsStore.getPort();
    final token = await _tokenStore.getToken();
    if (host == null || port == null || token == null) {
      throw StateError('Set up the server in Settings first.');
    }
    return NightshiftClient(host: host, port: port, token: token);
  }

  Future<void> _pickFiles() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final ids = <int>[];
      for (final f in result.files) {
        final path = f.path;
        if (path == null) continue; // shouldn't happen for FileType.video
        final id = await _dao.insertPending(
          // f.identifier is the original content:// URI on Android (SAF
          // picks), not the cache-copy path -- needed later for M6's
          // manual delete, which has to target the real document, not the
          // cache copy this app reads bytes from.
          localUri: f.identifier ?? path,
          localPath: path,
          filename: f.name,
          sizeBytes: f.size,
        );
        ids.add(id);
        final row = await _dao.findById(id);
        if (row != null && mounted) setState(() => _rows[id] = row);
      }

      if (ids.isNotEmpty) await _processQueue(ids);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Pick failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _processQueue(List<int> ids) async {
    setState(() => _processing = true);
    try {
      final client = await _buildClient();
      final engine = UploadEngine(client: client, dao: _dao);
      // Serial, one file at a time -- simple, and sufficient for a
      // personal-project LAN transfer (matches the chunk loop itself
      // being serial per the plan).
      for (final id in ids) {
        await engine.run(id, onUpdate: (row) {
          if (!mounted || row.id == null) return;
          setState(() => _rows[row.id!] = row);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _retry(int id) => _processQueue([id]);

  @override
  Widget build(BuildContext context) {
    final rows = _rows.values.toList()
      ..sort((a, b) => a.addedAt.compareTo(b.addedAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nightshift'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: rows.isEmpty
          ? const Center(child: Text('No files picked yet.'))
          : ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                return ProgressRow(
                  row: row,
                  onRetry: () => _retry(row.id!),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_picking || _processing) ? null : _pickFiles,
        icon: const Icon(Icons.video_library),
        label: Text(_processing ? 'Uploading…' : 'Pick videos'),
      ),
    );
  }
}
